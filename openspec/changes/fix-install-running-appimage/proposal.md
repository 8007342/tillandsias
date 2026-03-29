## Why

`curl -fsSL .../install.sh | bash` fails with `curl: (23) client returned ERROR on write` when the AppImage is already running. `curl -o` can't write directly to a running executable ("Text file busy").

Also: `tillandsias --update` on old versions (v0.1.56) still uses `curl` which hits the nghttp2 library conflict inside AppImage. These users need `install.sh` to bootstrap to a newer version.

## What Changes

- Install script downloads to a temp file first, then uses `mv -f` (atomic rename) to replace the running AppImage. Linux `rename(2)` works even when the target is being executed.

## Capabilities
### New Capabilities
### Modified Capabilities

## Impact

- **Modified**: `scripts/install.sh` — download to temp + atomic rename
