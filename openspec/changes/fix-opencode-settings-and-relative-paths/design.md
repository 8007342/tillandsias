## Context

Two independent bugs block normal CLI usage. The OpenCode config uses a wrong key name causing startup failure, and AppImage CWD override breaks relative path arguments.

## Goals / Non-Goals

**Goals:**
- OpenCode launches without settings errors inside the forge container
- `tillandsias .` resolves to the user's actual working directory, not the AppImage mount
- Both fixes work transparently — no user-visible behavior change beyond "it works now"

**Non-Goals:**
- Adding file-level deny rules to OpenCode (its config doesn't support path-based deny lists)
- Changing AppImage packaging or FUSE mount behavior

## Decisions

### D1: Minimal valid opencode.json

The current config uses `"permissions": { "deny": [...] }` which is not a valid OpenCode config key. OpenCode uses `"permission"` (singular) with tool-level controls like `"edit": "ask"`, `"bash": "ask"`.

Replace with a minimal valid config. Since OpenCode doesn't support file-path deny lists, the security intent (blocking access to `~/.config/gh`, `~/.claude`, etc.) cannot be expressed in the config file. Instead, rely on the existing container mount strategy — sensitive directories are either not mounted or mounted read-only, which is the actual security boundary.

The new config will contain only `$schema` for validation support, and set `autoupdate` to false (updates are managed by the entrypoint's `ensure_opencode()` with daily throttle).

### D2: Resolve relative paths against $OWD

When running as an AppImage, the FUSE runtime changes CWD to the mount point before executing the binary. AppImage sets `$OWD` (Original Working Directory) to the user's actual CWD at launch time.

In `runner.rs`, before calling `canonicalize()`, check if the path is relative AND `$OWD` is set. If so, prepend `$OWD` to the path before canonicalizing. This is the standard AppImage solution and affects no other code paths.

## Risks / Trade-offs

- [Risk] Removing the `permissions.deny` list means OpenCode has no config-level file restrictions. Mitigation: the actual security boundary is the container mount topology — sensitive dirs are not mounted into the container.
- [Risk] `$OWD` might not be set in all AppImage versions. Mitigation: fall back to standard `canonicalize()` when `$OWD` is absent.
