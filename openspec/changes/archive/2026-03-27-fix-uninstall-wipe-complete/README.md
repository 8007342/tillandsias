# fix-uninstall-wipe-complete

**Type:** Bug fix
**Status:** In progress
**Created:** 2026-03-27

## Problem

Running `tillandsias-uninstall --wipe` does not remove all application data.
On macOS, `~/Library/Application Support/tillandsias/config.toml` survives a
full wipe because:

1. The uninstall script sets `DATA_DIR` to `~/Library/Application Support/tillandsias`
   and removes it _before_ the `--wipe` block, but the config directory
   (`config_dir()`) resolves to the **same path** on macOS. The `rm -rf "$DATA_DIR"`
   on line 34 should catch it, but the real issue is that additional paths are
   never cleaned: logs, singleton lock, build locks, and keyring entries.

2. The `--wipe` block only removes `$CACHE_DIR` and container images. It does
   not remove logs (`~/Library/Logs/tillandsias/`), singleton/build lock files
   in `$TMPDIR`, or native keyring entries.

3. On Linux, the log directory (`~/.local/state/tillandsias/`) is never cleaned.

## Solution

Extend the `--wipe` section of `scripts/uninstall.sh` to remove every known
application path on both macOS and Linux, plus keyring entries and lock files.
