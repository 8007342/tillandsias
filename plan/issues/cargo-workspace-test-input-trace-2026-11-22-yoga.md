# cargo test --workspace: what the tests actually read (yoga, 2026-11-22)

Order 2175-ctin, option (C), stopped at (E) by the coordinator. A negative result, kept as evidence.

## Question

Can the 93 s `cargo test --workspace` gate step be skipped (against a daily full proof, 2174-dail) for
docs-only or Lua-only PRs, if its STEP_INPUTS are declared from what the tests really open?

## Method

- `cargo test --workspace --no-run` first, so compile-time reads are excluded from the trace.
- `strace -f -ff -e trace=open,openat,openat2,stat,newfstatat,statx,execve` over
  `cargo test -q --workspace --no-fail-fast` (builder toolbox, strace 7.3 installed there only).
- 15,151 traced processes. Kept: successful opens under the checkout, minus `target/` and `.git/`.
- Relative opens (11,727) resolved against the repo root and kept when that path exists (1,874).
- Compile-time inputs: cargo's own dep-info (`target/debug/deps/*.d`, build-script `output`) with
  the checkout prefix stripped, because the shared target names whichever checkout built a unit (720).

## Result

| set | files |
|---|---|
| opened, absolute | 14,791 |
| opened, relative and resolvable | 1,874 |
| compile-time (dep-info) | 720 |
| union outside `crates/` | 2,660 |

Union, each file widened to its parent `dir/**`, collapsed: 43 entries (below).

- **docs/**: one file is opened, `docs/cheatsheets/github-credential-tools.md`. A docs-only PR
  outside `docs/cheatsheets/` would skip.
- **scripts/lua/**: 342 files are opened, plus files across `scripts/` (fixtures, hooks, lib,
  test-support). Lua-only PRs must run the step. This is not a false positive.
- The static scan (`scan-cargo-test-repo-roots.lua --workspace`) over-reached: its `docs/**`,
  `locales/**` and `assets/**` came from literal false positives, or from crates the Linux test
  build does not compile (the Windows and macOS trays).

## Why stopped

The gain is docs-only PRs outside cheatsheets. Those already save about 70 s through #1293, the
feature-gated skip. Keeping an empirical declaration honest needs re-tracing on every daily run
(strace on the landing host, plus a trace-diff stage). That is not worth it for this gain, so the
workspace step stays unskippable.

## The empirical declaration (for reference, NOT in use)

    path:.cargo/**
    path:.codex/**
    path:.config
    path:.tillandsias/**
    path:AGENTS.md
    path:CLAUDE.md
    path:Cargo.lock
    path:Cargo.toml
    path:README.md
    path:VERSION
    path:build-all-images.sh
    path:build-forge.sh
    path:build-git.sh
    path:build-inference.sh
    path:build-proxy.sh
    path:build.sh
    path:crates
    path:docs/cheatsheets/**
    path:flake.nix
    path:images
    path:images/**
    path:launch.sh
    path:methodology
    path:methodology.yaml
    path:observatorium
    path:observatorium.sh
    path:observatorium/**
    path:openspec
    path:openspec/**
    path:plan/**
    path:research
    path:research/**
    path:run-forge-standalone.sh
    path:run-safe-browser.sh
    path:run-tillandsia.sh
    path:run_smoke.sh
    path:rust-toolchain.toml
    path:scripts
    path:scripts/**
    path:skills
    path:skills/**
    path:tests/**
    path:tools/trace-viewer/**

Raw lists (opened, relative, dep-info) are in the yoga agent scratchpad (c-trace/); they are 15k+ lines and not committed.
