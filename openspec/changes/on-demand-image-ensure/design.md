# Design — on-demand-image-ensure

All symbols are in `crates/tillandsias-headless/src` unless stated.

## 1. Inventory (measured 2026-10-17 on linux-next 59e5f4be6)

| image | context | built by `--init` (`INIT_IMAGES`) | ensured on demand today | launch sites that assume it |
|---|---|---|---|---|
| proxy | images/proxy | yes | `ensure_proxy_running` → `ensure_versioned_images(["proxy"])` | every enclave launch via `container_deps` |
| git | images/git | yes | `remote_projects` (`ensure_image_exists("git")`), opencode/web/enclave lists | clone, mirror |
| vault | images/vault | yes | `vault_bootstrap::build_vault_image` (OWN path: identity + build, no lock, no detach, no marker) | `ensure_vault_running`, cloudflare/github login (1770-z575) |
| inference | images/inference | yes | opencode/web/enclave lists; `accel_probe::inference_image_present` only probes | forge launch |
| router | images/router | yes | `local_web_preview::ensure_router` → `ensure_image_exists("router")`; lists | publish, browser windows (needs router RUNNING) |
| chromium-core | images/chromium (Containerfile.core) | yes | only as dependency of chromium-framework | — |
| chromium-framework | images/chromium (Containerfile.framework) | yes | `run_opencode_web_mode`, `run_observatorium_mode`, `run_status_check` lists ONLY | `browser_open::forwarder_spec`, Chromium window spec (`pull_never`), `mcp_socket` browser.open — **no ensure; the live defect** |
| forge-base | images/default (Containerfile.base) | yes | as dependency of forge | — |
| forge | images/default | yes | `tray::launch` (`ensure_image_exists("forge")`), opencode/enclave lists | forge launch |
| web | images/web | yes | `local_web_preview::Profile::image` | publish_local |
| web-wrangler | images/web-wrangler | yes | `local_web_preview::Profile::image` | publish_local (wrangler profile) |
| webkit | images/webkit | **no** | `browser_open::start_webkit` (first use, with notice) — the precedent | WebKit window |
| flutter | images/flutter | **no** | `toolchain_exec::prepare` (in-process slot; retries after failure) | forge toolchain exec |
| builder, warp | images/builder, images/warp | no | build scripts only (`scripts/with-tillandsias-builder.sh`) | dev only, out of scope |

Ensure lists today (four, drifted): `run_opencode_mode` = proxy, router, git,
inference, forge; `run_opencode_web_mode` = + chromium-core,
chromium-framework; `ensure_enclave_for_project` = router, git, inference,
forge; `run_status_check` = all eight. `run_observatorium_mode` = web,
router, chromium-core, chromium-framework.

Three mechanisms: `ensure_image_exists` (lock + detach + identity +
dependency + downgrade guard), `build_vault_image` (identity only),
`toolchain_exec::prepare` (slot + `ensure_image_exists`, retry after failure).

## 2. The shared mechanism

```
ensure_image(root, name, tag, caller) -> Result<Ensured, EnsureRefusal>
  1. runtime_phase::container_mutations_allowed()      (exists)
  2. downgrade_refusal()                                (exists)
  3. identity = ensure_image_identity(root, name, ver)  (exists; recurses deps)
  4. marker = FailureMarker::load(name)
       if marker.digest == identity.source_digest
          && !marker.retry_allowed(now)       -> Refused(BuildFailedPreviously)
       if marker.digest != identity.source_digest -> marker.clear()  (inputs changed)
  5. decision = decide_image_build(identity, observe)  (exists)
       Skip | Retag -> print verdict line, return
  6. preflight_disk(name)                               (NEW)
       free_bytes_at(podman store) < need(name) + 1 GiB -> Refused(Disk), NO marker
  7. detach helper (exists) -> helper takes flock(image-<name>) (exists)
       helper re-checks 4–6 under the lock (a waiter must see the winner's
       marker or image, never rebuild)
  8. build_image_with_logging under a resource scope    (NEW wrapper)
       progress -> push_udp_event + helper log `STEP n/m` (exists for toolchains)
  9. Ok  -> apply aliases (exists), marker.clear(), verdict line
     Err -> marker.record(digest, cause = describe_image_ensure_failure(...),
                           attempt += 1, next_retry_at = backoff(attempt)),
            verdict line, Err(format_on_demand_image_build_error)
```

Dependencies resolve in order through the existing recursion in step 3/7:
`forge` ensures `forge-base` first under its own lock; a failed base records
ITS marker and the dependent refuses with the base's cause (no second marker
for the dependent, so a fixed base retries the dependent at once).

### Failure marker

Path: `init_cache_dir()/image-ensure-failures/<image>.json` (the cache dir
`InitBuildState` already uses; survives reboot on purpose — a stale lock dies
with the session, a known-bad build input does not).

```json
{ "image": "chromium-framework", "source_digest": "sha256:…",
  "attempts": 2, "first_failed_at": "…", "last_failed_at": "…",
  "next_retry_at": "…", "cause": "<describe_image_ensure_failure text>",
  "log": "/home/u/.cache/tillandsias/tillandsias-init-chromium-framework.log" }
```

Backoff: attempt 1 → retry allowed after 10 min; attempt 2 → 1 h; attempt ≥ 3
→ never automatically (`next_retry_at: null`), operator retry only. The
digest key is the whole reason this is safe: a fix to any input changes the
digest and the marker is ignored and removed.

Refusal text (fast, no podman build spawned):

```
refused:image-ensure:chromium-framework:build-failed-previously
  inputs sha256:ab12… failed 2× (last 2026-10-17T16:02Z): <cause, first line>
  log: ~/.cache/tillandsias/tillandsias-init-chromium-framework.log
  next automatic retry: none — run `tillandsias --retry-image chromium-framework`
  (or the tray's "Retry build"), or change an image input.
```

`IMAGE_BUILD_REMEDY` stops saying "retried on each launch".

### Explicit retry

`tillandsias --retry-image <name>` removes the marker and runs the ensure
with `force=true` (`ImageBuildAction::ForceRebuild`, which `decide_image_build`
already has) in the foreground with progress. The tray exposes the same as a
menu item that appears only while a marker exists (`FailureMarker::list()`).
The forge's MCP `prepare` takes `force: true` for the same effect; without it
`prepare` reports `{"state":"failed","reason":"refused:image-ensure:…"}` and
does NOT respawn the build thread.

### Disk preflight

`image_disk_need(name) -> u64`: forge-base 8 GiB, forge 2 GiB, chromium-core
6 GiB, chromium-framework 2 GiB, webkit 2 GiB, inference 4 GiB, flutter
6 GiB, others 1 GiB (the numbers are the measured image sizes rounded up;
each is a constant beside the image's label so a Containerfile change can
adjust it). Store path: `podman info --format {{.Store.GraphRoot}}` (cached
once per process). `TILLANDSIAS_IMAGE_DISK_NEED_OVERRIDE=<bytes>` exists for
the fixture only. A disk refusal records NO marker (freeing space is the
remedy and the next launch should try).

### Resource bound

`podman_build_scope(cmd)`: if `systemd-run` is on PATH and `--user` works
(probe once, cached), prefix `systemd-run --user --scope --quiet -p
CPUWeight=50 -p IOWeight=50 -p MemoryHigh=<60 % of MemTotal>`; else `nice -n
10`. `TILLANDSIAS_IMAGE_BUILD_UNBOUNDED=1` opts out (the gate's own builds).
The wrapper keeps the child caller-owned (order 714-4r6w) and the log
streaming unchanged. On the macOS/Windows guest the same code runs inside
the VM, where systemd-run exists (Fedora guest) — unmeasured on WSL2; the
fallback is nice.

### Visibility

The build helper already logs `STEP n/m`; `toolchain_exec::build_progress`
parses it for one image. Generalise to `image_build_progress(name)` and have
the tray's status (`set_status(…, TrayIconState::Building)`) and the MCP
`prepare` reply carry `step n/m`. The first-use notice from `start_webkit`
("Prepared the … engine on first use (N s); later windows open without this
wait.") is reused verbatim for Chromium.

### Verdict line

`[tillandsias] image-ensure <name> decided=<action> digest=<identity>
present=<label digest|none> reason=<ImageBuildReason> marker=<none|attempts>`
on stderr for every ensure, and into the helper log. This is also the arm
1775-8tx5 needs: two installs under one version must print two digests.

## 3. Launch-site table and guard

`fn launch_images(site: LaunchSite) -> &'static [&'static str]` replaces
the four inline arrays. A Lua guard (`scripts/lua/check-launch-images-table.lua`)
greps `ContainerSpec::new(format!("tillandsias-<name>:v` and
`versioned_image_tag("<name>"` in the headless crate and fails if a name is
launched in a module whose site does not list it or ensure it inline. The
guard must assert its population (refuse on zero spec literals).

`run_opencode_mode` keeps `proxy, router, git, inference, forge` — chromium
moves to first use in `browser_open::start` (the operator's low-end-host
ruling: never build what the session may not use).

## 4. What stays where

- `--init`: unchanged loop over `INIT_IMAGES`; a success clears that image's
  marker; `InitBuildState` keeps its own `failed` entries (they are --init's
  resume state, not the launch breaker).
- `build-*.sh` dev scripts: untouched.

## 5. Fixtures (each red on today's code)

- `cargo test -p tillandsias-headless browser_open::chromium_window_ensures_its_image`
  — source-window arm: the Chromium branch of `start` reaches an ensure seam
  before `network create`; plus a seam test with a counting ensure.
- `scripts/lua/test-image-ensure-breaker.lua` — a context whose Containerfile
  is `FROM scratch\nRUN false`, `TILLANDSIAS_ROOT` pointing at it, two
  `--internal-ensure-image` runs: the first fails and writes the marker; the
  second exits non-zero within 5 s, prints `build-failed-previously`, and
  `podman build` was NOT spawned (podman shim counts calls); editing the
  Containerfile makes the third run build again; NEGATIVE CONTROL: a
  Containerfile that succeeds leaves no marker and a second run is `Skip`.
- `scripts/lua/test-image-ensure-disk-preflight.lua` — override need to
  2^60: refuses `:disk:` before any build, no marker written.
- `cargo test -p tillandsias-headless vault_image_goes_through_ensure_image_exists`
  — source arm + a held `image-vault` resource lock makes `build_vault_image`
  wait instead of building.
- `scripts/lua/test-image-build-scope.lua` — the spawn argv begins with
  `systemd-run`/`nice` unless `TILLANDSIAS_IMAGE_BUILD_UNBOUNDED=1`.
- `cargo test -p tillandsias-headless image_build_remedy_never_says_retried_on_each_launch`.
- LIVE: `podman rmi localhost/tillandsias-chromium-framework:v$(cat VERSION)`;
  launch the forge; `browser.open` from the forge → the window opens after a
  visible first-use build; a second `browser.open` opens without it.
