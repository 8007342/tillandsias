# Forge Diagnostics Summary — 2026-05-29T08:09:58Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T080843Z.log`
- **Forge version**: 0.2.260528.1
- **Host platform**: unknown
- **Agent**: unknown
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- {'risk': 'Weak external access via proxy', 'detail': 'Proxy returning HTTP 403 (not connection failure) confirms outbound HTTP traffic is proxied and policy-filtered but not network-blocked; a proxy misconfiguration could permit unintended external data exfiltration', 'severity': 'low'}
- {'risk': 'Git author identity in environment', 'detail': 'GIT_AUTHOR_EMAIL=bulloncito@gmail.com and GIT_AUTHOR_NAME=Tlatoāni are set in container environment, exposing project contributor identity to any process inside the container', 'severity': 'low'}

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- rust-analyzer
- cargo-tarpaulin
- cargo-audit
- cargo-deny
- just
- gcc
- g++
- make
- cmake
- jq
- ripgrep
- fd
- bat
- delta
- httpie
- yq
- nix
- flutter
### Proposed enhancements
- rust: rust-analyzer — Installed via rustup component but not on PATH; symlink from /usr/local/rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin/rust-analyzer to /usr/local/bin/
- rust: cargo-tarpaulin — Code coverage tool for Rust; standard in CI and local test workflows
- rust: cargo-audit — Security vulnerability auditing for Rust dependency trees
- rust: cargo-deny — License and dependency auditing for Rust projects
- rust: just — Modern command runner; common in Rust and Nix project Makefile replacements
- other: build-essential (gcc, g++, make, cmake) — C/C++ native compilation required by many Rust crates, Python native extensions, and system-level builds
- other: jq — JSON processor; ubiquitous in shell scripting, CLI pipelines, and CI workflows
- other: ripgrep (rg) — Fast recursive content search; standard developer tool replacing grep for codebases
- other: fd — Fast file find replacement for find(1); ergonomic defaults for developer workflows
- other: bat — Syntax-highlighted cat with git integration; improves terminal code reading
- other: delta — Syntax-highlighted git diff pager; pairs with bat for cohesive terminal UX
- web: httpie — User-friendly HTTP client for API testing and debugging; preferred over raw curl for interactive use
- other: yq — YAML/TOML processor; needed for working with Kubernetes, GitHub Actions, and Nix configs
- other: nix — Referenced in nix-first.md and methodology but not installed; required for Nix flake workflows the forge instructions depend on
- dart: flutter — Referenced in flutter.md agent instructions but not installed; Dart SDK is present but mobile/web UI toolchain is missing

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T080843Z.stderr.log`
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
| event:container_stderr     | 961   |

#### container_stderr — top 5 containers by line count
```
    851 event:container_stderr container=tillandsias-inference
    102 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```
