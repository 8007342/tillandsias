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

#[cfg(test)]
mod tests {
    use super::*;

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
}
