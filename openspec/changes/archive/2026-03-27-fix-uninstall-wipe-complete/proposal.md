# Proposal: Complete --wipe cleanup

## Paths to remove (--wipe)

### macOS
| What | Path |
|------|------|
| Config | `~/Library/Application Support/tillandsias/` |
| Cache/secrets | `~/Library/Caches/tillandsias/` |
| Logs | `~/Library/Logs/tillandsias/` |
| Singleton lock | `$TMPDIR/tillandsias.lock` |
| Build locks | `$TMPDIR/tillandsias-build/` |
| Keyring entries | service=`tillandsias`, keys: `github-oauth-token`, `claude-api-key` |
| Stale Linux paths | `~/.config/tillandsias/`, `~/.cache/tillandsias/` |

### Linux
| What | Path |
|------|------|
| Config | `~/.config/tillandsias/` |
| Data | `~/.local/share/tillandsias/` |
| Cache/secrets | `~/.cache/tillandsias/` |
| Logs | `~/.local/state/tillandsias/` |
| Singleton lock | `$XDG_RUNTIME_DIR/tillandsias.lock` (fallback `/tmp/tillandsias.lock`) |
| Build locks | `$XDG_RUNTIME_DIR/tillandsias/` (fallback `/tmp/tillandsias-build/`) |
| Keyring entries | service=`tillandsias` (via `keyring` crate / GNOME Keyring) |

## Changes

1. **`scripts/uninstall.sh`** -- add comprehensive path removal in `--wipe` block
2. **`scripts/install.sh`** -- make the uninstall fallback message platform-aware

## Non-changes

- Base uninstall (no `--wipe`) stays the same: only removes binary/app/desktop entries
- No Rust code changes needed
