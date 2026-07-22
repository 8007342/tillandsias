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

## Implementation note (2026-07-21, linux coordinator waiver)

Took smallest-fix path (a): two native cross-typecheck lanes added to
`.github/workflows/ci.yml` (edited under an explicit coordinator waiver; the
existing `check` job is untouched):

- `windows-typecheck` on `windows-2022` (native x86_64-pc-windows-msvc):
  `cargo check -p tillandsias-windows-tray --all-features --all-targets`.
- `macos-typecheck` on `macos-14` (native aarch64-apple-darwin):
  `cargo check -p tillandsias-macos-tray --all-features --all-targets`.

These are CHECK-only (no linking), so no cross-linker/mingw/osxcross is needed
— the type-checker walks the real `#[cfg(target_os = ...)]` bodies that the
ubuntu runner stubs out. Style matches the `check` job: pinned
`actions/checkout@de0fac2e...` (v6), `Swatinem/rust-cache@v2` with a distinct
per-OS `shared-key` (`ci-windows-typecheck` / `ci-macos-typecheck`),
`timeout-minutes: 30`, and the workflow-level `concurrency` group applies to
all jobs. Dropped `--locked` from these lanes to mirror the coordinator's
exact command (the workspace `check` lane still enforces the lockfile).

Validated locally with `ruby -ryaml -e 'YAML.load_file(...)'` (parses; three
jobs: check, windows-typecheck, macos-typecheck). Cannot exercise the runners
from Linux — static validation + style fidelity is the bar here; the first
real run on GitHub Actions (a push to a covered branch or a PR to `main`) is
the live proof, and the exit-criteria red-test (a mistyped-but-parseable gated
edit) can only be confirmed there.
