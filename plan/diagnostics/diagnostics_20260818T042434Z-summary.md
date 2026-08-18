# Forge Diagnostics Summary — 2026-08-18T00:00:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260818T042434Z.log`
- **Forge version**: 0.4.260817.1
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 24 / 25 checks passed (96%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 96%

## Missing Capabilities

- `network_isolation.external_curl`

## Recommended Actions

- Verify enclave network isolation: forge should not reach external internet directly

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- /home/forge/.config/gh is tmpfs-mounted (1M) and returns Permission denied on directory listing; if gh tokens are expected to be injected at runtime, this mount may be masking a config injection path.
- /home/forge/.cache/tillandsias-project is a btrfs rw mount from the host; cache artifacts (cargo, npm, go, gradle) persist across forge sessions, which could leak build metadata between runs if not expected.
- /home/forge/.gitconfig is a ro btrfs mount from the host; git identity is exposed to all forge operations.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- {'tool': 'flutter', 'ecosystem': 'dart', 'why': 'Dart SDK 3.12.1 is installed but Flutter CLI is absent; agents instructed to use flutter via instructions/flutter.md will fail.'}
- {'tool': 'golangci-lint', 'ecosystem': 'rust', 'why': 'Go 1.26.5 is installed but golangci-lint is missing; standard Go linting workflow requires it.'}
- {'tool': 'nix', 'ecosystem': 'other', 'why': 'nix-first.md instruction references Nix but nix is not installed in the image.'}
### Proposed enhancements
- dart: flutter — Install Flutter CLI to match the flutter.md instruction file already deployed; completes the Dart/Flutter toolchain.
- go: golangci-lint — Pre-install golangci-lint for Go linting; avoids per-session install overhead and matches standard Go CI workflows.
- other: nix — If nix-first.md instructions are authoritative, nix must be present; otherwise the instruction file should be removed to avoid agent confusion.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260818T042434Z.stderr.log`
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
