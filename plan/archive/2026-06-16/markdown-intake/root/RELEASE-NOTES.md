# Release Notes — v0.3.0 "Fedora Pivot"

## Overview
Tillandsias v0.3.0 is a major architecture update that introduces the **Fedora Pivot**, switching from custom-built rootfs images to official, signed Fedora Project images for the underlying Linux runtime. This release also achieves **UX Parity** across Linux, macOS, and Windows.

## Key Changes

### Fedora Pivot
- **Official Image Integration**: Now uses official Fedora WSL2 (Windows) and Cloud Base (macOS) images.
- **Smaller Footprint**: Reduced download sizes by leveraging official compressed images.
- **Improved Reliability**: Native bootstrap process into the VM replaces complex pre-materialized images.

### Multi-Host UX Parity
- **Native macOS Tray**: Full AppKit menu-bar integration with proper icon rendering and project-threading.
- **Native Windows Tray**: Win32 NotifyIcon tray with Windows Terminal and `wsl.exe` integration.
- **Structural Alignment**: Menus and status text now match the reference Linux implementation across all platforms.

### Diagnostics & Observability
- **Diagnostics Stream**: New event-driven observability for container lifecycle (start, stop, exit, OOM).
- **Ring Buffer**: 10K capacity event buffer with backpressure management.
- **Enhanced --diagnose**: Cross-platform health reports with 17+ metrics.

### Security & Hardening
- **Sigstore Signatures**: Every artifact is signed via Cosign keyless mode (Fulcio/Rekor).
- **Static Linkage**: macOS tray now statically links `liblzma` for zero-dependency provisioning.
- **Rootless Podman**: Continued commitment to rootless, unprivileged container execution.

## Verification
Verification instructions are available in [docs/VERIFICATION.md](docs/VERIFICATION.md). Checksums and signatures can be found in the [latest release](https://github.com/8007342/tillandsias/releases/latest).

---
*Release 2026-06-04*
