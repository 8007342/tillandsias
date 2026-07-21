//! Windows host → WSL2 guest control-wire transport over Hyper-V sockets (F2).
//!
//! **Connection primitives** (`vsock_service_guid`, `parse_wsl_vm_id`,
//! `parse_guid`, `wsl_utility_vm_id`, `wsa_startup`, `connect_control_wire`,
//! `open_hvsocket_stream`) now live in
//! `tillandsias_vm_layer::transport_windows` — the canonical home for the
//! `GuestTransport` backend (order 127). This module re-exports them so
//! existing tray call sites need no changes, and adds the protocol-level helpers
//! (`hvsocket_handshake`, `hvsocket_request`, …) that are tray-specific.
//!
//! @trace spec:host-guest-transport, plan/issues/tray-convergence-coordination.md (F2)

// Re-export the canonical primitives from the vm-layer GuestTransport backend.
// These are public API consumed by tests (via `super::*`) and future callers.
#[allow(unused_imports)]
pub use tillandsias_vm_layer::transport_windows::{
    WirePath, connect_control_wire, open_hvsocket_stream, open_wsl_stdio_bridge,
    open_wsl_wire_stream, parse_guid, parse_wsl_vm_id, vsock_service_guid, wire_path, wsa_startup,
    wsl_utility_vm_id,
};

#[cfg(target_os = "windows")]
pub async fn open_and_wrap_hvsocket_stream(
    port: u32,
) -> std::io::Result<Box<dyn tillandsias_control_wire::transport::AsyncReadWrite + Unpin + Send>> {
    // Privilege-routed (order 312): elevated → direct AF_HYPERV; standard
    // user → wsl.exe/socat stdio bridge. Same wire either way.
    let stream = open_wsl_wire_stream(port).await?;
    if std::env::var("TILLANDSIAS_SECURE_CONTROL_WIRE").as_deref() == Ok("on") {
        let psk = tillandsias_secure_channel::channel_psk(
            env!("WORKSPACE_VERSION"),
            tillandsias_control_wire::WIRE_VERSION,
            tillandsias_secure_channel::HopId::HostGuest,
        );
        let encrypted = tillandsias_secure_channel::client_handshake(stream, &psk)
            .await
            .map_err(|e| std::io::Error::other(format!("secure handshake failed: {e}")))?;
        Ok(Box::new(encrypted))
    } else {
        Ok(Box::new(stream))
    }
}

#[cfg(target_os = "windows")]
pub async fn hvsocket_handshake(port: u32) -> std::io::Result<(tokio::net::TcpStream, u16)> {
    use std::io::{Error, ErrorKind};
    use tillandsias_control_wire::{
        ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION, decode, encode,
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let mut stream = open_hvsocket_stream(port).await?;

    let hello = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 1,
        body: ControlMessage::Hello {
            from: "tillandsias-windows-tray".to_string(),
            capabilities: tillandsias_host_shell::vsock_client::STANDARD_HOST_CAPABILITIES
                .iter()
                .map(|s| s.to_string())
                .collect(),
            build_version: None,
        },
    };
    let bytes = encode(&hello).map_err(|e| Error::new(ErrorKind::InvalidData, e))?;
    stream
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .await?;
    stream.write_all(&bytes).await?;
    stream.flush().await?;

    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_MESSAGE_BYTES {
        return Err(Error::new(
            ErrorKind::InvalidData,
            "inbound frame too large",
        ));
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body).await?;
    let ack = decode(&body).map_err(|e| Error::new(ErrorKind::InvalidData, e))?;
    match ack.body {
        ControlMessage::HelloAck {
            wire_version,
            build_version: _,
            ..
        } => {
            if wire_version != WIRE_VERSION {
                return Err(Error::new(
                    ErrorKind::InvalidData,
                    format!("wire version mismatch: local={WIRE_VERSION} server={wire_version}"),
                ));
            }
            Ok((stream, wire_version))
        }
        other => Err(Error::new(
            ErrorKind::InvalidData,
            format!("expected HelloAck, got {other:?}"),
        )),
    }
}

/// Send one control-wire request envelope over a connected stream and read the
/// next reply envelope (same 4-byte-length + postcard framing as the handshake).
/// The building block for w9 menu-action routing (VmStatus / EnumerateLocalProjects
/// / PTY-attach) over the live HvSocket control wire.
///
/// @trace plan/issues/tray-convergence-coordination.md (w9), spec:vsock-transport
#[cfg(target_os = "windows")]
pub async fn hvsocket_request(
    stream: &mut tokio::net::TcpStream,
    seq: u64,
    body: tillandsias_control_wire::ControlMessage,
) -> std::io::Result<tillandsias_control_wire::ControlEnvelope> {
    hvsocket_send(stream, seq, body).await?;
    hvsocket_read_envelope(stream).await
}

/// Send one control-wire request envelope over a connected stream (no reply
/// read). Used for fire-and-forward frames like `PtyOpen` / `PtyData{ToGuest}`
/// (stdin) / `PtyClose`, where replies arrive asynchronously and are pumped
/// separately via [`hvsocket_read_envelope`].
///
/// @trace plan/issues/tray-convergence-coordination.md (w9), spec:vsock-transport
#[cfg(target_os = "windows")]
pub async fn hvsocket_send(
    stream: &mut tokio::net::TcpStream,
    seq: u64,
    body: tillandsias_control_wire::ControlMessage,
) -> std::io::Result<()> {
    use std::io::{Error, ErrorKind};
    use tillandsias_control_wire::{ControlEnvelope, WIRE_VERSION, encode};
    use tokio::io::AsyncWriteExt;

    let env = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq,
        body,
    };
    let bytes = encode(&env).map_err(|e| Error::new(ErrorKind::InvalidData, e))?;
    stream
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .await?;
    stream.write_all(&bytes).await?;
    stream.flush().await
}

/// Read one control-wire envelope from a connected stream (4-byte length +
/// postcard). The streaming-read counterpart to [`hvsocket_request`], used to
/// pump multi-frame exchanges like a PTY session (`PtyData` … `PtyClose`).
///
/// @trace plan/issues/tray-convergence-coordination.md (w9), spec:vsock-transport
#[cfg(target_os = "windows")]
pub async fn hvsocket_read_envelope(
    stream: &mut tokio::net::TcpStream,
) -> std::io::Result<tillandsias_control_wire::ControlEnvelope> {
    use std::io::{Error, ErrorKind};
    use tillandsias_control_wire::{MAX_MESSAGE_BYTES, decode};
    use tokio::io::AsyncReadExt;

    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_MESSAGE_BYTES {
        return Err(Error::new(
            ErrorKind::InvalidData,
            "inbound frame too large",
        ));
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body).await?;
    decode(&body).map_err(|e| Error::new(ErrorKind::InvalidData, e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_guid_mixed_endian() {
        let g = parse_guid("A5A7CF6F-FFF6-4EA9-B4A3-9557B0D5B0CA").expect("valid guid");
        assert_eq!(g.data1, 0xA5A7_CF6F);
        assert_eq!(g.data2, 0xFFF6);
        assert_eq!(g.data3, 0x4EA9);
        assert_eq!(g.data4, [0xB4, 0xA3, 0x95, 0x57, 0xB0, 0xD5, 0xB0, 0xCA]);
    }

    #[test]
    fn rejects_malformed_guid() {
        assert!(parse_guid("not-a-guid").is_none());
        assert!(parse_guid("A5A7CF6F-FFF6-4EA9-B4A3").is_none());
    }

    #[test]
    fn control_wire_port_maps_to_expected_service_guid() {
        // tillandsias control-wire port: 42420 = 0xA5B4.
        assert_eq!(
            vsock_service_guid(42420),
            "0000a5b4-facb-11e6-bd58-64006a7986d3"
        );
    }

    #[test]
    fn service_guid_is_zero_padded_eight_hex() {
        assert_eq!(
            vsock_service_guid(1),
            "00000001-facb-11e6-bd58-64006a7986d3"
        );
        // A full 32-bit port renders all 8 hex digits.
        assert_eq!(
            vsock_service_guid(0xDEAD_BEEF),
            "deadbeef-facb-11e6-bd58-64006a7986d3"
        );
    }

    // Verbatim `hcsdiag list` output captured on the dev host (WSL2 2.7.3.0):
    // a bare GUID line followed by the indented detail row ending in `WSL`.
    const HCSDIAG_FIXTURE: &str = "A5A7CF6F-FFF6-4EA9-B4A3-9557B0D5B0CA\n\
         \x20\x20\x20\x20VM,                       \tRunning, A5A7CF6F-FFF6-4EA9-B4A3-9557B0D5B0CA, WSL\n";

    #[test]
    fn parses_wsl_utility_vm_id() {
        assert_eq!(
            parse_wsl_vm_id(HCSDIAG_FIXTURE).as_deref(),
            Some("A5A7CF6F-FFF6-4EA9-B4A3-9557B0D5B0CA")
        );
    }

    #[test]
    fn ignores_non_wsl_compute_systems() {
        let other = "11111111-2222-3333-4444-555555555555\n    \
                     VM, Running, 11111111-2222-3333-4444-555555555555, SomeOtherVM\n";
        assert_eq!(parse_wsl_vm_id(other), None);
    }

    #[test]
    fn none_when_no_vm_running() {
        assert_eq!(parse_wsl_vm_id(""), None);
    }

    /// Regression guard for the hard-reset bug: `open_hvsocket_stream` must not
    /// block the tokio `current_thread` executor even when AF_HYPERV `connect()`
    /// stalls for a long time (the original hang scenario). The guard works by
    /// spawning a concurrent task that sets a flag after a short sleep; if the
    /// executor is blocked, the task never runs and the assertion fires.
    ///
    /// Port 42421 is not the control-wire port. AF_HYPERV connects to
    /// non-listening ports may hang for many seconds — that is fine; we only care
    /// that the executor stays alive (i.e., the connect runs in `spawn_blocking`).
    #[cfg(target_os = "windows")]
    #[tokio::test(flavor = "current_thread")]
    async fn blocking_connect_does_not_hang_executor() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::time::Duration;

        let executor_alive = Arc::new(AtomicBool::new(false));
        let flag = executor_alive.clone();

        // This task can only make progress when the executor is free. On a
        // current_thread runtime it runs between await-yields of the main task.
        // Without spawn_blocking, connect_control_wire blocks the executor
        // thread and this task never runs.
        let bg = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            flag.store(true, Ordering::Relaxed);
        });

        // Bound the connect so the test does not run for minutes.
        let _ = tokio::time::timeout(Duration::from_secs(5), open_hvsocket_stream(42421)).await;

        // bg should have finished long ago; give it a short grace period.
        let _ = tokio::time::timeout(Duration::from_millis(500), bg).await;

        assert!(
            executor_alive.load(Ordering::Relaxed),
            "executor was blocked during open_hvsocket_stream — \
             spawn_blocking wrapper is missing or broken"
        );
    }

    /// Live round-trip proof (F2): with a running WSL distro whose
    /// `tillandsias-headless.service` is `active` on vsock 42420, the host
    /// resolves the VM GUID + service GUID and establishes an `AF_HYPERV`
    /// connection to the in-VM listener. Run explicitly:
    /// `cargo test -p tillandsias-windows-tray -- --ignored hvsocket`.
    #[cfg(target_os = "windows")]
    #[test]
    #[ignore = "needs a running WSL distro with the headless listening on vsock 42420"]
    fn e2e_hvsocket_connects_to_headless() {
        let stream = connect_control_wire(42420)
            .expect("AF_HYPERV connect to the in-VM headless vsock listener");
        // Connection established = the full F2 path works (VM-GUID + service-GUID
        // + AF_HYPERV connect → guest AF_VSOCK listener).
        println!("HvSocket connected to in-VM headless: {stream:?}");
    }

    /// Full host→guest control-wire proof: HvSocket connect + `Hello`/`HelloAck`
    /// against the live in-VM headless. Run explicitly with a distro up:
    /// `cargo test -p tillandsias-windows-tray -- --ignored hvsocket_handshake`.
    #[cfg(target_os = "windows")]
    #[tokio::test]
    #[ignore = "needs a running WSL distro with the headless listening on vsock 42420"]
    async fn e2e_hvsocket_handshake() {
        let (_stream, wire_version) = hvsocket_handshake(42420)
            .await
            .expect("control-wire Hello/HelloAck over HvSocket");
        println!("control wire UP over HvSocket; negotiated wire_version={wire_version}");
        assert_eq!(wire_version, tillandsias_control_wire::WIRE_VERSION);
    }

    /// w9 probe: after the handshake, send `VmStatusRequest` over the live wire
    /// and read the reply — proves the request/response routing path the menu
    /// will use, and confirms which requests the in-VM headless answers. Run:
    /// `cargo test -p tillandsias-windows-tray -- --ignored vm_status_over_hvsocket`.
    #[cfg(target_os = "windows")]
    #[tokio::test]
    #[ignore = "needs a running WSL distro with the headless listening on vsock 42420"]
    async fn e2e_vm_status_over_hvsocket() {
        use tillandsias_control_wire::ControlMessage;
        let (mut stream, _) = hvsocket_handshake(42420).await.expect("handshake");
        let reply = hvsocket_request(&mut stream, 2, ControlMessage::VmStatusRequest { seq: 2 })
            .await
            .expect("VmStatusRequest round-trip");
        println!("VmStatusRequest reply over HvSocket: {:?}", reply.body);
    }

    /// w9 PTY-attach probe: open a PTY in the VM running a short command and
    /// pump the output frames back to `PtyClose`. Proves the in-VM headless's
    /// PTY-attach (the mechanism behind Open Shell / agents). Run:
    /// `cargo test -p tillandsias-windows-tray -- --ignored pty_attach_over_hvsocket`.
    #[cfg(target_os = "windows")]
    #[tokio::test]
    #[ignore = "needs a running WSL distro with the headless listening on vsock 42420"]
    async fn e2e_pty_attach_over_hvsocket() {
        use tillandsias_control_wire::{ControlMessage, PtyDirection};

        let (mut stream, _) = hvsocket_handshake(42420).await.expect("handshake");
        // Open a PTY running a command that prints a marker and exits.
        let first = hvsocket_request(
            &mut stream,
            2,
            ControlMessage::PtyOpen {
                session_id: 1,
                rows: 24,
                cols: 80,
                argv: vec!["/bin/echo".into(), "tillandsias-pty-ok".into()],
                env: vec![("TERM".into(), "xterm-256color".into())],
                cwd: None,
            },
        )
        .await
        .expect("PtyOpen round-trip");

        let mut output = Vec::new();
        let mut env = first;
        loop {
            match env.body {
                ControlMessage::PtyData {
                    direction: PtyDirection::ToHost,
                    bytes,
                    ..
                } => output.extend_from_slice(&bytes),
                ControlMessage::PtyClose { exit, .. } => {
                    println!(
                        "PTY closed: exit={:?}; output={:?}",
                        exit,
                        String::from_utf8_lossy(&output)
                    );
                    break;
                }
                other => println!("PTY frame: {other:?}"),
            }
            env = hvsocket_read_envelope(&mut stream)
                .await
                .expect("read PTY frame");
        }
        assert!(
            String::from_utf8_lossy(&output).contains("tillandsias-pty-ok"),
            "expected PTY output to contain the marker; got {:?}",
            String::from_utf8_lossy(&output)
        );
    }

    /// Secure-wire flag-ON proof (order 191, windows evidence slice): with the
    /// in-VM headless running a version-matched binary under
    /// `TILLANDSIAS_SECURE_CONTROL_WIRE=on`, the tray-side wrapper
    /// (`open_and_wrap_hvsocket_stream`) completes the Noise NNpsk0 handshake
    /// and a full Hello/HelloAck + `VmStatusRequest` round-trip over the
    /// encrypted stream. Run with the flag exported on the host:
    /// `$env:TILLANDSIAS_SECURE_CONTROL_WIRE='on'; cargo test -p tillandsias-windows-tray -- --ignored secure_vm_status`.
    #[cfg(target_os = "windows")]
    #[tokio::test]
    #[ignore = "needs a running WSL distro with a version-matched headless under TILLANDSIAS_SECURE_CONTROL_WIRE=on"]
    async fn e2e_secure_vm_status_over_hvsocket() {
        use tillandsias_control_wire::transport::Transport;
        use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
        use tillandsias_host_shell::vsock_client::Client;

        assert_eq!(
            std::env::var("TILLANDSIAS_SECURE_CONTROL_WIRE").as_deref(),
            Ok("on"),
            "export TILLANDSIAS_SECURE_CONTROL_WIRE=on so the wrapper takes the secure path"
        );

        let stream = open_and_wrap_hvsocket_stream(42420)
            .await
            .expect("HvSocket open + Noise client handshake (secure wrapper)");
        let mut client = Client::from_stream(
            stream,
            Transport::Vsock {
                cid: 0,
                port: 42420,
            },
        );
        let wire_version = client
            .handshake()
            .await
            .expect("Hello/HelloAck over the encrypted stream");
        assert_eq!(wire_version, WIRE_VERSION);
        let seq = client.allocate_seq();
        let env = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::VmStatusRequest { seq },
        };
        let reply = client
            .request(&env)
            .await
            .expect("VmStatusRequest over the encrypted stream");
        println!("secure control wire UP; VmStatus reply: {:?}", reply.body);
        assert!(
            matches!(reply.body, ControlMessage::VmStatusReply { .. }),
            "expected VmStatusReply, got {:?}",
            reply.body
        );
    }

    /// w9 bidirectional probe: open `cat` in a PTY, write to its **stdin**
    /// (host→guest `PtyData{ToGuest}`), and read the echo back
    /// (guest→host `PtyData{ToHost}`). Proves the last unproven data direction —
    /// host→guest stdin — i.e. the full interactive Open Shell data path. Run:
    /// `cargo test -p tillandsias-windows-tray -- --ignored pty_bidirectional`.
    #[cfg(target_os = "windows")]
    #[tokio::test]
    #[ignore = "needs a running WSL distro with the headless listening on vsock 42420"]
    async fn e2e_pty_bidirectional_over_hvsocket() {
        use tillandsias_control_wire::{ControlMessage, PtyDirection, PtyExit};

        let (mut stream, _) = hvsocket_handshake(42420).await.expect("handshake");
        // `cat` echoes stdin → stdout.
        hvsocket_send(
            &mut stream,
            2,
            ControlMessage::PtyOpen {
                session_id: 1,
                rows: 24,
                cols: 80,
                argv: vec!["/bin/cat".into()],
                env: vec![("TERM".into(), "xterm-256color".into())],
                cwd: None,
            },
        )
        .await
        .expect("PtyOpen cat");

        // Host → guest stdin.
        let marker = "tillandsias-stdin-ok\n";
        hvsocket_send(
            &mut stream,
            3,
            ControlMessage::PtyData {
                session_id: 1,
                direction: PtyDirection::ToGuest,
                bytes: marker.as_bytes().to_vec(),
            },
        )
        .await
        .expect("PtyData ToGuest (stdin)");

        // Read echoed stdout until the marker round-trips.
        let mut out = Vec::new();
        while !String::from_utf8_lossy(&out).contains("tillandsias-stdin-ok") {
            let env = hvsocket_read_envelope(&mut stream)
                .await
                .expect("read frame");
            if let ControlMessage::PtyData {
                direction: PtyDirection::ToHost,
                bytes,
                ..
            } = env.body
            {
                out.extend_from_slice(&bytes);
            }
        }
        println!(
            "bidirectional PTY over HvSocket — stdin echoed back: {:?}",
            String::from_utf8_lossy(&out)
        );
        // Terminate the session (host-initiated close).
        let _ = hvsocket_send(
            &mut stream,
            4,
            ControlMessage::PtyClose {
                session_id: 1,
                exit: PtyExit {
                    code: 0,
                    signal: None,
                },
            },
        )
        .await;
    }
}
