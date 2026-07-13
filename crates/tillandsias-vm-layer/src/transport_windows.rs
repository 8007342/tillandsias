// @trace spec:host-guest-transport
//! Windows host→guest transport backend for WSL2 / Hyper-V sockets.
//!
//! Implements the [`GuestTransport`] facade (order 124) for
//! `GuestEndpoint::Wsl { port }`. The transport is an `AF_HYPERV` socket that
//! bridges the host's Win32 Hyper-V network to the guest's `AF_VSOCK` listener.
//!
//! **Core connection primitives** (GUID derivation, `WSAStartup`, socket
//! create/connect) live here in `tillandsias-vm-layer` so both this backend
//! **and** the Windows tray's `hvsocket.rs` can import them, avoiding
//! duplication. The tray re-exports the primitives it needs from this crate
//! (no cycle: `tillandsias-vm-layer` does not depend on
//! `tillandsias-windows-tray`).
//!
//! [`GuestTransport`]: tillandsias_control_wire::guest_transport::GuestTransport

#![cfg(target_os = "windows")]

use std::io;
use std::os::windows::io::FromRawSocket;
use std::sync::OnceLock;

use async_trait::async_trait;
use tillandsias_control_wire::guest_transport::{
    ExecChunk, ExecOutput, ExecRequest, GuestEndpoint, GuestTransport,
};
use tillandsias_control_wire::transport::AsyncReadWrite;
use windows::Win32::Networking::WinSock::{
    SOCK_STREAM, SOCKADDR, WSADATA, WSAGetLastError, WSAStartup, closesocket, connect, setsockopt,
    socket,
};

// ─── GUID / addressing helpers ────────────────────────────────────────────────

/// The Linux kernel's vsock↔HvSocket service-GUID template suffix.
/// A Linux vsock port `P` maps to the Hyper-V service GUID
/// `PPPPPPPP-FACB-11E6-BD58-64006A7986D3`.
const VSOCK_TEMPLATE_SUFFIX: &str = "facb-11e6-bd58-64006a7986d3";

/// Derive the HvSocket service GUID (lowercase) for a Linux vsock `port`.
pub fn vsock_service_guid(port: u32) -> String {
    format!("{port:08x}-{VSOCK_TEMPLATE_SUFFIX}")
}

fn is_guid(s: &str) -> bool {
    let groups = [8usize, 4, 4, 4, 12];
    let parts: Vec<&str> = s.split('-').collect();
    parts.len() == groups.len()
        && parts
            .iter()
            .zip(groups)
            .all(|(p, n)| p.len() == n && p.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// Parse the WSL utility VM's GUID from `hcsdiag list` output.
///
/// Tolerates UTF-16LE-as-lossy-UTF-8 output (interleaved NULs): Windows
/// tooling can emit UTF-16 when stdout is a pipe from a GUI-subsystem
/// parent, and a NUL-interleaved `W\0S\0L` row never matches — the
/// 2026-07-12 operator session saw 3 minutes of "no running WSL utility
/// VM" while the VM was demonstrably up and held by the keepalive. Same
/// discipline as `WslRuntime::wsl_list_quiet`'s NUL strip.
pub fn parse_wsl_vm_id(hcsdiag_list: &str) -> Option<String> {
    let cleaned = hcsdiag_list.replace('\u{0}', "");
    for line in cleaned.lines() {
        let fields: Vec<&str> = line.split(',').map(str::trim).collect();
        let is_wsl_row = fields
            .last()
            .is_some_and(|name| name.eq_ignore_ascii_case("WSL"));
        if let Some(guid) = fields.iter().find(|f| is_guid(f)).filter(|_| is_wsl_row) {
            return Some((*guid).to_string());
        }
    }
    None
}

/// True when the current process can query HCS: an ENABLED membership in
/// BUILTIN\Administrators or Hyper-V Administrators. This is exactly the
/// check `hcsdiag` enforces ("insufficient privileges … administrators or
/// Hyper-V Administrators"), so the VM-ID lookup can distinguish "no VM
/// running" from "no rights to look". Membership (CheckTokenMembership),
/// NOT TokenElevation: filtered/restricted tokens carry the admin group
/// deny-only, which membership correctly reports as false while the
/// elevation flag can still read true.
/// @trace plan/index.yaml windows-tray-requires-elevation-hcsdiag (order 312)
pub fn process_can_query_hcs() -> bool {
    use windows::Win32::Foundation::BOOL;
    use windows::Win32::Security::{
        CheckTokenMembership, CreateWellKnownSid, PSID, WELL_KNOWN_SID_TYPE,
        WinBuiltinAdministratorsSid, WinBuiltinHyperVAdminsSid,
    };

    fn is_member(kind: WELL_KNOWN_SID_TYPE) -> bool {
        // SECURITY_MAX_SID_SIZE is 68 bytes.
        let mut sid_buf = [0u8; 68];
        let mut sid_len = sid_buf.len() as u32;
        unsafe {
            let sid = PSID(sid_buf.as_mut_ptr() as *mut _);
            if CreateWellKnownSid(kind, None, sid, &mut sid_len).is_err() {
                return false;
            }
            let mut member = BOOL(0);
            CheckTokenMembership(None, sid, &mut member).is_ok() && member.as_bool()
        }
    }

    is_member(WinBuiltinAdministratorsSid) || is_member(WinBuiltinHyperVAdminsSid)
}

/// The error a failed VM-ID lookup surfaces, classified by elevation.
/// Pure so the actionable text is unit-testable: a non-elevated process
/// gets the order-312 remediation, not the misleading "distro not
/// started?" that burned a full 36x5s handshake budget on the 2026-07-12
/// attended smoke.
fn vm_id_lookup_error(elevated: bool) -> io::Error {
    if elevated {
        io::Error::other("no running WSL utility VM in `hcsdiag list` (distro not started?)")
    } else {
        io::Error::other(
            "cannot enumerate the WSL utility VM: this process is NOT elevated, and \
             `hcsdiag` requires Administrator or 'Hyper-V Administrators' membership \
             (https://aka.ms/hcsadmin). Relaunch Tillandsias as administrator, or add \
             your user to the Hyper-V Administrators group and sign out/in (order 312).",
        )
    }
}

/// Shell out to `hcsdiag list` and return the WSL utility VM's GUID.
pub fn wsl_utility_vm_id() -> io::Result<String> {
    // no_window: this runs once per handshake attempt from the GUI tray —
    // without CREATE_NO_WINDOW each retry flashed a console (2026-07-12).
    let mut cmd = std::process::Command::new("hcsdiag");
    cmd.arg("list");
    crate::no_window_sync(&mut cmd);
    let output = cmd
        .output()
        .map_err(|e| io::Error::other(format!("hcsdiag list failed: {e}")))?;
    let text = String::from_utf8_lossy(&output.stdout);
    parse_wsl_vm_id(&text).ok_or_else(|| vm_id_lookup_error(process_can_query_hcs()))
}

/// Parse an `8-4-4-4-12` GUID string into a Win32 [`windows::core::GUID`].
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
    let tail = format!("{}{}", p[3], p[4]);
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

// ─── Winsock init ─────────────────────────────────────────────────────────────

static WSA_INIT: OnceLock<Result<(), i32>> = OnceLock::new();

/// Initialise the Winsock runtime (WSA 2.2) exactly once; idempotent.
pub fn wsa_startup() -> io::Result<()> {
    let r = WSA_INIT.get_or_init(|| {
        let mut data = WSADATA::default();
        let rc = unsafe { WSAStartup(0x0202, &mut data) };
        if rc != 0 { Err(rc) } else { Ok(()) }
    });
    r.as_ref()
        .copied()
        .map_err(|rc| io::Error::other(format!("WSAStartup failed: {rc}")))
}

// ─── Raw AF_HYPERV connect ────────────────────────────────────────────────────

const AF_HYPERV: u16 = 34;
const HV_PROTOCOL_RAW: i32 = 1;
const SOL_SOCKET: i32 = 0xFFFF;
const SO_SNDTIMEO: i32 = 0x1005;

#[repr(C)]
struct SockaddrHv {
    family: u16,
    reserved: u16,
    vm_id: windows::core::GUID,
    service_id: windows::core::GUID,
}

/// Open an `AF_HYPERV` socket and connect to the WSL2 guest's vsock listener
/// on `port`. Returns a [`std::net::TcpStream`] wrapping the SOCKET handle.
///
/// **Blocking** — always call from `tokio::task::spawn_blocking`.
pub fn connect_control_wire(port: u32) -> io::Result<std::net::TcpStream> {
    let vm = wsl_utility_vm_id()?;
    let vm_guid = parse_guid(&vm).ok_or_else(|| io::Error::other("bad WSL VM GUID"))?;
    let svc_guid = parse_guid(&vsock_service_guid(port))
        .ok_or_else(|| io::Error::other("bad service GUID"))?;

    wsa_startup()?;
    unsafe {
        let sock = match socket(AF_HYPERV as i32, SOCK_STREAM, HV_PROTOCOL_RAW) {
            Ok(s) => s,
            Err(e) => return Err(io::Error::other(format!("AF_HYPERV socket() failed: {e}"))),
        };
        let timeout_ms: u32 = 5_000;
        let _ = setsockopt(
            sock,
            SOL_SOCKET,
            SO_SNDTIMEO,
            Some(std::slice::from_raw_parts(
                &timeout_ms as *const u32 as *const u8,
                std::mem::size_of::<u32>(),
            )),
        );
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
            return Err(io::Error::other(format!(
                "AF_HYPERV connect to WSL VM (vsock {port}) failed: {e:?}"
            )));
        }
        Ok(std::net::TcpStream::from_raw_socket(sock.0 as _))
    }
}

/// Async wrapper: `connect_control_wire` in `spawn_blocking`, then set
/// non-blocking and wrap as a tokio `TcpStream`.
pub async fn open_hvsocket_stream(port: u32) -> io::Result<tokio::net::TcpStream> {
    let std_stream = tokio::task::spawn_blocking(move || connect_control_wire(port))
        .await
        .map_err(|e| io::Error::other(format!("spawn_blocking panicked: {e}")))??;
    std_stream.set_nonblocking(true)?;
    tokio::net::TcpStream::from_std(std_stream)
}

// ─── GuestTransport implementation ───────────────────────────────────────────

/// Windows WSL2/HvSocket backend for the [`GuestTransport`] facade.
///
/// `GuestEndpoint::Wsl { port }` is the only supported variant.
pub struct WslGuestTransport;

#[async_trait]
impl GuestTransport for WslGuestTransport {
    async fn open_stream(
        &self,
        ep: &GuestEndpoint,
    ) -> io::Result<Box<dyn AsyncReadWrite + Unpin + Send>> {
        let port = wsl_port(ep)?;
        let stream = open_hvsocket_stream(port).await?;
        Ok(Box::new(stream))
    }

    async fn exec(&self, ep: &GuestEndpoint, req: ExecRequest) -> io::Result<ExecOutput> {
        let port = wsl_port(ep)?;
        let argv_refs: Vec<&str> = req.argv.iter().map(String::as_str).collect();
        let stdin = req.stdin.unwrap_or_default();

        let stream = open_hvsocket_stream(port).await?;
        let out = crate::vsock_exec::exec_over_stream_with_input(stream, &argv_refs, &stdin)
            .await
            .map_err(io::Error::other)?;

        Ok(ExecOutput {
            stdout: out.stdout,
            stderr: vec![],
            exit_code: out.exit.code,
        })
    }

    async fn exec_streaming(
        &self,
        ep: &GuestEndpoint,
        req: ExecRequest,
        on_chunk: &mut (dyn FnMut(ExecChunk) + Send),
    ) -> io::Result<ExecOutput> {
        let port = wsl_port(ep)?;
        let argv_refs: Vec<&str> = req.argv.iter().map(String::as_str).collect();
        let stdin = req.stdin.unwrap_or_default();

        let stream = open_hvsocket_stream(port).await?;
        let out = crate::vsock_exec::exec_over_stream_with_input_streaming(
            stream,
            &argv_refs,
            &stdin,
            |bytes: &[u8]| on_chunk(ExecChunk::Stdout(bytes.to_vec())),
        )
        .await
        .map_err(io::Error::other)?;

        Ok(ExecOutput {
            stdout: out.stdout,
            stderr: vec![],
            exit_code: out.exit.code,
        })
    }
}

fn wsl_port(ep: &GuestEndpoint) -> io::Result<u32> {
    match ep {
        GuestEndpoint::Wsl { port } => Ok(*port),
        other => Err(io::Error::other(format!(
            "WslGuestTransport: unsupported endpoint {other:?}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vsock_service_guid_format() {
        assert_eq!(
            vsock_service_guid(42420),
            "0000a5b4-facb-11e6-bd58-64006a7986d3"
        );
    }

    #[test]
    fn parse_guid_mixed_endian() {
        let g = parse_guid("A5A7CF6F-FFF6-4EA9-B4A3-9557B0D5B0CA").expect("valid guid");
        assert_eq!(g.data1, 0xA5A7_CF6F);
        assert_eq!(g.data2, 0xFFF6);
        assert_eq!(g.data3, 0x4EA9);
        assert_eq!(g.data4, [0xB4, 0xA3, 0x95, 0x57, 0xB0, 0xD5, 0xB0, 0xCA]);
    }

    #[test]
    fn parse_wsl_vm_id_from_hcsdiag() {
        const FIXTURE: &str = "A5A7CF6F-FFF6-4EA9-B4A3-9557B0D5B0CA\n\
             \x20\x20\x20\x20VM,                       \tRunning, A5A7CF6F-FFF6-4EA9-B4A3-9557B0D5B0CA, WSL\n";
        assert_eq!(
            parse_wsl_vm_id(FIXTURE).as_deref(),
            Some("A5A7CF6F-FFF6-4EA9-B4A3-9557B0D5B0CA")
        );
    }

    /// Order 312: a non-elevated lookup failure must surface the
    /// remediation (Hyper-V Administrators / relaunch elevated), never
    /// the misleading "distro not started?" — and the elevated variant
    /// keeps the genuine no-VM text.
    #[test]
    fn vm_id_lookup_error_classifies_by_elevation() {
        let non_elevated = vm_id_lookup_error(false).to_string();
        assert!(
            non_elevated.contains("NOT elevated"),
            "must name the elevation problem: {non_elevated}"
        );
        assert!(
            non_elevated.contains("Hyper-V Administrators"),
            "must give the group remediation: {non_elevated}"
        );
        assert!(
            !non_elevated.contains("distro not started"),
            "must not mislead toward the distro: {non_elevated}"
        );
        let elevated = vm_id_lookup_error(true).to_string();
        assert!(
            elevated.contains("distro not started"),
            "elevated no-VM keeps the genuine diagnosis: {elevated}"
        );
    }

    /// UTF-16LE piped output arrives as NUL-interleaved lossy UTF-8; the
    /// parser must still find the WSL row (2026-07-12 operator session:
    /// 3 min of false "no running WSL utility VM" during handshake).
    #[test]
    fn parse_wsl_vm_id_tolerates_utf16_nul_interleaving() {
        let clean = "VM,\tRunning, A5A7CF6F-FFF6-4EA9-B4A3-9557B0D5B0CA, WSL\n";
        let interleaved: String = clean.chars().flat_map(|c| [c, '\u{0}']).collect();
        assert_eq!(
            parse_wsl_vm_id(&interleaved).as_deref(),
            Some("A5A7CF6F-FFF6-4EA9-B4A3-9557B0D5B0CA")
        );
    }

    #[test]
    fn wsl_port_extracted_from_wsl_endpoint() {
        let ep = GuestEndpoint::Wsl { port: 42420 };
        assert_eq!(wsl_port(&ep).unwrap(), 42420);
    }

    #[test]
    fn wsl_transport_rejects_non_wsl_endpoint() {
        let ep = GuestEndpoint::Vsock {
            cid: 3,
            port: 42420,
        };
        assert!(wsl_port(&ep).is_err());
    }
}
