## Overview

Three independent bugs make container death invisible. Each bug is individually fatal -- any one of them prevents death events from reaching the application. All three must be fixed together.

## Bug Analysis

### Bug 1: Wildcard filter silently matches nothing

`podman events --filter container=tillandsias-*` treats the value as an exact container name, not a glob. The `*` is literal. Since no container is named `tillandsias-*`, the filter matches nothing and the stream emits zero events.

**Fix**: Remove `--filter container=...` from the command. Run `podman events --format json` unfiltered. The existing prefix check in `parse_podman_event()` already filters by name -- it just never gets the chance because no events arrive.

### Bug 2: Docker JSON schema vs Podman JSON schema

The parser reads `value["Actor"]["Attributes"]["name"]` and `value["Action"]`, which is Docker's event schema. Podman emits a different format:

```json
{"Name": "tillandsias-tetris-aeranthos", "Status": "died", "Type": "container", ...}
```

**Fix**: Read `value["Name"]` and `value["Status"]` instead.

### Bug 3: Status string "die" vs "died"

The match arm checks for `"die"` but Podman emits `"died"`. Additionally, `--rm` containers emit a `"cleanup"` event that should also map to Stopped.

**Fix**: Match `"died" | "remove" | "cleanup"`.

### Bug 4: Fallback cannot detect disappearances

The backoff fallback runs `podman ps -a` and reports containers it finds. But `--rm` containers (which ALL Tillandsias containers use) are removed immediately on death -- they never appear in `ps -a` as "exited". The fallback sees an empty list and reports nothing.

**Fix**: Track a set of container names previously reported as Running. After each `podman ps` poll, diff against this set. Any container that was previously running but is now absent gets a synthetic `Stopped` event. This set lives in the `backoff_inspect` method as local state.

## Tracing

Add `tracing::debug!` at:
- Event stream start/reconnect
- Raw JSON line received
- Parsed event dispatched
- Fallback activated
- Container disappearance detected

## Testing

`parse_podman_event()` is a pure function -- add unit tests covering:
- Valid Podman event JSON (all status values)
- Prefix filtering (matching and non-matching names)
- Malformed JSON
- Docker-format JSON (should return None, not crash)
