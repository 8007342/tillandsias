# build-macos-tray (from windows host) — 2026-05-29

**Branch:** windows-next @ `707871c4` (post-FF, with macOS m10/m11 + slice 30 architectural-invariants).
**cargo exit:** `0`
**First error line:** — (none)
**Classification:** **expected steady state** — the macos-tray crate is fully
cfg-gated for non-macOS targets (every macOS-only module is behind
`#[cfg(target_os = "macos")]` in `src/main.rs`; the Apple-only deps live under
`[target.'cfg(target_os = "macos")'.dependencies]` in `Cargo.toml`), so on
Windows the build produces a stub `main` that exits 1 with a pointer at the
spec. The build succeeding here means the **cross-platform-shared** portion of
macos-tray (`menu_disabled_v2`, `terminal_attach`) and its non-platform-gated
dependency crates (`tillandsias-host-shell`, `tillandsias-control-wire`,
etc.) all still compile cleanly from the Windows host.

**Shared-crate impact:** none.

## Findings

- **Initial assumption was wrong.** I expected the macos-tray build to fail on
  Windows (unresolved `objc2_virtualization` / linker errors). The actual
  failure mode would have been an **UNRELATED shared-crate compilation error**;
  the expected-steady-state is build `0`. I have rewritten
  `skills/build-macos-tray/SKILL.md` Steps 3 (classification table) and the
  "Why this exists" preamble to match the real semantics: this loop is now
  documented as a cross-tray health canary — Windows builds the stub daily,
  and any **non-zero exit** here means at least one shared module or crate
  broke for everyone, not just macOS.

- **Documented the shared-module surface this loop pins.** `menu_disabled_v2`,
  `terminal_attach`, `tillandsias-host-shell`, `tillandsias-control-wire`.
  Each rename / removal / API-break on any of those becomes immediately
  visible on the Windows host's daily probe.

## No cross-host escalation needed
