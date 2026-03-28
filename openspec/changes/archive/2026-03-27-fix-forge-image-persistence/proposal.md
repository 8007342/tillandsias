# Proposal: Fix Forge Image Persistence on macOS

## Investigation Summary

### How the launch-time image check works

1. `main.rs` (line 296-297): Calls `forge_image_tag()` which returns
   `tillandsias-forge:v{CARGO_PKG_VERSION}` (currently `tillandsias-forge:v0.1.81`)
2. `main.rs` (line 297): Calls `forge_client.image_exists(&tag).await`
3. `client.rs` (line 64-70): Runs `podman image exists <tag>` and checks exit code
4. If the image is absent, triggers `run_build_image_script_pub("forge")` which
   extracts embedded sources to a temp dir and runs `build-image.sh`

### What happens on macOS

On macOS, podman uses `podman machine` (Apple Hypervisor VM). The startup sequence
in `main.rs` (lines 200-208) is:

```
1. Check is_machine_running()
2. If not running, call start_machine()
3. If start succeeds, proceed to image_exists() check
```

### Root Cause 1: Race condition after machine start

`start_machine()` (`client.rs` line 39-60) runs `podman machine start` and
returns `true` as soon as the command exits with code 0. However, on macOS,
`podman machine start` returns successfully before the API socket inside the
VM is fully ready to accept connections. This creates a window where:

- `start_machine()` returns `true`
- `image_exists("tillandsias-forge:v0.1.81")` runs immediately
- `podman image exists` fails because the socket isn't ready yet
- The image is reported as absent, triggering an unnecessary rebuild

Evidence from logs: On the session where the rebuild occurred (01:52:59), there
is no log entry for "Podman machine not running, starting automatically" -- this
means the machine was already running. However, if the machine had been auto-started
on a previous launch attempt (e.g., the failed launch at 01:46:00 where podman was
not found at all), the socket readiness race could still apply.

The most likely scenario for "rebuilds on every launch" is:

1. macOS reboots or podman machine stops
2. App launches, auto-starts machine
3. `image_exists` runs too quickly, returns false (socket not ready)
4. Rebuild happens (50 seconds wasted)
5. User quits app, relaunches
6. Machine is running this time, image check passes
7. But on the NEXT reboot, cycle repeats

### Root Cause 2: Staleness hash file destroyed after build

The build script (`build-image.sh`) maintains a staleness hash at
`$ROOT/.nix-output/.last-build-forge.sha256`. When invoked from the app:

- `ROOT` = `$TMPDIR/tillandsias-embedded/image-sources/` (temp directory)
- Hash file = `$TMPDIR/tillandsias-embedded/image-sources/.nix-output/.last-build-forge.sha256`
- After build completes, `cleanup_image_sources()` deletes the entire temp tree

This means the hash file is always lost. The build-image.sh staleness check can
never short-circuit -- it always falls through to a full nix build. This is the
**secondary** cause: even if `image_exists` correctly returns true (and the Rust
code skips the build), any build that IS triggered cannot benefit from staleness
caching.

### Root Cause 3 (potential): Machine not persisting images

On some macOS setups, `podman machine` may not persist container images across
machine restarts if:
- The machine was initialized with a small disk
- The machine is recreated rather than restarted
- The VM disk is corrupted after an ungraceful shutdown

This would mean the image genuinely doesn't exist after a machine restart, and
the rebuild is necessary. However, this is the expected behavior of podman machine
and images should normally persist.

## Proposed Fix

### Fix 1: Add readiness wait after machine start (PRIMARY)

After `start_machine()` returns true, wait for the podman API to be ready before
proceeding. Implement a `wait_for_ready()` method on `PodmanClient`:

```rust
/// Wait for podman to be ready to accept commands after machine start.
/// Polls `podman info` with exponential backoff up to ~30 seconds.
pub async fn wait_for_ready(&self, max_attempts: u32) -> bool {
    for attempt in 0..max_attempts {
        if self.is_available().await {
            return true;
        }
        let delay = std::time::Duration::from_millis(500 * 2u64.pow(attempt.min(4)));
        tokio::time::sleep(delay).await;
    }
    false
}
```

Call this in `main.rs` after `start_machine()`:

```rust
if client.start_machine().await {
    // Wait for the API socket to be ready
    if client.wait_for_ready(8).await {
        has_machine = true;
    } else {
        warn!("Podman machine started but API not responding");
    }
}
```

### Fix 2: Add retry logic to image_exists check

Even without an explicit readiness wait, the `image_exists` check at launch
should retry on failure with a short backoff:

```rust
// In main.rs, replace the single image_exists call:
let mut image_present = false;
for attempt in 0..3 {
    if forge_client.image_exists(&tag).await {
        image_present = true;
        break;
    }
    if attempt < 2 {
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}
```

### Fix 3: Persist staleness hash outside temp directory

Move the build-image.sh hash file to a persistent location. When invoked with
`--tag`, write the hash file to `~/.cache/tillandsias/` instead of `$ROOT/.nix-output/`:

```bash
if [[ -n "$FLAG_TAG" ]]; then
    CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias"
else
    CACHE_DIR="$ROOT/.nix-output"
fi
```

This ensures the staleness hash survives temp directory cleanup.

## Recommendation

Implement Fix 1 (readiness wait) as the primary fix -- this directly addresses
the race condition. Fix 2 (retry) provides defense-in-depth. Fix 3 (hash
persistence) is a nice-to-have optimization that prevents unnecessary nix builds
when a rebuild IS triggered.

## Files to Modify

- `crates/tillandsias-podman/src/client.rs` -- Add `wait_for_ready()` method
- `src-tauri/src/main.rs` -- Call `wait_for_ready()` after `start_machine()`,
  add retry logic to `image_exists` check
- `scripts/build-image.sh` -- Use persistent cache dir when `--tag` is specified
