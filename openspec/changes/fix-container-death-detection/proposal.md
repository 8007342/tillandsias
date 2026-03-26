## Why

Container death is completely invisible. When a `--rm` container dies, the tray never updates because three independent bugs in `events.rs` conspire to suppress all death events. The event stream silently produces zero events, the fallback polling never notices disappearances, and the user sees a permanently "running" ghost entry.

## What Changes

- **Remove broken wildcard filter** -- `podman events --filter container=tillandsias-*` silently matches nothing because the filter takes exact names, not globs. Remove it and filter in-process instead.
- **Fix JSON schema mismatch** -- The parser reads Docker's `Actor.Attributes.name` / `Action` fields, but Podman emits `Name` / `Status`. Switch to Podman's actual schema.
- **Fix status string mismatch** -- The parser matches `"die"` but Podman emits `"died"`. Also add `"cleanup"` which fires for `--rm` containers.
- **Detect container disappearances in fallback** -- The backoff fallback only reports containers it finds in `podman ps`. For `--rm` containers (all Tillandsias containers), dead containers vanish from `ps`. Track known-running containers and emit Stopped events when they disappear.
- **Add tracing instrumentation** -- Debug-level logs at key points for future troubleshooting.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `podman-orchestration`: Container death detection now works for all container types including `--rm` containers

## Impact

- **Modified files**: `crates/tillandsias-podman/src/events.rs`
- **Risk**: Low -- all changes are in one file, the fix aligns code with what Podman actually emits
