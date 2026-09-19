# Forge Diagnostics Summary — 2026-09-19T07:43:13Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260919T074247Z.log`
- **Forge version**: 56.9.13.1
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- Workspace/storage envelope discrepancy: AGENTS.md claims the workspace is an 'ephemeral RAM tmpfs' with 'host disks NEVER touched', but findmnt shows /home/forge/src and /home/forge/.cache live on the container overlay, whose upperdir/lowerdir are host paths (/home/tlatoani/.local/share/containers/storage/overlay/...), visible from inside via /proc/self/mountinfo. Still ephemeral (dies with the container) and no raw host sockets/mounts were added, but the documented backup claim is inaccurate and host username/paths leak through mountinfo.
- no additional isolation violations observed: outbound network is blocked (HTTP 000), egress is confined to the in-envelope proxy (http://proxy:3128), inference is only the in-envelope service, and /run/secrets is a sealed 6.2G tmpfs.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- gradle
- delve
- golangci-lint
- staticcheck (go-tools)
- basedpyright
- flutter
- typo
- opsx
### Proposed enhancements
- other: gradle — GRADLE_USER_HOME is routed to ~/.cache/tillandsias-project/gradle but the directory is empty and the gradle binary is absent; preinstall gradle and pre-warm the distribution cache so the routing is usable instead of dead config.
- other: delve — gdb/lldb are present but there is no Go debugger; delve would enable interactive debugging of the Go tooling the forge is built around.
- other: golangci-lint — Go toolchain (go, gofmt semantics via gopls ecosystem) is present but no linter; golangci-lint bundles errcheck/staticcheck/govet and is two-lines-of-config to wire into CI.
- python: basedpyright — pyright is present but its actively-maintained, config-aware fork basedpyright (pairs with ruff) is absent, which gives better type checking of config-driven Python.
- dart: flutter — The Dart SDK ships at ~/.cache/tillandsias-project/dart but the Flutter toolchain does not, so the Flutter targets referenced by the flutter.md agent instructions cannot be built in-forge.
- other: typo — No source spell-checker is installed; typo cheaply catches typos in comments and identifiers across Rust/Go/Node and slots into pre-commit.
- other: workspace tmpfs split — AGENTS.md documents the workspace as a RAM tmpfs but /home/forge/src actually sits on the container overlay (host-backed). Carving /home/forge/src onto an enlarged RAM tmpfs (mode=0777) would realize the documented hot/cold split and keep large builds off host-backed storage; /tmp is only 256M and easy to exhaust.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260919T074247Z.stderr.log`
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
