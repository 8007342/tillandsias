# Forge Diagnostics Summary — 2026-05-29T04:06:40Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T040556Z.log`
- **Forge version**: 0.2.260528.1
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- {'risk': 'proxy_external_access', 'detail': 'HTTP proxy at http://proxy:3128 returned HTTP 403 for example.com and HTTP 301 for google.com — external internet is reachable through the proxy. A fully isolated forge should return BLOCKED (curl connection failure). If access control is intentional, confirm via policy.'}
- {'risk': 'hot_cold_split_inactive', 'detail': 'All storage paths (/opt/cheatsheets, /home/forge/src, /tmp, /home/forge/.cache) share the same overlay root mount (952G). No separate tmpfs for /tmp or persistent bind mount for workspace was detected. The dual-storage architecture (tmpfs hot + persistent cold) is not active in this container instance, risking shared-storage pressure.'}

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- nix
- flutter
- wasmtime
- prettier
- black
- shellcheck
- shfmt
- delve
### Proposed enhancements
- other: nix — nix-first.md agent instruction exists but nix binary is not installed; package management and reproducible builds depend on it.
- dart: flutter — Dart SDK 3.12.1 is installed but flutter SDK is missing; flutter.md instruction file exists suggesting mobile/desktop/web UI development is in scope.
- wasm: wasmtime — wasm-pack 0.15.0 is present but wasmtime runtime is missing; WebAssembly execution and testing is incomplete without a runtime.
- web: prettier — No JavaScript/TypeScript/JSON/Markdown formatter pre-installed; formatting consistency across JS/TS/MD/YAML files requires prettier.
- python: black — Python linter (ruff) is installed but formatter (black) is not; Python code formatting relies on black for PEP 8 compliance.
- other: shellcheck — Project uses extensive shell scripting (entrypoints, build scripts); no static analysis for shell scripts is available.
- other: shfmt — Shell formatter is absent alongside shellcheck; consistent shell script formatting requires both.
- go: delve — Go toolchain 1.26.3 and gopls 0.22.0 are installed but Go debugger (delve) is missing; debugging Go code requires delve.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T040556Z.stderr.log`
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
| event:container_stderr     | 111   |

#### container_stderr — top 5 containers by line count
```
    103 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```
