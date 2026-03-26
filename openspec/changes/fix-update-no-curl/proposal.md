## Why

`tillandsias --update` shells out to the system `curl` binary to fetch `latest.json` and download the update archive. Inside an AppImage, this causes a library symbol mismatch:

```
curl: symbol lookup error: /lib64/libnghttp2.so.14: undefined symbol:
nghttp2_option_set_no_rfc9113_leading_and_trailing_ws_validation
```

The AppImage bundles its own copy of `libnghttp2` at a version that conflicts with the `nghttp2` that the system `libcurl.so` was built against. Because `LD_LIBRARY_PATH` is set by the AppImage runtime to prefer bundled libraries, the dynamic linker loads the wrong `nghttp2` for `curl`, causing a hard crash at symbol resolution time.

This is the same class of problem already fixed for terminal launches and podman calls (those clear `LD_LIBRARY_PATH` before spawning child processes). The `--update` path was missed in that cleanup.

## What Changes

- **`update_cli.rs`** — Replace `Command::new("curl")` calls in `fetch_url` and `download_update` with pure-Rust HTTP using `reqwest` (already compiled into the binary via `tauri-plugin-updater`). The CLI path runs before any Tauri event loop, so HTTP calls are driven by a minimal `tokio` single-threaded runtime using `block_on`.
- **`src-tauri/Cargo.toml`** — Add `reqwest` as an explicit direct dependency with `default-features = false` (reqwest 0.13 uses rustls by default) to make the existing transitive dependency directly accessible.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `update-system`: The `--update` CLI path no longer shells out to `curl`. All HTTP is done inside the process using the Rust HTTP stack already embedded in the binary.

## Impact

- **Modified files**: `src-tauri/src/update_cli.rs`, `src-tauri/Cargo.toml`
- **No new transitive dependencies**: `reqwest` 0.13 and `tokio` are already compiled into every Tillandsias build.
- **`tar` is still used** for archive extraction — `tar` does not link against `libcurl` and is unaffected by the nghttp2 conflict.
