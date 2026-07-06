# Implement: embed matching guest binaries into macOS and Windows trays — 2026-07-04

- class: packaging+transport
- filed: 2026-07-04
- owner: any
- pickup_role: linux
- status: obsoleted
- superseded_by: plan/issues/embedded-guest-binary-linux-build-2026-07-05.md

> TOMBSTONE 2026-07-05: this was an early macOS-filed implementation intake note.
> The active implementation path is order 190 for the Linux/Nix guest-binary
> artifact contract, then orders 191 and 193 for sibling branch integration and
> macOS VZ mount evidence. Do not claim this file as a ready packet.

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

## Historical blocker

The host-side code path is in place to consume a `ProvisionManifest`
`tillandsias_binary`, but this checkout cannot yet stage Linux guest binaries
locally because the macOS host shell does not currently have `rustup` or the
Linux cross targets installed. A local attempt to build
`x86_64-unknown-linux-musl` failed immediately with `rustup: command not found`.

## Historical next diagnostic

Install or expose a Rust toolchain with cross targets on this host, then build
`tillandsias-headless` for `x86_64-unknown-linux-musl` and
`aarch64-unknown-linux-musl` so the tray bundle can stage matching guest
binaries into the shared host directory before VM boot.

Superseded verdict: do not require the macOS host to self-produce these binaries
with rustup/cross. Linux owns the Nix build/staging contract in order 190.
