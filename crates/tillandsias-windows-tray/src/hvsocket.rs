//! Windows host → WSL2 guest control-wire transport over Hyper-V sockets (F2).
//!
//! The in-VM headless binds Linux **AF_VSOCK** `:42420`, but WSL2 is a Hyper-V
//! guest: the Windows host cannot `connect()` to that listener via AF_VSOCK.
//! It reaches it only through **Hyper-V sockets** (`AF_HYPERV`), addressed by
//! `(VmId, ServiceId)` where `VmId` is the WSL utility VM's GUID and
//! `ServiceId` is derived from the Linux vsock port. The guest side is
//! unchanged (plain AF_VSOCK) — only the host's connect mechanism differs from
//! macOS's real-AF_VSOCK path, so the frozen "host connects, guest binds
//! `VMADDR_CID_ANY:42420`" contract holds.
//!
//! This module owns the **pure, testable** addressing piece. The `AF_HYPERV`
//! socket `connect` + WSL-utility-VM GUID resolution (via `hcsdiag` / the HCS
//! API) layer on once the in-VM headless reaches a stable READY (cross-host
//! blocker F1 — the `Type=notify` restart loop).
//!
//! @trace plan/issues/tray-convergence-coordination.md (F2 — Windows transport)

#![allow(dead_code)]

/// The Linux kernel's vsock↔HvSocket service-GUID template suffix. A Linux
/// vsock port `P` maps to the Hyper-V service GUID
/// `PPPPPPPP-FACB-11E6-BD58-64006A7986D3`, where the leading 32 bits are the
/// port (big-endian, as rendered in GUID text form).
const VSOCK_TEMPLATE_SUFFIX: &str = "facb-11e6-bd58-64006a7986d3";

/// Derive the HvSocket service GUID (lowercase) for a Linux vsock `port`.
///
/// e.g. the control-wire port `42420` (`0xA5B4`) →
/// `0000a5b4-facb-11e6-bd58-64006a7986d3`. This is the `ServiceId` half of the
/// `AF_HYPERV` address the host connects to; the `VmId` half (the WSL utility
/// VM GUID) is resolved separately at connect time.
pub fn vsock_service_guid(port: u32) -> String {
    format!("{port:08x}-{VSOCK_TEMPLATE_SUFFIX}")
}

/// True for an `8-4-4-4-12` hex GUID (the textual form `hcsdiag` prints).
fn is_guid(s: &str) -> bool {
    let groups = [8usize, 4, 4, 4, 12];
    let parts: Vec<&str> = s.split('-').collect();
    parts.len() == groups.len()
        && parts
            .iter()
            .zip(groups)
            .all(|(p, n)| p.len() == n && p.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// Parse the WSL utility VM's GUID (`VmId`) from `hcsdiag list` output.
///
/// WSL2 runs all distros in one lightweight Hyper-V "utility VM" whose compute
/// system is named `WSL`. Its `hcsdiag list` detail row looks like:
/// `VM, <pad> Running, <GUID>, WSL`. We return the GUID from the row whose
/// trailing comma-field is `WSL` (case-insensitive) — that's the `VmId` half of
/// the `AF_HYPERV` address the host connects to.
pub fn parse_wsl_vm_id(hcsdiag_list: &str) -> Option<String> {
    for line in hcsdiag_list.lines() {
        let fields: Vec<&str> = line.split(',').map(str::trim).collect();
        let is_wsl_row = fields
            .last()
            .is_some_and(|name| name.eq_ignore_ascii_case("WSL"));
        // Only accept a GUID from the WSL row; keep scanning other rows.
        if let Some(guid) = fields.iter().find(|f| is_guid(f)).filter(|_| is_wsl_row) {
            return Some((*guid).to_string());
        }
    }
    None
}

/// Resolve the running WSL utility VM's GUID by shelling out to `hcsdiag list`.
/// Errors if `hcsdiag` is unavailable or no running `WSL` compute system exists
/// (e.g. no distro started yet).
pub fn wsl_utility_vm_id() -> Result<String, String> {
    let output = std::process::Command::new("hcsdiag")
        .arg("list")
        .output()
        .map_err(|e| format!("hcsdiag list failed to spawn: {e}"))?;
    let text = String::from_utf8_lossy(&output.stdout);
    parse_wsl_vm_id(&text).ok_or_else(|| {
        "no running WSL utility VM in `hcsdiag list` (is a distro started?)".to_string()
    })
}

/// Parse a `8-4-4-4-12` GUID string into a Win32 [`windows::core::GUID`]
/// (mixed-endian: `data1`/`data2`/`data3` are integers, `data4` is the trailing
/// 8 bytes as written). Returns `None` on a malformed GUID.
pub fn parse_guid(s: &str) -> Option<windows::core::GUID> {
    let s = s.trim().trim_start_matches('{').trim_end_matches('}');
    let p: Vec<&str> = s.split('-').collect();
    if p.len() != 5
        || p[0].len() != 8
        || p[1].len() != 4
        || p[2].len() != 4
        || p[3].len() != 4
        || p[4].len() != 12
    {
        return None;
    }
    let data1 = u32::from_str_radix(p[0], 16).ok()?;
    let data2 = u16::from_str_radix(p[1], 16).ok()?;
    let data3 = u16::from_str_radix(p[2], 16).ok()?;
    let tail = format!("{}{}", p[3], p[4]); // 16 hex = 8 bytes, big-endian
    let mut data4 = [0u8; 8];
    for (i, b) in data4.iter_mut().enumerate() {
        *b = u8::from_str_radix(&tail[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(windows::core::GUID {
        data1,
        data2,
        data3,
        data4,
    })
}

/// Connect to the in-VM control wire over a **Hyper-V socket** (`AF_HYPERV`) —
/// the Windows-host realization of "connect to the guest's AF_VSOCK listener"
/// for WSL2. Resolves the WSL utility-VM GUID + the vsock-port service GUID,
/// opens an `AF_HYPERV` / `HV_PROTOCOL_RAW` stream socket, and `connect`s to
/// `(VmId, ServiceId)`. Returns the connected socket as a [`std::net::TcpStream`]
/// (a thin wrapper over the OS `SOCKET`; stream read/write work regardless of
/// address family) so the control-wire framing can run over it.
///
/// @trace plan/issues/tray-convergence-coordination.md (F2)
#[cfg(target_os = "windows")]
pub fn connect_control_wire(port: u32) -> std::io::Result<std::net::TcpStream> {
    use std::io::{Error, ErrorKind};
    use std::os::windows::io::FromRawSocket;
    use windows::Win32::Networking::WinSock::{
        SOCK_STREAM, SOCKADDR, WSACleanup, WSADATA, WSAGetLastError, WSAStartup, closesocket,
        connect, socket,
    };

    const AF_HYPERV: u16 = 34;
    const HV_PROTOCOL_RAW: i32 = 1;

    /// `SOCKADDR_HV` (hvsocket.h): family + reserved + 16-byte VmId + 16-byte
    /// ServiceId GUIDs = 36 bytes.
    #[repr(C)]
    struct SockaddrHv {
        family: u16,
        reserved: u16,
        vm_id: windows::core::GUID,
        service_id: windows::core::GUID,
    }

    let vm = wsl_utility_vm_id().map_err(|e| Error::new(ErrorKind::NotFound, e))?;
    let vm_guid =
        parse_guid(&vm).ok_or_else(|| Error::new(ErrorKind::InvalidData, "bad WSL VM GUID"))?;
    let svc_guid = parse_guid(&vsock_service_guid(port))
        .ok_or_else(|| Error::new(ErrorKind::InvalidData, "bad service GUID"))?;

    unsafe {
        let mut wsadata = WSADATA::default();
        if WSAStartup(0x0202, &mut wsadata) != 0 {
            return Err(Error::other("WSAStartup failed"));
        }
        let sock = match socket(AF_HYPERV as i32, SOCK_STREAM, HV_PROTOCOL_RAW) {
            Ok(s) => s,
            Err(e) => {
                WSACleanup();
                return Err(Error::other(format!("AF_HYPERV socket() failed: {e}")));
            }
        };
        let addr = SockaddrHv {
            family: AF_HYPERV,
            reserved: 0,
            vm_id: vm_guid,
            service_id: svc_guid,
        };
        let rc = connect(
            sock,
            &addr as *const SockaddrHv as *const SOCKADDR,
            std::mem::size_of::<SockaddrHv>() as i32,
        );
        if rc != 0 {
            let e = WSAGetLastError();
            let _ = closesocket(sock);
            return Err(Error::other(format!(
                "AF_HYPERV connect to WSL VM (vsock {port}) failed: {e:?}"
            )));
        }
        // Ownership of the connected SOCKET transfers to the TcpStream.
        Ok(std::net::TcpStream::from_raw_socket(sock.0 as _))
    }
}

/// Connect over HvSocket and run the control-wire `Hello`/`HelloAck` handshake,
/// returning the negotiated wire version. Proves the FULL Windows host→guest
/// control wire end-to-end: transport (`AF_HYPERV`) + protocol (the
/// `tillandsias-control-wire` envelope codec). The connected stream is returned
/// for the caller to keep for the session.
///
/// @trace plan/issues/tray-convergence-coordination.md (F2), spec:vsock-transport
/// Open an HvSocket connection to the in-VM AF_VSOCK port (via AF_HYPERV) and
/// return it as a tokio TCP stream — a thin wrapper over the OS socket; stream
/// I/O works regardless of address family. Does NOT perform the
/// `Hello`/`HelloAck` handshake — wrap this in
/// `tillandsias_host_shell::vsock_client::Client::from_stream` and call
/// `client.handshake().await` for the standard wire protocol (the macOS tray
/// drives the same shared `Client` over its `VZVirtioSocketConnection` stream;
/// slice 4 `80d9196e`).
///
/// @trace plan/issues/tray-convergence-coordination.md (F2), spec:vsock-transport
#[cfg(target_os = "windows")]
pub async fn open_hvsocket_stream(port: u32) -> std::io::Result<tokio::net::TcpStream> {
    let std_stream = connect_control_wire(port)?;
    std_stream.set_nonblocking(true)?;
    tokio::net::TcpStream::from_std(std_stream)
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
            capabilities: vec![
                "VmStatusRequest".to_string(),
                "EnumerateLocalProjects".to_string(),
            ],
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
        ControlMessage::HelloAck { wire_version, .. } => {
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
