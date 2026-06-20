# Forge Diagnostics Summary — 2026-06-20T17:28:03Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260620T172748Z.log`
- **Forge version**: 0.3.260620.6
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
- taplo
- dprint
- hadolint
- golangci-lint
- delve
- flutter
- nix
- deadnix
- statix
- nixpkgs-fmt
- stylua
- checkmake
- terraform
- tofu
### Proposed enhancements
- rust: taplo — TOML formatter/linter essential for Cargo.toml and Rust project hygiene; missing despite Rust being the primary toolchain.
- rust: dprint — Fast multi-language formatter (Rust-native); complements prettier for Rust projects and provides JSON/Markdown/TOML formatting with a single binary.
- other: hadolint — Dockerfile linter; the project builds container images and would benefit from Dockerfile best-practice checks.
- go: golangci-lint — Go linter suite; Go toolchain is present (go 1.26), but no linting tooling is preinstalled.
- go: delve — Go debugger; essential for debugging Go code, complementary to the Go toolchain already present.
- dart: flutter — Flutter SDK referenced in agent instructions (flutter.md) but not installed; Dart SDK present at /opt/dart-sdk/bin/dart.
- other: nix — Nix package manager referenced in agent instructions (nix-first.md, nix-flake-basics cheatsheet) but not installed.
- other: deadnix — Nix dead-code linter; pairs with the nix-first methodology the forge explicitly documents.
- other: statix — Nix linter; pairs with the nix-first methodology the forge explicitly documents.
- other: nixpkgs-fmt — Nix formatter; pairs with the nix-first methodology the forge explicitly documents.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260620T172748Z.stderr.log`
- **Total launch events**: 10
- **state=running**: 4
- **state=failed**: 0

### Distinct stage → state pairings

```
event:container_launch stage=opencode state=exited
event:container_launch stage=opencode state=starting
event:container_launch stage=opencode-git state=running
event:container_launch stage=opencode-git state=starting
event:container_launch stage=opencode-inference state=running
event:container_launch stage=opencode-inference state=starting
event:container_launch stage=opencode-proxy state=running
event:container_launch stage=opencode-proxy state=starting
event:container_launch stage=router state=running
event:container_launch stage=router state=starting
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 83   |

#### container_stderr — top 5 containers by line count
```
     70 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```
