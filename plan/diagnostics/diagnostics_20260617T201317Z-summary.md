# Forge Diagnostics Summary — 2026-06-17T20:14:48Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260617T201317Z.log`
- **Forge version**: 0.3.260617.1
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- GIT_AUTHOR_NAME and GIT_AUTHOR_EMAIL propagated into container environment — personal identifying information exposed (values redacted before commit)
- GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL also propagated — same exposure (values redacted before commit)

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- rustup
- flutter
- bash-language-server
- yaml-language-server
- delve
- nix
### Proposed enhancements
- rust: rustup — Project uses Rust extensively; rustup is needed for managing toolchains, components (clippy, rust-analyzer), and overrides; only rustc/cargo from Fedora packages are present
- dart: flutter — Dart SDK is installed but Flutter SDK is absent despite FLUTTER_ROOT env var being set; flutter.md instructions exist implying Flutter work is expected
- other: bash-language-server — Shell scripting is pervasive in the project (entrypoints, build scripts, CI); no LSP support for .sh files despite 196+ shebanged scripts
- other: yaml-language-server — YAML is the primary config format (methodology.yaml, plan.yaml, step files, CI configs); no YAML language server available for editing
- other: delve — Go is installed and the project has Go components; no Go debugger present
- other: nix — nix-first.md instruction references Nix workflow; env var TILLANDSIAS_SHARED_CACHE=/nix/store set but /nix does not exist; Nix store is not provisioned

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260617T201317Z.stderr.log`
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
| event:container_stderr     | 774   |

#### container_stderr — top 5 containers by line count
```
    763 event:container_stderr container=tillandsias-proxy
     11 event:container_stderr container=tillandsias-git-tillandsias
```
