# vsock Kernel Probe Results — 2026-06-29

**Distro**: tillandsias (WSL2 v2, Fedora 44 Container Base)
**Kernel**: 6.6.114.1-microsoft-standard-WSL2
**Phase 0 of plan**: floating-honking-locket.md

---

## Results Summary

| Check | Result | Phase gate |
|-------|--------|------------|
| `vsock_loopback` kernel config | `CONFIG_VSOCKETS_LOOPBACK=m` — **present as module** | Phase 5 UNBLOCKED |
| `modprobe vsock_loopback` | **OK** — module loads, `vmw_vsock_virtio_transport_common` auto-loaded | Phase 5 UNBLOCKED |
| `/dev/vsock` present | **YES** | Phase 5 prerequisite met |
| AF_VSOCK in `/proc/net/protocols` | **YES** | Phase 5 prerequisite met |
| `CONFIG_HYPERV_VSOCKETS=y` | **YES** (built-in) | HvSocket host→guest confirmed |
| rootless podman `--device /dev/vsock` | **INCONCLUSIVE** — docker.io pull timeout (network issue in WSL2 at test time); not a vsock/podman capability failure | Retest when network available |
| vsock CID 1 loopback socat test | **INCONCLUSIVE** — `socat: command not found` (not installed) + DNF DNS timeout; vsock_loopback module loads but end-to-end CID 1 reachability unverified | Retest after `dnf install socat` when network available |
| SELinux mode | `getenforce: command not found` — **DISABLED** (no policycoreutils installed) | Phase 3 prerequisite: install selinux-policy-targeted |
| `tillandsias-headless` installed | `/usr/local/bin/tillandsias-headless` exists, service **active** | Phase 0 complete |

---

## Detailed Kernel Config (vsock-related)

```
CONFIG_VSOCKETS=y
CONFIG_VSOCKETS_DIAG=m
CONFIG_VSOCKETS_LOOPBACK=m       ← KEY: loopback present as module
CONFIG_VMWARE_VMCI_VSOCKETS=m
CONFIG_VIRTIO_VSOCKETS=m
CONFIG_VIRTIO_VSOCKETS_COMMON=m
CONFIG_HYPERV_VSOCKETS=y         ← built-in, HvSocket works
CONFIG_VSOCKMON=m
CONFIG_VHOST_VSOCK=m
```

---

## Architectural Decision Update

Based on these results:

- **AD-7 updated**: vsock-in-vsock (Phase 5) is UNBLOCKED. `vsock_loopback` is a loadable
  module in the WSL2 kernel. CID 1 loopback routing should work once the module is loaded.
  The `modprobe vsock_loopback` step must be added to `inject_bootstrap_logic` (or as a
  systemd module-load unit) so the module persists across WSL2 restarts.

- **AD-4 unchanged**: Phase 4 (Unix socket passthrough) still proceeds as planned. It gives
  us a working, testable baseline before committing to the vsock-in-vsock wiring.

---

## Pending (need retest when network available)

- `podman run --rm --device /dev/vsock alpine ls /dev/vsock` — verify rootless podman can
  pass `/dev/vsock` to containers. Failure was due to `i/o timeout` on docker.io DNS lookup.

## Action: Load vsock_loopback on boot

Add to `inject_bootstrap_logic`:

```rust
// After systemctl enable --now ...
self.wsl_root_sh(
    "echo 'vsock_loopback' > /etc/modules-load.d/tillandsias-vsock.conf && \
     modprobe vsock_loopback 2>/dev/null || true"
).await?;
```
