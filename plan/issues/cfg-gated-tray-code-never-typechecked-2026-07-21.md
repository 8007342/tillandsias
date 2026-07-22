# cfg-gated Windows/macOS tray code is NEVER type-checked on Linux or CI — only parsed

- Date: 2026-07-21
- Class: bug (verification hole, structural) — the enabling condition of the
  2026-07-21 handshake-push breakage
- Filed by: linux coordinator, from the wave-2 planner's verified finding
- Related: 60151373 (handshake repair), ci.yml (born 2026-07-21),
  plan/issues/agent-pushed-unparseable-code-no-push-ci-2026-07-21.md

## Verified (wave-2 planner, 2026-07-21)

`tillandsias-windows-tray`'s real notify_icon.rs/wsl_lifecycle.rs and
`tillandsias-macos-tray`'s real action_host.rs/status_item.rs/diagnose.rs are
all `#[cfg(target_os = ...)]`-gated; on Linux, main.rs swaps in stub files.
Neither `./build.sh --check` nor CI's
`cargo check --workspace --all-features --all-targets` (ubuntu runner) ever
type-checks those bodies. `cargo check -p tillandsias-windows-tray --target
x86_64-pc-windows-gnu` fails immediately on this host (no
x86_64-w64-mingw32-gcc cross toolchain). The ONLY inspection those files get
on Linux is `cargo fmt --check` (parse-only) — exactly why the handshake
push's broken notify_icon.rs was caught by formatting, not by a type error.

## Why it matters

Every tray-surface change made from Linux (most of them — waves 1-2 shipped
five such packets) is high-care, low-verifiability: unit tests cover the
non-gated host-shell/control-wire logic, but the platform bodies compile for
the first time on a Windows/macOS host, days later, in someone else's cycle.

## Mitigations already in practice (waves 1-2)

Workers push logic into non-gated crates (host-shell, control-wire, vm-layer)
and keep gated bodies thin; source-scan tests pin the wiring textually.

## Smallest fix (exit_criteria)

1. CI gains a cross-TYPECHECK lane for the gated bodies. Candidate paths
   (research which is cheapest, in order): (a) `cargo check --target
   x86_64-pc-windows-msvc` on a `windows-2022` runner + `--target
   aarch64-apple-darwin` on a `macos-14` runner — native toolchains, no
   cross-linkers needed for CHECK (no linking); (b) Linux runner with mingw +
   osxcross (heavier, avoid if (a) works). Scope: `cargo check -p
   tillandsias-windows-tray -p tillandsias-macos-tray --all-targets` only —
   keep it minutes-cheap.
2. The daily-loop skills already run real platform builds
   (build-windows-tray, build-macos-tray) — CI type-check is the fast gate,
   those remain the deep gate.
- Exit: a deliberately mistyped (but parseable) edit inside a
  `#[cfg(target_os = "windows")]` body turns a PR/push red.
