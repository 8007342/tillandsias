# Forge Diagnostics Summary — 2026-05-29T06:03:45Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T060330Z.log`
- **Forge version**: 0.2.260528.1
- **Host platform**: unknown
- **Agent**: unknown
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- delve
- clippy
- cargo-edit
- cargo-tarpaulin
- cargo-deny
- cargo-outdated
- cargo-tree
- cargo-criterion
- cargo-expand
- cargo-llvm-cov
- cargo-semver-checks
- pylint
- flake8
- black
- bandit
- pylint
- eslint
- prettier
- ltrace
- perf
- heaptrack
- wasmtime
- wasmer
- cargo-wasi
### Proposed enhancements
- rust: clippy (rustup component) — Standard Rust linter; absent despite rustc/cargo being installed. Install via rustup component add clippy.
- rust: cargo-edit — Enables 'cargo add/rm/upgrade' for ergonomic dependency management.
- rust: cargo-llvm-cov / cargo-tarpaulin — Code coverage tooling expected in CI/test workflows; neither is installed.
- rust: cargo-deny — License and advisory checking for Rust dependencies, standard in production pipelines.
- rust: cargo-semver-checks — Automated semver verification for Rust library releases.
- rust: cargo-expand — Macro-expansion debugging essential for Rust development.
- python: pylint / flake8 / black / bandit — Core Python linting, formatting, and security tools missing despite mypy/pytest/ruff being present.
- web: eslint / prettier — Standard JS/TS linting and formatting; absent despite node/npm/tsc being available.
- wasm: wasmtime / wasmer — WASM runtime execution outside the browser; wasm-pack is present but no runtime.
- other: perf / ltrace / heaptrack — Profiling/dynamic-analysis tools valuable for performance work; gdb/lldb/strace/valgrind are present but these are not.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T060330Z.stderr.log`
- **Total launch events**: 8
- **state=running**: 3
- **state=failed**: 0

### Distinct stage → state pairings

```
event:container_launch stage=opencode-git state=running
event:container_launch stage=opencode-git state=starting
event:container_launch stage=opencode-inference state=running
event:container_launch stage=opencode-inference state=starting
event:container_launch stage=opencode-proxy state=running
event:container_launch stage=opencode-proxy state=starting
event:container_launch stage=opencode state=exited
event:container_launch stage=opencode state=starting
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 110   |

#### container_stderr — top 5 containers by line count
```
    102 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```
