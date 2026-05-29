# Forge Diagnostics Summary — 2026-05-29T15:14:23Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T151307Z.log`
- **Forge version**: 0.2.260529.2
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
- nix
- pylsp
- markdownlint
- yamllint
- actionlint
- vale
### Proposed enhancements
- nix: nix — methodology.yaml and cheatsheets reference Nix flakes extensively; flake-based workflows cannot run without it
- python: pylsp — Python LSP server is absent despite Python 3.14 being installed; needed for editor-level diagnostics
- other: markdownlint — docs-heavy project with OpenSpec discipline; markdown quality enforced in CI but no local linter preinstalled
- other: yamllint — extensive YAML in methodology/ and plan/; no local validation tool
- other: actionlint — GitHub Actions workflows present; no local validation before push
- other: vale — prose linter for documentation quality; aligns with OpenSpec documentation discipline

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T151307Z.stderr.log`
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
| event:container_exit       | 7     |
| event:container_signal     | 3   |
| event:container_stderr     | 149   |

#### container_exit lines (head 10)
```
[2026-05-29T15:13:07.752Z] event:container_exit container=tillandsias-git-tillandsias exit_code=128
[2026-05-29T15:13:17.752Z] event:container_exit container=tillandsias-inference exit_code=137
[2026-05-29T15:13:27.752Z] event:container_exit container=tillandsias-tillandsias-forge exit_code=137
[2026-05-29T15:13:27.752Z] event:container_exit container=tillandsias-router exit_code=0
[2026-05-29T15:14:43.252Z] event:container_exit container=tillandsias-tillandsias-forge exit_code=0
[2026-05-29T15:14:48.311Z] event:container_exit container=tillandsias-proxy exit_code=139
[2026-05-29T15:14:48.669Z] event:container_exit container=tillandsias-git-tillandsias exit_code=128
```

#### container_signal lines (head 10)
```
[2026-05-29T15:13:17.752Z] event:container_signal container=tillandsias-inference signal=SIGKILL
[2026-05-29T15:13:27.752Z] event:container_signal container=tillandsias-tillandsias-forge signal=SIGKILL
[2026-05-29T15:14:48.311Z] event:container_signal container=tillandsias-proxy signal=SIGSEGV
```

#### container_stderr — top 5 containers by line count
```
    103 event:container_stderr container=tillandsias-proxy
     29 event:container_stderr container=tillandsias-inference
      9 event:container_stderr container=tillandsias-router
      8 event:container_stderr container=tillandsias-git-tillandsias
```
