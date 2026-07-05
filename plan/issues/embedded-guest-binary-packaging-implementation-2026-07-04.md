# Implement: embed matching guest binaries into macOS and Windows trays — 2026-07-04

- class: packaging+transport
- filed: 2026-07-04
- owner: any
- pickup_role: linux
- status: ready

## Goal

Teach the macOS and Windows tray wrappers to ship the matching Linux guest
binaries inside the host bundle, so a local install always launches a guest
that matches the same source revision as the wrapper.

The bundle may include both Linux `x86_64` and `aarch64` guest binaries. The
host should pick the correct one at runtime.

## Scope

- Bundle guest binaries with the macOS and Windows tray artifacts.
- Add a host-side selector that chooses the embedded guest by host arch.
- Replace any release-latest guest fetch in the wrapper launch path with the
  embedded asset path when available.
- Keep the existing network-based fallback only if the bundle asset is absent
  for a transitional build.

## Why this is the right next slice

- Local smokes should not depend on Wi-Fi or on release propagation timing.
- Host/guest version skew is a recurring cause of handshake failures.
- The accepted size overhead is smaller than the cost of a broken launch path.

## Exit criteria

- A packaged macOS tray can launch a matching guest without fetching from the
  network.
- A packaged Windows tray can do the same.
- GitHub login, remote-project listing, and forge launch all work against the
  embedded guest binary.
- The secure-control-wire path reaches a responder built from the same tree.

## Notes for the first implementation slice

1. Define the bundle asset layout and names first.
2. Wire the launcher to prefer embedded assets before any network fetch.
3. Add plan evidence for the resulting local smoke.

