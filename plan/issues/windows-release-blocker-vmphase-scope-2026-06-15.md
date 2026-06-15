# P0 release blocker: Windows tray fails to compile (VmPhase out of scope) — 2026-06-15

The `windows-release` job of `release.yml` FAILED for `v0.3.260615.1` (and will
fail every release until fixed). Linux + macOS artifacts published fine; the
Windows tray artifact is MISSING from the release.

- release run: https://github.com/8007342/tillandsias/actions/runs/27522169421
- failing job: "Build, sign, and publish Windows tray" (cargo exit 101)

trace: crates/tillandsias-windows-tray/src/wsl_lifecycle.rs
       .github/workflows/release.yml (windows-release job)

## Work Packet: windows-tray/vmphase-import-scope-release-break

- id: `windows-tray/vmphase-import-scope-release-break`
- type: fix
- title: Hoist VmPhase import so windows-tray compiles (P0 release blocker)
- owner_host: windows
- capability_tags: [rust, windows, control-wire, release]
- priority: P0
- status: ready
- discovered_by: `/merge-to-main-and-release` (osx-next promotion, v0.3.260615.1)
- owned_files:
  - `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`
- evidence:
  - `wsl_lifecycle.rs:415` — `use tillandsias_control_wire::{ControlEnvelope,
    ControlMessage, VmPhase, WIRE_VERSION};` is declared INSIDE the body of
    `try_connect_until_ready`, so it does not bring `VmPhase` into scope for
    that fn's own return-type signature nor for sibling functions.
  - `wsl_lifecycle.rs:413` — `async fn try_connect_until_ready(...) ->
    Result<VmPhase, String>` → E0433 "cannot find type `VmPhase` in this scope".
  - `wsl_lifecycle.rs:228` — `Ok(VmPhase::Ready) | Ok(VmPhase::Starting)` in a
    different fn → E0433 (and an E0425).
  - Build log: `error: could not compile tillandsias-windows-tray ... due to 3
    previous errors`; `build-windows-tray.ps1:85 throw "cargo build failed
    (exit 101)"`.
- repro:
  - On a Windows host (or `--target x86_64-pc-windows-msvc`):
    `cargo build -p tillandsias-windows-tray`
- next_action: >
    Hoist `VmPhase` (and the other control_wire items used across multiple fns)
    to a module-level `use tillandsias_control_wire::VmPhase;` near the top of
    wsl_lifecycle.rs, and drop the now-redundant body-local import (which the
    compiler already flags as `unused import: VmPhase`). Verify with a real
    Windows-target build, then re-run release.yml --ref v0.3.260615.1 (the
    windows-release job uploads via --clobber) OR let the next release pick it up.
- notes: >
    Pre-existing break in Windows-owned scope; surfaced because macOS/Linux
    builds don't compile windows-tray. Not fixed here to avoid shipping
    Windows code that cannot be compile-verified from a macOS host.
- events:
  - type: discovered
    ts: "2026-06-15T04:10:00Z"
    agent_id: macos-claude-opus
    host: macos
