# Forge Diagnostics Summary — 2026-06-14T12:00:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T070420Z.log`
- **Forge version**: 0.3.260614.2
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- {'risk': 'proxy_configured', 'detail': 'HTTP_PROXY set to http://proxy:3128 — external traffic is routable through the internal proxy. External curl returned 000BLOCKED (proxy is blocking), but the proxy path exists and inference (http://inference:11434) is reachable.', 'severity': 'low'}
- {'risk': 'git_author_env', 'detail': 'GIT_AUTHOR_NAME and GIT_AUTHOR_EMAIL are in the environment and readable by agents; low sensitivity but visible in diagnostics/shell output.', 'severity': 'low'}

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- clangd
- clang-tidy
- clang-format
- nix
- taplo
- hadolint
- rust-gdb
- rust-lldb
- cargo-tarpaulin
- cargo-public-api
- flutter
### Proposed enhancements
- other: clangd/clang-tidy/clang-format — C/C++ LSP and linting/formatting toolchain missing despite gcc being present; clangd provides IDE-grade code intelligence for C/C++ files.
- other: nix — Explicitly referenced in agent instructions (nix-first.md), @cheatsheet build/nix-flake-basics.md, and methodology; installing enables Nix-based workflows without fallback failure.
- rust: taplo — TOML linter/formatter essential for Cargo.toml hygiene in Rust projects; missing from current tooling while Cargo and rust-analyzer are present.
- other: hadolint — Containerfile/Dockerfile linter; tillandsias ships Containerfiles and hadolint would catch anti-patterns during CI.
- rust: rust-gdb/rust-lldb — Rust-aware debugger wrappers (gdb/lldb are installed but not the Rust-pretty-printing wrappers), making debugging ergonomics poorer than expected.
- rust: cargo-tarpaulin — Rust code-coverage tool; useful for CI gating and coverage reports. cargo-llvm-cov is an acceptable alternative.
- rust: cargo-public-api — API diff tool for Rust crates; useful for review/semver checks alongside already-present cargo-semver-checks.
- dart: flutter — Flutter SDK is missing despite agent instruction file flutter.md existing; any Dart/Flutter forge usage will fail at SDK bootstrap.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T070420Z.stderr.log`
- **Total launch events**: 10
- **state=running**: 4
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
event:container_launch stage=router state=running
event:container_launch stage=router state=starting
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 113   |

#### container_stderr — top 5 containers by line count
```
    105 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```
