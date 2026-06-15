# Forge Diagnostics Summary — 2026-06-14T16:08:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T160501Z.log`
- **Forge version**: 0.3.260614.7
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
- flutter
- nix
- podman
- sqlite3
- redis-cli
- fzf
- tmux
- lazygit
- protoc
- buf
- yaml-language-server
- lua-language-server
- javac
- eza
- starship
- zoxide
- docker
- hyperfine
### Proposed enhancements
- dart: flutter — Referenced in agent instructions (instructions/flutter.md) but binary is not installed; needed for Dart/Flutter development workflows
- other: nix — Referenced in agent instructions (instructions/nix-first.md) as the caching discipline and methodology reference but nix binary is absent
- other: podman — Project build scripts (./build.sh, scripts/local-ci.sh) use podman extensively but container runtime is not available inside the forge
- other: fzf — Standard developer terminal UX tool for fuzzy finding; expected in a ready-to-use environment
- other: tmux — Terminal multiplexer for managing multiple sessions during development; common expectation
- other: lazygit — Terminal UI for git operations improves developer productivity; complements existing git/gh tooling
- other: protoc — Protocol Buffers compiler used across Rust/Go/TypeScript ecosystems; missing despite codebase likely using protobuf
- other: buf — Modern protobuf toolchain; pairs with protoc for linting/breaking-change detection
- other: yaml-language-server — LSP for YAML configuration files; no language server present despite extensive YAML usage
- other: sqlite3 — Common CLI tool for database debugging and inspection; absent from the image
- other: redis-cli — Redis CLI for debugging cache/queue interactions; absent from the image
- other: lua-language-server — LSP for Lua (used in Neovim configs and some tooling); missing LSP coverage
- other: hyperfine — Benchmarking tool for performance-sensitive Rust/Go code; absent from image
- other: eza — Modern ls replacement; developer UX improvement common in container images
- other: starship — Cross-shell prompt enhancement; developer UX polish

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T160501Z.stderr.log`
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
