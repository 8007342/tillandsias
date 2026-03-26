## 1. Fix event stream command

- [ ] 1.1 Remove `--filter container=...` from `podman events` args
- [ ] 1.2 Keep `--format json` and add `--filter type=container` to reduce noise

## 2. Fix JSON parser

- [ ] 2.1 Change `value["Actor"]["Attributes"]["name"]` to `value["Name"]`
- [ ] 2.2 Change `value["Action"]` to `value["Status"]`
- [ ] 2.3 Update match arms: `"died" | "remove" | "cleanup"` for Stopped

## 3. Fix fallback disappearance detection

- [ ] 3.1 Add `HashSet<String>` to track known-running containers in `backoff_inspect`
- [ ] 3.2 After each `podman ps` poll, emit Stopped for containers that vanished
- [ ] 3.3 Update known set when containers appear or disappear

## 4. Add tracing instrumentation

- [ ] 4.1 Debug log on event stream start/reconnect
- [ ] 4.2 Debug log on raw JSON line received
- [ ] 4.3 Debug log on parsed event dispatched
- [ ] 4.4 Debug log on fallback activation
- [ ] 4.5 Debug log on container disappearance detected

## 5. Unit tests

- [ ] 5.1 Test parse_podman_event with valid Podman JSON for each status
- [ ] 5.2 Test prefix filtering (match and reject)
- [ ] 5.3 Test malformed JSON returns None
- [ ] 5.4 Test Docker-format JSON returns None (not our format)

## 6. Verification

- [ ] 6.1 `cargo check --workspace` passes
- [ ] 6.2 `cargo test --workspace` passes
