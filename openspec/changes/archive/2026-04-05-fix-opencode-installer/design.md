## Context

The current entrypoint manually downloads OpenCode from GitHub releases as a tar.gz, extracts it, and chmods the binary. This has broken before (archive structure changes, wrong strip-components). OpenCode provides `curl -fsSL https://opencode.ai/install | bash` which handles architecture detection, download, install, and updates idempotently.

## Goals / Non-Goals

**Goals:**
- OpenCode installs and updates reliably using the official installer
- First launch installs, subsequent launches update silently if needed

**Non-Goals:**
- Pinning to a specific version (follow latest)
- Caching the installer script itself

## Decisions

**Use official installer**: `curl -fsSL https://opencode.ai/install | bash` handles everything. It installs to `$HOME/.opencode/bin/opencode` by default. The installer is idempotent — if the same version is already installed, it exits immediately.

**Install to cache dir**: Set `OPENCODE_INSTALL_DIR=$CACHE/opencode` to keep the binary in the persistent cache directory that survives container restarts (mounted from host).

**Single function for install and update**: Since the official installer is idempotent, we don't need separate install/update functions. A single `ensure_opencode()` call handles both.

## Risks / Trade-offs

- [Risk] curl to a URL inside a container. Mitigation: same pattern used by Claude Code (npm install from registry).
