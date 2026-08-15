# Forge Diagnostics Summary — 2026-07-28T00:14:32Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260728T001334Z.log`
- **Forge version**: 0.3.260724.1
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
- {'tool': 'nix', 'ecosystem': 'nix', 'why': 'Project uses Nix-first build system (build.sh, nix-first.md instruction) but nix binary is absent from the forge image'}
- {'tool': 'rustup', 'ecosystem': 'rust', 'why': 'rustc/cargo/rust-analyzer present but rustup missing - cannot manage toolchain versions or targets'}
- {'tool': 'bash-language-server', 'ecosystem': 'other', 'why': 'Shell scripts (build.sh, entrypoints, skills) lack LSP support for diagnostics'}
- {'tool': 'podman', 'ecosystem': 'other', 'why': 'No container engine available; E2E smoke tests and containerized builds cannot run inside the forge'}
### Proposed enhancements
- nix: nix — Preinstall nix package manager with flakes support to match the Nix-first build convention documented in methodology and agent instructions
- rust: rustup — Preinstall rustup so agents can manage Rust toolchain versions, add targets, and pin nightly/stable as required by project specs
- other: bash-language-server — Preinstall bashls to provide real-time diagnostics on the numerous shell scripts (entrypoints, build.sh, skill scripts)
- other: podman — Preinstall podman (rootless) to enable in-forge container operations for E2E smoke testing without requiring host-level podman

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260728T001334Z.stderr.log`
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
