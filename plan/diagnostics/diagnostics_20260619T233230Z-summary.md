# Forge Diagnostics Summary — 2026-06-19T23:32:52Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260619T233230Z.log`
- **Forge version**: 0.3.260619.4
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- /run/secrets is a tmpfs mount (6.2G); while currently empty, secrets injected at container start would be visible inside the forge container

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- podman
- nix
- htop
- fzf
- perf
- flutter
- delve
- staticcheck
- hadolint
### Proposed enhancements
- other: podman — Core container runtime Tillandsias depends on; needed for in-forge build/test of container images
- other: nix — Required by nix-first.md agent instructions; enables Nix-based workflows and builds
- go: delve — Go debugger — complements present go/gopls for runtime debugging
- go: staticcheck — Go static analysis tool; standard CI/linting companion for Go codebases
- dart: flutter — Dart SDK is present but Flutter framework is missing; needed for Flutter UI development
- other: htop — Interactive process monitor for diagnosing resource issues during builds
- other: fzf — Fuzzy finder for improved CLI workflow (file search, history, completions)
- other: perf — Linux profiler for performance analysis of builds and runtime
- other: hadolint — Dockerfile linter for container image best-practices validation

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260619T233230Z.stderr.log`
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
| event:container_stderr     | 115   |

#### container_stderr — top 5 containers by line count
```
    102 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```
