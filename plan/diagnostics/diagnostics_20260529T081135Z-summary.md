# Forge Diagnostics Summary — 2026-05-29T08:11:49Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T081135Z.log`
- **Forge version**: 0.2.260528.1
- **Host platform**: unknown
- **Agent**: unknown
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- external_curl returns 403 (not connection refused) — container can reach external internet through proxy; exfiltration possible if proxy ACL is bypassed via HTTPS CONNECT to non-standard ports
- Proxy configured as plain HTTP (http://proxy:3128) with no TLS — any credentials or tokens sent through proxy are visible within container network
- GIT_AUTHOR_EMAIL and GIT_AUTHOR_NAME present in environment with real-looking values (bulloncito@gmail.com / Tlatoāni) — personal info leak if container is shared or outputs captured
- /run/secrets directory is mounted (from host) and world-readable — currently empty, but any future secret mount would be accessible inside the forge container
- All storage (src, tmp, cheatsheets) on single root filesystem — no isolation between ephemeral and persistent data; tmpfs mounts are limited to system pseudo-filesystems only

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- nix
- flutter
- black
- pylint
- prettier
- eslint
- delve
- yq
- git-lfs
### Proposed enhancements
- other: nix — nix-first.md instruction exists referencing spec:forge-bake-nix but nix binary is absent; required for nix-based workflows referenced in cheatsheets and cache discipline
- dart: flutter — flutter.md instruction present and dart SDK is at /opt/dart-sdk/bin/dart; Flutter SDK is the expected next layer for mobile/UI development
- python: black — Python formatter required for consistent code style; ruff and mypy are present but black is the standard autoformatter
- python: pylint — Complements ruff and mypy for Python linting coverage; no Python linter with configurable rule sets currently installed
- web: prettier — Universal formatter for JS/TS/JSON/Markdown/YAML; project already uses tsc but lacks a formatter for web assets
- web: eslint — Standard JS/TS linter; tsc provides type-checking only — no JS linting capability available
- go: delve — Go debugger; go and gopls are installed (language server) but no debugger for Go workflows
- other: yq — YAML processor analogous to jq (which is installed); needed for YAML-heavy workflows (OpenSpec, methodology, plan files)
- other: git-lfs — Git LFS support for large binary/asset files in repositories; standard git extension not present
- other: tmpfs-work-partition — All work paths (src, tmp, cheatsheets) live on same ~951MB root filesystem; mount a dedicated tmpfs (e.g. 4G) at /home/forge/.cache/tillandsias-work for ephemeral build artifacts to reduce wear and improve isolation per spec:forge-cache-dual

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T081135Z.stderr.log`
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
