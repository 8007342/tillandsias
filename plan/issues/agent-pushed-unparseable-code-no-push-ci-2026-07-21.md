# Agent pushed unparseable code to linux-next — and NO CI exists on pushes or PRs to catch it

- Date: 2026-07-21
- Class: bug (process/verification hole) + regression (tree broken at HEAD)
- Filed by: linux coordinator (meta-orchestration cycle on operator request)
- Related: commit ced9657e ("Implement guest-tray-build-version-handshake",
  Generated-By: tool=antigravity), the Non-Negotiable Exit Contract
  (skills/meta-orchestration), merge-to-main-and-release step 3 (which
  `--watch`es PR checks that DO NOT EXIST).

## Observed (live, 2026-07-21)

Commit `ced9657e` landed on origin/linux-next with:

1. `crates/tillandsias-windows-tray/src/notify_icon.rs` UNPARSEABLE — a
   mechanical `(WireReport, guest_version)` tuple refactor spliced the tuple
   closer INTO string literals (`format!("{phase:?}, guest_version)")`) and
   dropped closing delimiters; `cargo fmt` could not even parse the file.
2. Literal `\"` escapes written into source at
   `tray/mod.rs:945` and `vsock_server.rs:650`
   (`env!(\"CARGO_PKG_VERSION\")`) — a patch-tool quoting bug, flush-left
   with no indentation.
3. Five test targets missing the new `build_version`/`guest_version` fields
   (host-shell x2, router-sidecar, macos-tray, headless vsock e2e) —
   `cargo check` passes but `--all-targets`/`./build.sh --check` fails.

Every developer/agent on linux-next inherited a red `./build.sh --check`.
All repaired by the coordinator the same session (fmt-clean, clippy-clean,
workspace tests green except the pre-existing zombie-reap flake).

## Root cause

- The producing agent did not run `./build.sh --check` (or even `cargo fmt`)
  before pushing — the meta-orchestration exit contract was not applied
  because the work ran OUTSIDE that loop (direct Antigravity session).
- Structural hole: `.github/workflows/` contains ONLY `release.yml`
  (workflow_dispatch) and `nix-cache-warm.yml` (cron). There is NO workflow
  on `push` or `pull_request` — nothing server-side validates linux-next
  pushes, and the release skill's step 3 (`gh pr checks --watch`) watches an
  EMPTY check set (observed on PR #78: "no checks reported").

## Why it matters

- A broken HEAD poisons every downstream consumer: forge clones (agents
  build from the mirror's current head), sibling platform branches (the
  pre-push merge gate pulls linux-next in), and the daily release PR.
- The release gate believes it is waiting for CI that can never run — the
  "merge once green" contract is currently vacuous.

## Smallest fix (exit_criteria)

1. `.github/workflows/ci.yml`: on push to linux-next/windows-next/osx-next
   and pull_request to main — `cargo fmt --all --check` +
   `cargo check --workspace --all-features --all-targets` (implemented with
   this filing; keep it lean, no test execution, so Actions cost stays low).
2. Every autonomous harness prompt that can push MUST include the pre-push
   gate (`./build.sh --check`); AGENTS.md gains the one-line rule so
   non-Claude harnesses inherit it.
3. Exit: a deliberately unparseable push to a scratch branch shows a red
   check; PR checks on the next release PR are non-empty.
