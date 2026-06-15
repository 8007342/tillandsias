# Forge Diagnostics Summary — 2026-06-14T15:21:54Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T152053Z.log`
- **Forge version**: 0.3.260614.6
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
- delve
- flutter
- nil
- statix
- taplo
- yaml-language-server
- marksman
- gradle
### Proposed enhancements
- go: delve — Go debugger; GOPATH is configured and Go is installed but debugging is unavailable
- rust: taplo — TOML language server for Cargo.toml and Rust project configuration files
- other: yaml-language-server — YAML validation and completion for CI/CD pipelines, Docker Compose, and config files
- other: marksman — Markdown language server for spec documents, cheatsheets, and project documentation
- other: nil — Nix language server; methodology.yaml and nix-first instructions reference Nix workflows but no Nix tooling is installed
- other: gradle — GRADLE_USER_HOME is configured and Java is present but the Gradle binary is missing

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T152053Z.stderr.log`
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
| event:container_stderr     | 83   |

#### container_stderr — top 5 containers by line count
```
     70 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```
