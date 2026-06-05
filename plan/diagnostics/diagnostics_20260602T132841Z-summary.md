# Forge Diagnostics Summary — 2026-06-02T13:28:55Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260602T132841Z.log`
- **Forge version**: 0.2.260602.1
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
- clangd
- basedpyright
- sqlite3
- hadolint
- nix
- flutter
### Proposed enhancements
- c/c++: clangd — C/C++ language server for native dependency code, FFI, and system-level development in the forge
- python: basedpyright — Faster, more configurable Python type checking with extended rule set over stock pyright
- other: sqlite3 — Universal CLI for ad-hoc data inspection, debugging, and lightweight database operations
- other: hadolint — Dockerfile linter to catch errors and enforce best practices in container image definitions
- other: nix — Project methodology references nix-first; Nix enables reproducible builds and declarative dev environments in the forge
- dart: flutter — Project includes macos-tray skill referencing Flutter; adding Flutter SDK enables Dart/Flutter development within the forge

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260602T132841Z.stderr.log`
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
| event:container_stderr     | 190   |

#### container_stderr — top 5 containers by line count
```
    182 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```
