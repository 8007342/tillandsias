# Forge Diagnostics Summary — 2026-06-17T20:24:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260617T202340Z.log`
- **Forge version**: 0.3.260617.2
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
- ripgrep
- rustup
- delve
- bash-language-server
- fzf
- tmux
- zoxide
- eza
### Proposed enhancements
- other: ripgrep — Universal code-content search; `Grep` tool in forge depends on rg; no alternative present
- rust: rustup — Rust toolchain manager — required for multi-target builds, component install (clippy, rust-docs), and nightly toolchains; only rustc/cargo from Fedora packages are present
- go: delve — Go debugger; Go SDK 1.26 is present but no debugger is available for it
- other: bash-language-server — Shell language server for LSP-based editing; shellcheck is present but no LSP companion
- other: fzf — Fuzzy finder — critical for interactive shell workflows, history search, file navigation; commonly expected in dev environments
- other: tmux — Terminal multiplexer for persistent long-running sessions inside the forge container
- other: zoxide — Smarter directory navigation; commonly bundled in ready-to-use dev environments
- other: eza — Modern ls replacement with Git integration, icons, and rich output; no colorized tree/file listing tool present

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260617T202340Z.stderr.log`
- **Total launch events**: 10
- **state=running**: 4
- **state=failed**: 0

### Distinct stage → state pairings

```
event:container_launch stage=opencode state=exited
event:container_launch stage=opencode state=starting
event:container_launch stage=opencode-git state=running
event:container_launch stage=opencode-git state=starting
event:container_launch stage=opencode-inference state=running
event:container_launch stage=opencode-inference state=starting
event:container_launch stage=opencode-proxy state=running
event:container_launch stage=opencode-proxy state=starting
event:container_launch stage=router state=running
event:container_launch stage=router state=starting
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 97   |

#### container_stderr — top 5 containers by line count
```
     89 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```
