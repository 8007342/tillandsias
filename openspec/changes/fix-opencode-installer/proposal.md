## Why

The OpenCode entrypoint manually downloads a tar.gz from GitHub releases, extracts with --strip-components=1, and chmod's the binary. This is fragile — the tar structure has broken before, and the update logic duplicates download/extract code. OpenCode has an official installer at `curl -fsSL https://opencode.ai/install | bash` that handles both install and update, detects architecture, and installs to `$HOME/.opencode/bin/opencode`.

## What Changes

- Replace manual tar download/extract/chmod in `install_opencode()` with the official curl installer
- Replace manual update logic in `update_opencode()` with the same curl installer (it's idempotent — exits early if same version installed)
- Update install path from `$CACHE/opencode/bin/opencode` to `$HOME/.opencode/bin/opencode` (the official default)
- Support OPENCODE_INSTALL_DIR for custom install location if needed

## Capabilities

### Modified Capabilities

- OpenCode installation: uses official installer instead of manual tar extraction

## Impact

- `images/default/entrypoint-forge-opencode.sh` — rewrite install/update functions
