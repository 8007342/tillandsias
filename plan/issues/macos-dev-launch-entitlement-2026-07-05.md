# macOS tray dev launch smoke: debug build lacks Virtualization entitlement — 2026-07-05

- class: bug-fix+packaging (macOS launch smoke)
- filed: 2026-07-05
- owner: macos
- pickup_role: macos
- status: blocked
- trace: spec:macos-native-tray, plan/issues/macos-build-findings-2026-07-01.md

## Problem

`cargo check -p tillandsias-macos-tray` and `cargo test -p tillandsias-macos-tray`
both pass after the secure control-wire helper landed, but a direct dev launch

```bash
cargo run -p tillandsias-macos-tray
```

fails during the auto-boot path with:

```text
Invalid virtual machine configuration. The process doesn’t have the
“com.apple.security.virtualization” entitlement.
```

The tray binary starts, but the VM cannot auto-boot in this debug-launch mode, so
the local smoke never reaches the interactive menu / GitHub login / forge attach
surface.

## Evidence

- `cargo check -p tillandsias-macos-tray` passes.
- `cargo test -p tillandsias-macos-tray` passes except the ignored slow e2e.
- `cargo run -p tillandsias-macos-tray` emits the entitlement failure above after
  `Auto-boot: spawning worker`.

## Next step

Decide which launch path should own the entitlement for macOS smoke:

1. Build and launch the packaged `.app` for smoke sessions, or
2. Carry the virtualization entitlement into the local dev launch path.

## Exit criteria

- The launched macOS tray can auto-boot the VM without the entitlement failure.
- The interactive tray can reach GitHub login, list-cloud-projects, and forge
  attach in a local smoke session.
