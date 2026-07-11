# Impl: Fix macOS Virtualization DNSSEC and IPv6 ULA Issues in Podman Builds — 2026-07-07

- class: enhancement
- filed: 2026-07-07
- owner: antigravity
- status: pending
- depends_on: research-macos-vz-dnssec-ipv6-2026-07-07.md

## Implementation Plan
Based on the findings from the research packet (`research-macos-vz-dnssec-ipv6-2026-07-07.md`), implement the proper networking fixes for the macOS `Virtualization.framework` guest:

1. **Disable DNSSEC in `systemd-resolved`**: Configure the guest OS to set `DNSSEC=no` to prevent SERVFAILs caused by macOS NAT DNS proxy signature stripping.
2. **Mitigate IPv6 ULA Blackholes**: Implement the chosen strategy to prevent Alpine's `apk` and other package managers from hanging on unroutable `fd22::` addresses (e.g., sysctl disables, podman config updates, etc.).
3. **Remove Hacks**: Remove the temporary `--dns 8.8.8.8` hack from `podman_build_argv` in `crates/tillandsias-headless/src/main.rs`.
