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
}
