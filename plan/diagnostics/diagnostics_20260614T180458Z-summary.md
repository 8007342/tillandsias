# Forge Diagnostics Summary — 2026-06-14T18:05:43Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T180458Z.log`
- **Forge version**: 0.3.260614.8
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- clang
- clangd
- zig
- flutter
- nix
- nixd
- bash-language-server
- yaml-language-server
- lua-language-server
- taplo
- podman
- delve
### Proposed enhancements
- other: clang + clangd — C/C++ LSP and compiler alternative to gcc; clangd is the de facto C/C++ LSP for editors
- other: zig — Modern systems programming language growing in build-tool and cross-compilation use
- dart: flutter — Dart SDK is present but Flutter framework is not; flutter.md instructions exist but tooling is absent
- other: nix + nixd — nix-first.md instructions expect Nix; missing package manager and LSP
- other: bash-language-server — shellcheck and shfmt present but no shell language server for editor integration
- other: yaml-language-server — YAML is pervasive in configs (CI, Docker, k8s); no LSP for validation/completion
- rust: taplo — TOML LSP for Cargo/ Rust project config; Rust toolchain is complete but TOML LSP absent

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T180458Z.stderr.log`
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
| event:container_stderr     | 101   |

#### container_stderr — top 5 containers by line count
```
     88 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```
