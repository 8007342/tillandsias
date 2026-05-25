//! Vsock-or-Unix control-wire client for the host trays.
//!
//! Wraps `tillandsias-control-wire::transport::connect` and provides a
//! typed `request`/`handshake` surface over `ControlEnvelope`. The Linux
//! dev box uses the `Unix` transport for round-trip unit tests against a
//! fake in-process server; production Windows + macOS hosts open `Vsock`
//! to the in-VM headless.
//!
//! @trace spec:host-shell-architecture, spec:vsock-transport

#![allow(dead_code)]

use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use tillandsias_control_wire::transport::{
    self, AsyncReadWrite, Transport, CONTROL_WIRE_VSOCK_PORT,
};
use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION, decode, encode,
};

/// Default duration the client gives the in-VM headless to ack a `Hello`
/// before treating the VM as unreachable. Matches the
/// `host-shell-architecture.transport.vsock-client-lifecycle@v1`
/// "within 2s of VM start" budget.
pub const DEFAULT_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(2);

/// Backoff schedule for the reconnect loop. Mirrors the spec's
/// `250ms / 500ms / 1s / 2s / 4s` cap.
pub const BACKOFF_SCHEDULE: &[Duration] = &[
    Duration::from_millis(250),
    Duration::from_millis(500),
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
];

/// A connected control-wire client.
///
/// Holds a single open transport stream and a monotonic per-connection
/// `seq` counter. The Linux dev loop uses `Transport::Unix`; production
/// Windows + macOS use `Transport::Vsock`.
pub struct Client {
    stream: Box<dyn AsyncReadWrite + Unpin + Send>,
    next_seq: AtomicU64,
    transport: Transport,
}

impl Client {
    /// Open a fresh connection to `transport`. Does not perform the
    /// `Hello`/`HelloAck` handshake — call `handshake()` next.
    pub async fn connect(transport: Transport) -> io::Result<Self> {
        let stream = transport::connect(&transport).await?;
        Ok(Self {
            stream,
            next_seq: AtomicU64::new(1),
            transport,
        })
    }

    /// Convenience constructor matching the Windows/macOS production path:
    /// connect over vsock to the given CID on the standard control port.
    pub async fn connect_vsock(cid: u32) -> io::Result<Self> {
        Self::connect(Transport::Vsock {
            cid,
            port: CONTROL_WIRE_VSOCK_PORT,
        })
        .await
    }

    fn next_seq(&self) -> u64 {
        self.next_seq.fetch_add(1, Ordering::Relaxed)
    }

    /// Send a `Hello` envelope and consume the `HelloAck` reply, returning
    /// the server's reported `wire_version`. Surfaces a wire-version
    /// mismatch as an `InvalidData` error.
    pub async fn handshake(&mut self) -> io::Result<u16> {
        let seq = self.next_seq();
        let hello = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::Hello {
                from: "tillandsias-host-shell".to_string(),
                capabilities: vec![
                    "VmStatusRequest".to_string(),
                    "VmShutdownRequest".to_string(),
                    "EnumerateLocalProjects".to_string(),
                    "CloudRefreshRequest".to_string(),
                ],
            },
        };
        self.send(&hello).await?;
        let ack = self.recv().await?;
        match ack.body {
            ControlMessage::HelloAck { wire_version, .. } => {
                if wire_version != WIRE_VERSION {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!(
                            "wire version mismatch: local={} server={}",
                            WIRE_VERSION, wire_version
                        ),
                    ));
                }
                Ok(wire_version)
            }
            other => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("expected HelloAck, got {:?}", other),
            )),
        }
    }

    /// Send a single envelope and await the next inbound envelope. Callers
    /// requiring strict sequence correlation MUST filter on `seq` from the
    /// reply.
    pub async fn request(&mut self, envelope: &ControlEnvelope) -> io::Result<ControlEnvelope> {
        self.send(envelope).await?;
        self.recv().await
    }

    /// Allocate a fresh `seq` for outgoing envelopes the caller authors.
    pub fn allocate_seq(&self) -> u64 {
        self.next_seq()
    }

    async fn send(&mut self, envelope: &ControlEnvelope) -> io::Result<()> {
        let bytes = encode(envelope).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        if bytes.len() > MAX_MESSAGE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "control frame too large",
            ));
        }
        self.stream.write_all(&(bytes.len() as u32).to_be_bytes()).await?;
        self.stream.write_all(&bytes).await?;
        self.stream.flush().await
    }

    async fn recv(&mut self) -> io::Result<ControlEnvelope> {
        let mut len_buf = [0u8; 4];
        self.stream.read_exact(&mut len_buf).await?;
        let len = u32::from_be_bytes(len_buf) as usize;
        if len > MAX_MESSAGE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "inbound control frame too large",
            ));
        }
        let mut body = vec![0u8; len];
        self.stream.read_exact(&mut body).await?;
        decode(&body).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }
}

/// Try `connect + handshake` once, with the given timeout for the whole
/// operation. Returns `Ok(Client)` on success, an `io::Error` otherwise.
///
/// @trace spec:host-shell-architecture.transport.vsock-client-lifecycle@v1
pub async fn connect_with_handshake(
    transport: Transport,
    timeout: Duration,
) -> io::Result<Client> {
    match tokio::time::timeout(timeout, async {
        let mut client = Client::connect(transport).await?;
        client.handshake().await?;
        Ok::<_, io::Error>(client)
    })
    .await
    {
        Ok(result) => result,
        Err(_) => Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "handshake timed out",
        )),
    }
}

// These round-trip tests drive the `Transport::Unix` path, which only exists
// on Unix (production Windows/macOS use `Transport::Vsock`). Gate the module
// on `unix` so `cargo test` compiles on the Windows host; Linux + macOS still
// run them.
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use tokio::net::UnixListener;

    async fn spawn_hello_responder(path: std::path::PathBuf) -> tokio::task::JoinHandle<()> {
        let listener = UnixListener::bind(&path).expect("bind responder");
        tokio::spawn(async move {
            let (mut stream, _addr) = listener.accept().await.expect("accept");
            // Read Hello.
            let mut len_buf = [0u8; 4];
            stream.read_exact(&mut len_buf).await.expect("read len");
            let len = u32::from_be_bytes(len_buf) as usize;
            let mut body = vec![0u8; len];
            stream.read_exact(&mut body).await.expect("read body");
            let env = decode(&body).expect("decode");
            assert!(matches!(env.body, ControlMessage::Hello { .. }));
            // Reply with HelloAck.
            let ack = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: env.seq,
                body: ControlMessage::HelloAck {
                    wire_version: WIRE_VERSION,
                    server_caps: vec!["v1".to_string()],
                },
            };
            let ack_bytes = encode(&ack).expect("encode ack");
            stream
                .write_all(&(ack_bytes.len() as u32).to_be_bytes())
                .await
                .expect("write len");
            stream.write_all(&ack_bytes).await.expect("write ack");
            stream.flush().await.expect("flush");
            // Keep the stream alive briefly so the client can complete the read.
            tokio::time::sleep(Duration::from_millis(100)).await;
        })
    }

    /// @trace spec:host-shell-architecture, spec:vsock-transport
    #[tokio::test]
    async fn handshake_succeeds_against_fake_unix_server() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("control.sock");
        let _server = spawn_hello_responder(path.clone()).await;
        // Give the listener a moment to bind.
        tokio::time::sleep(Duration::from_millis(50)).await;

        let client = connect_with_handshake(
            Transport::Unix(path),
            DEFAULT_HANDSHAKE_TIMEOUT,
        )
        .await
        .expect("handshake succeeds");
        // After handshake the next seq is 2 (we consumed 1 for Hello).
        assert_eq!(client.next_seq.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn handshake_times_out_when_server_does_not_reply() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("control.sock");
        // Bind a listener but never accept — connect succeeds at the kernel
        // level (Unix), and the subsequent handshake read will block until
        // the timeout fires.
        let _listener = UnixListener::bind(&path).expect("bind");
        let result = connect_with_handshake(
            Transport::Unix(path),
            Duration::from_millis(150),
        )
        .await;
        match result {
            Err(err) => assert_eq!(err.kind(), io::ErrorKind::TimedOut),
            Ok(_) => panic!("handshake against silent server must time out"),
        }
    }
}
