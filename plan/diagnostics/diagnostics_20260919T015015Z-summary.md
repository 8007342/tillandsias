# Forge Diagnostics Summary — 2026-09-19T01:50:58Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260919T015015Z.log`
- **Forge version**: 56.9.13.1
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
- openssl
- zip
- pigz
### Proposed enhancements
- dart: flutter — Advertised as pre-installed in AGENTS.md and referenced by ~/.config/opencode/instructions/flutter.md, but no flutter binary exists in the image; installing the mirror-pinned SDK would make the forge match its docs
- web: chromium — AGENTS.md advertises headless/headful Chrome but no chrome/chromium binary is present on PATH; needed for in-sandbox browser-driven e2e probes
- go: delve — gopls is installed but the Go debugger dlv is missing, so interactive Go debugging in the forge is impossible
- other: openssl — libssl/libcrypto libs exist but the CLI is absent; cert/CA inspection is a daily task here (enclave CA, vendor-ca-bundle.crt) and the CLI is currently unavailable
- other: zip — Archive/compress tooling is partial (unzip/xz present, zip/pigz missing); adding zip rounds out artifact packaging within the sandbox

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260919T015015Z.stderr.log`
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
