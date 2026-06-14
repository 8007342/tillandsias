# Forge Diagnostics Summary — 2026-06-14T22:31:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T150524Z.log`
- **Forge version**: 0.3.260614.4
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 24 / 25 checks passed (96%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 96%

## Missing Capabilities

- `network_isolation.external_curl`

## Recommended Actions

- Verify enclave network isolation: forge should not reach external internet directly

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- cargo-udeps
- delve
- golangci-lint
- lldb-mi
- markdownlint-cli2
### Proposed enhancements
- rust: cargo-udeps — Detect unused dependencies in Tillandsias Rust workspace; runs cleanly in CI without network after deps are cached
- go: delve — Go debugger for Tillandsias Go components; preinstalled binary needs no special privileges
- go: golangci-lint — Comprehensive Go linter; single static binary, no runtime daemon needed
- rust: lldb-mi — LLDB machine interface for Rust debugging via IDE protocols; installable from distro packages in /tmp
- other: markdownlint-cli2 — Enforce consistent documentation style across specs, cheatsheets, and plan files; lightweight Node package installable to project-local cache

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T150524Z.stderr.log`
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
| event:container_stderr     | 1250   |

#### container_stderr — top 5 containers by line count
```
   1134 event:container_stderr container=tillandsias-inference
    103 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```
