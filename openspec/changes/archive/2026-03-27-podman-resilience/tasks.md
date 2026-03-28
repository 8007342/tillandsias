## 1. Path detection

- [x] 1.1 Add `/opt/homebrew/bin/podman` and `/opt/local/bin/podman` to `find_podman_path()` in `lib.rs`

## 2. Events resilience

- [x] 2.1 Add attempt counter with reduced log frequency (every 5th attempt) in outer `stream()` loop
- [x] 2.2 Replace `podman events --help` reconnect check with `podman info --format json` in `backoff_inspect()`
- [x] 2.3 Log retry attempts at reduced frequency (every 5th attempt or on interval change)

## 3. Startup gating

- [x] 3.1 Skip podman events stream spawn in `main.rs` when `has_podman` is false or (needs_machine && !has_machine)
- [x] 3.2 Verified: event loop handles an empty/never-sending podman_rx channel gracefully (tokio::select branch never matches)

## 4. Bug fix: machine detection

- [x] 4.1 Fix `is_machine_running()` — was matching `"Running"` key in JSON, now matches `"Running": true` value

## 5. Testing

- [x] 5.1 `./build-osx.sh --test` — 96 tests pass, 0 warnings
- [x] 5.2 Live test: app launches cleanly without podman machine running — zero retry spam, "Podman events stream skipped" logged once
