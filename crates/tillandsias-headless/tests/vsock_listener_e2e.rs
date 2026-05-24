// @trace spec:vsock-transport, spec:host-shell-architecture
//! End-to-end smoke test for `tillandsias --listen-vsock <PORT>`.
//!
//! Spawns the headless binary bound to a vsock listener on
//! `VMADDR_CID_LOCAL` (CID 1, loopback) and exchanges a `Hello` /
//! `HelloAck` round-trip from the test process. Verifies the wire version
//! agrees on both sides and that the in-VM server advertises the new
//! VM-lifecycle / cloud-refresh capabilities.
//!
//! Marked `#[ignore]` because vsock loopback requires the `vsock_loopback`
//! kernel module, which is not loaded on every developer host. To run it
//! locally:
//!
//! ```bash
//! sudo modprobe vsock_loopback
//! cargo test -p tillandsias-headless --features listen-vsock \
//!   --test vsock_listener_e2e -- --ignored
//! ```
//!
//! The test is also gated on `target_os = "linux"` and on the `listen-vsock`
//! cargo feature, so it never compiles on Windows / macOS or in default
//! builds.

#![cfg(all(target_os = "linux", feature = "listen-vsock"))]

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use tillandsias_control_wire::transport::{Transport, connect};
use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION, decode, encode,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn headless_binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_tillandsias"))
}

async fn write_envelope<W>(stream: &mut W, env: &ControlEnvelope) -> std::io::Result<()>
where
    W: AsyncWriteExt + Unpin,
{
    let bytes = encode(env)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    stream
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .await?;
    stream.write_all(&bytes).await?;
    stream.flush().await
}

async fn read_envelope<R>(stream: &mut R) -> std::io::Result<ControlEnvelope>
where
    R: AsyncReadExt + Unpin,
{
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_MESSAGE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body).await?;
    decode(&body).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}

/// @trace spec:vsock-transport
#[tokio::test]
#[ignore]
async fn test_vsock_end_to_end_localhost() {
    use tokio_vsock::VMADDR_CID_LOCAL;
    // Pick a non-conflicting port for the test (the production wire is 42420).
    const TEST_PORT: u32 = 42421;

    // Sanity-probe: try a vsock bind on the loopback CID before spawning the
    // child. If the kernel doesn't load `vsock_loopback`, fail-soft so this
    // test stays useful on hosts where loopback is supported and skip
    // gracefully on ones where it isn't.
    {
        use tokio_vsock::{VsockAddr, VsockListener};
        let addr = VsockAddr::new(VMADDR_CID_LOCAL, 0);
        if let Err(err) = VsockListener::bind(addr) {
            eprintln!(
                "[skip] vsock loopback not available on this kernel: {err} \
                 (modprobe vsock_loopback to enable)"
            );
            return;
        }
    }

    let binary = headless_binary();
    let mut child = Command::new(&binary)
        .arg("--headless")
        .arg("--listen-vsock")
        .arg(TEST_PORT.to_string())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn tillandsias --listen-vsock");
    let pid = child.id() as libc::pid_t;

    // Defer kill until the test scope ends so a panic doesn't leak the child.
    struct ChildGuard(libc::pid_t);
    impl Drop for ChildGuard {
        fn drop(&mut self) {
            unsafe { libc::kill(self.0, libc::SIGTERM) };
        }
    }
    let _guard = ChildGuard(pid);

    // Wait for the listener to come up. Retry connect with a short backoff
    // until either it succeeds or 10s elapse.
    let transport = Transport::Vsock {
        cid: VMADDR_CID_LOCAL,
        port: TEST_PORT,
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut stream = loop {
        match connect(&transport).await {
            Ok(s) => break s,
            Err(_) if Instant::now() < deadline => {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Err(err) => panic!("client connect to vsock listener failed: {err}"),
        }
    };

    // Exchange Hello / HelloAck.
    let hello = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 1,
        body: ControlMessage::Hello {
            from: "vsock-e2e-test".to_string(),
            capabilities: vec!["VmStatusRequest".to_string()],
        },
    };
    write_envelope(&mut stream, &hello)
        .await
        .expect("client write hello");
    let ack = read_envelope(&mut stream)
        .await
        .expect("client read hello ack");
    assert_eq!(ack.seq, 1, "ack seq must echo Hello seq");
    match ack.body {
        ControlMessage::HelloAck {
            wire_version,
            ref server_caps,
        } => {
            assert_eq!(wire_version, WIRE_VERSION, "wire version must match");
            assert!(
                server_caps.iter().any(|c| c == "VmStatusRequest"),
                "server caps must advertise VmStatusRequest"
            );
        }
        other => panic!("expected HelloAck, got {other:?}"),
    }

    // Drop the connection and let ChildGuard reap the spawned tillandsias.
    drop(stream);

    // Best-effort wait for child exit.
    let _ = child.wait();
}
