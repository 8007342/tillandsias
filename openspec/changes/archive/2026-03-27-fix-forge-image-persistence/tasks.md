# Tasks: Fix Forge Image Persistence on macOS

## Task 1: Add `wait_for_ready()` to PodmanClient [x]

**File**: `crates/tillandsias-podman/src/client.rs`

Add a new async method that polls `podman info` (or `podman --version`) with
exponential backoff to confirm the API socket is ready after machine start.

- [x] Method: `pub async fn wait_for_ready(&self, max_attempts: u32) -> bool`
- [x] Backoff: 500ms, 1s, 2s, 4s (capped), up to `max_attempts`
- [x] Uses existing `is_available()` as the readiness probe
- [x] Log each retry attempt at debug level
- [x] Log success at info level

## Task 2: Call `wait_for_ready()` after machine auto-start [x]

**File**: `src-tauri/src/main.rs` (lines 200-208)

After `client.start_machine().await` returns true, call
`client.wait_for_ready(5).await` before setting `has_machine = true`.

```rust
if client.start_machine().await {
    if client.wait_for_ready(8).await {
        has_machine = true;
    } else {
        warn!("Podman machine started but API not ready after retries");
    }
}
```

## Task 3: Add retry to launch-time image_exists check [x]

**File**: `src-tauri/src/main.rs` (lines 296-298)

Replace the single `image_exists` call with a retry loop (3 attempts, 2s apart).
This provides defense-in-depth for cases where the machine was already running
but the socket has a transient failure.

```rust
let mut image_present = false;
for attempt in 0..3u32 {
    if forge_client.image_exists(&tag).await {
        image_present = true;
        break;
    }
    if attempt < 2 {
        debug!(attempt, tag = %tag, "image_exists returned false, retrying...");
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}
```

## Task 4: Persist staleness hash outside temp directory

**File**: `scripts/build-image.sh` (line 21, and CACHE_DIR usage)

When `--tag` is provided (i.e., called from the app binary), use a persistent
cache directory instead of `$ROOT/.nix-output/`:

```bash
if [[ -n "$FLAG_TAG" ]]; then
    CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias"
else
    CACHE_DIR="$ROOT/.nix-output"
fi
```

This ensures the hash file at `$CACHE_DIR/.last-build-forge.sha256` survives
the temp directory cleanup performed by `cleanup_image_sources()`.

## Task 5: Test on macOS

Manual verification:

- [ ] Build and install: `./build.sh --install`
- [ ] Stop podman machine: `podman machine stop`
- [ ] Launch tillandsias
- [ ] Confirm logs show machine auto-start + readiness wait
- [ ] Confirm image is found (no unnecessary rebuild)
- [ ] Quit and relaunch -- confirm no rebuild on second launch
- [ ] Reboot macOS, launch tillandsias -- confirm no rebuild if image persists

## Priority Order

1. Task 1 + Task 2 (primary fix -- eliminates the race condition)
2. Task 3 (defense-in-depth)
3. Task 4 (optimization -- avoids redundant nix builds)
4. Task 5 (verification)
