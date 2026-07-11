# Research: macOS Virtualization DNSSEC and IPv6 ULA Issues in Podman Builds — 2026-07-07

- class: research
- filed: 2026-07-07
- owner: antigravity
- status: pending
- eligible_models: ["Fable", "Opus"]

## Context
When running `tillandsias-headless` inside a macOS `Virtualization.framework` guest (Fedora CoreOS), `podman build` fails to fetch packages (like `dl-cdn.alpinelinux.org`) during container initialization. This manifests as `temporary error (try again later)` and `unable to select packages` from `apk`.

## The Two Core Issues

1. **systemd-resolved SERVFAIL due to DNSSEC Stripping:**
   macOS Internet Sharing (NAT) provides DNS to the guest via `mDNSResponder`, which notoriously strips DNSSEC signatures. `systemd-resolved` in the guest receives these unsigned/broken responses and returns `SERVFAIL` (which `apk` surfaces as `EAI_AGAIN` or "temporary error").
   - *Temporary workaround used:* We injected `--dns 8.8.8.8` into `podman build` to bypass the host's `systemd-resolved`. This is a hack and fails in environments blocking public DNS.
   - *Proper solution needed:* `systemd-resolved` in the guest must be configured to disable DNSSEC validation (`DNSSEC=no` in `/etc/systemd/resolved.conf.d/`), either during `rootfs.qcow2` provisioning or dynamically at boot.

2. **IPv6 ULA Blackhole with --network host:**
   When we attempted to fix DNS by passing `--network host` to `podman build`, `apk` successfully resolved DNS but timed out connecting. This is because the VM gets a Unique Local Address (ULA) IPv6 address (`fd22::...`) from macOS. `apk` strongly prefers IPv6, but the ULA address has no internet route, causing connection timeouts.
   - *Temporary workaround used:* We removed `--network host`, keeping the build in Podman's default bridge (which is IPv4-only), preventing `apk` from seeing an IPv6 route.
   - *Proper solution needed:* Investigate if `netavark` can be explicitly told to disable IPv6 for specific bridges, or if macOS Virtualization can be configured not to hand out unroutable ULA addresses if there's no NAT64.

## Goal
A highly capable agent (Fable/Opus) should research the optimal way to provision `systemd-resolved` with `DNSSEC=no` inside the `tillandsias-in-vm` guest without breaking existing host-side network configurations. Additionally, determine if IPv6 should be globally disabled in the guest kernel or podman configuration to prevent ULA blackholes during container operations.
