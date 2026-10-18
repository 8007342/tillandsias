# Tasks — on-demand-image-ensure

Packet orders in brackets; dependency order top to bottom. Each task's closure
is the fixture named in its packet's exit criteria, written red against
today's code first (memory: exit criteria must fail on the pre-fix code).

## 1. Close the live hole (v0.5, first)

- [x] 1.1 `browser_open::start`'s Chromium branch ensures `chromium-framework`
      (and so `chromium-core`) before `network create`, with the WebKit
      first-use notice; `prepare`-style progress in the MCP reply [1776-ch4m]
      (done: the ensure and the notice; live progress during the wait is
      1776-pr0g, as the ch4m packet scopes it)
- [x] 1.2 One `launch_images(site)` table replaces the four inline ensure
      arrays; a Lua guard refuses a `tillandsias-<name>:v` spec literal in a
      module whose site neither lists nor ensures it [1776-ch4m]

## 2. Stop the retry storm (v0.5)

- [x] 2.1 `FailureMarker` keyed on `(image, source_digest)` beside the init
      state; `ensure_image_exists` refuses fast on a matching marker with
      the named cause, log and remedy; two automatic background retries on
      exponential backoff, then declared failed (operator ruling
      2026-10-17); agents get "busy" + `retry_after_s` meanwhile; marker
      cleared when the digest changes or on success [1776-brk3]
- [x] 2.2 `tillandsias --retry-image <name>` (foreground, forced rebuild);
      `IMAGE_BUILD_REMEDY` no longer says "retried on each launch"
      [1776-brk3] (no tray "Retry build" item: operator ruling 2026-10-17;
      MCP `prepare(force)` moves to 3.2 [1776-v1t4])
- [x] 2.3 The verdict line on every ensure decision (decided / digest /
      present / reason / marker) [1776-brk3]

## 3. One seam (v0.5)

- [x] 3.1 `build_vault_image` delegates to `ensure_image_exists` (lock,
      detach, marker, verdict) [1776-v1t4]
- [x] 3.2 `toolchain_exec::prepare` stops re-spawning a build after a
      failure; reports the marker's refusal (or "busy" + `retry_after_s`
      while a retry is scheduled); MCP `prepare(force)` [1776-v1t4]

## 4. Bound the build (v0.5)

- [x] 4.1 Free-space preflight on the podman graph root against a per-image
      need; `refused:image-ensure:<image>:disk:<free>/<need>`, no marker
      [1776-d5k2]
- [x] 4.2 `podman build` under `systemd-run --user --scope` weights
      (fallback `nice -n 10`); opt-out env for the gate [1776-d5k2]

## 5. Make it visible (v0.5)

- [x] 5.1 `image_build_progress(name)` generalised from the toolchain
      `STEP n/m` parser; tray status and MCP replies carry `step n/m`
      during any on-demand build [1776-pr0g]
      (browser.open no longer holds the call through the build: it answers
      `state: "preparing"` with the step and opens on a later call)

## 6. Live

- [ ] 6.1 On a Linux host with no `--init`: launch the forge, `browser.open`
      from inside it opens a window after one visible build; a second window
      opens without it; `podman rmi` + a broken Containerfile input +
      two launches = one build, one fast refusal [epic 1776-ondm]
