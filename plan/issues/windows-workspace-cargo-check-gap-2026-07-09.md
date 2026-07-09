# Windows host cannot run workspace-wide cargo check — enhancement — 2026-07-09

- discovered_by: `/advance-work-from-plan` (windows), order 154 cycle
- classification: enhancement
- host: Windows 11 native
- status: ready
- owner_host: any
- capability_tags: [build-script, windows, verification, tooling]

## Finding

`cargo check -p tillandsias-headless` (and by extension `cargo check
--workspace` / `./build.sh --check`) fails to compile on a Windows host:

- `crates/tillandsias-headless/src/main.rs:42` — `use
  std::os::unix::net::UnixStream;` is ungated (the `CommandExt` import right
  below it IS `#[cfg(unix)]`-gated), E0433 on Windows.
- `libc::getuid` calls, `signal_hook` usage — unix-only APIs throughout the
  headless and parts of `tillandsias-podman`.

This is longstanding (the headless is the in-VM Linux guest binary, built via
the musl cross target), NOT a regression — but it means Windows workers cannot
run the post-merge Integration Verification Gate's `./build.sh --check` step
as written in `skills/advance-work-from-plan/SKILL.md` §6, and each Windows
cycle re-discovers which `-p` subset compiles by trial and error (this cycle
lost a diagnostic detour confirming ab3fea87's merge was not at fault).

## Why it makes cycles slower

The gate says "Code still compiles — ./build.sh --check" with no per-host
carve-out. On Windows the honest equivalent is a documented crate allowlist
(`-p tillandsias-windows-tray -p tillandsias-host-shell -p
tillandsias-control-wire -p tillandsias-vm-layer -p tillandsias-policy …`),
but that list lives in no executable place — every agent re-derives it.

## Smallest next action

Either (a) add a `scripts/check-host-crates.sh` (or build.sh flag) that maps
host kind → compilable crate set and becomes the Windows/macOS wording of the
Integration Verification Gate, or (b) cfg-gate the headless/podman unix-isms
so `cargo check --workspace` passes everywhere (larger; only worth it if
cross-platform IDE ergonomics matter). Option (a) is one small script + a
SKILL.md §6 sentence; pin with an instant litmus.

- events:
  - type: discovered
    ts: "2026-07-09T21:50:00Z"
    agent_id: "windows-bullo-claude-fable-20260709T2107Z"
    host: windows
