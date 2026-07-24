# macOS tray runtime status-UX parity with Windows (implemented 2026-07-23)

- **Date:** 2026-07-23
- **Class:** enhancement (tray status/tooltip UX; macOS-only)
- **Operator-directed:** "event propagation beyond github-login must be pretty-
  printed in the status element; users should never wonder if something is
  happening or if the system is stuck/unhealthy." Tray-ux governance: approved.
- **Relates to:** order 155 `macos-tray-stream-refactor`; vm-provisioning-lifecycle
  `ux.condensed-status@v1`.

## What was already at parity (verified, no change)

- Fedora **download** progress DOES reach the chip+tooltip (byte/% counter via
  `boot_vm_async` `on_phase` → `vz.rs` throttled emitter). Not a gap.
- `VmPhase` chip rendering, `last_event` suffix, `WIRE_UNREACHABLE` chip,
  crash-loop verdict chip+notification, and the four push topics
  (VmStatus/LoginState/CloudProjects/LocalProjects) are all at Windows parity.

## Gaps fixed this pass (`crates/tillandsias-macos-tray/src/action_host.rs`)

1. **[HIGH] Silent boot/connect tail → labeled phases.** The window between
   `vz.start()` and the first guest vsock reply (guest OS boot + agent bind;
   seconds, longer cold) was silent/static — the real "is it stuck?" moment.
   - `run_start` now emits `on_phase("Starting Fedora Linux")` before
     `vz.start()` and `on_phase("Connecting")` after (spec-verbatim condensed
     status, parity with windows `ProvisionPhase::StartingVm`/`Connecting`).
   - `boot_vm_async`'s post-boot chip is now `CONNECTING_CHIP_TEXT` ("🔵
     Connecting…") instead of a static "Starting…".
2. **[HIGH] No false "Reconnecting…" during first boot.** The vm-status poller's
   error path showed `WIRE_UNREACHABLE_CHIP_TEXT` ("🟠 Reconnecting to your
   workspace…") even before the guest had EVER answered — a normal (possibly
   slow) first boot looked unhealthy. Now gated on `vm_ever_ready`: before the
   first successful reply, a poll error leaves the curated Connecting… chip in
   place; the reconnecting chip is reserved for genuine mid-session loss.
3. **[XS] Tooltip now carries the build version.** `apply_status_text_main_thread`
   composes `"Tillandsias <version>\n<status>"` (parity with windows
   `compose_tooltip`) instead of the bare chip, so a hover confirms build+state.
4. **[XS] Provisioning phases sync to `menu_state.status_text`.** `set_status_text`
   and the `on_phase` closure now also write `menu_state.status_text`, so a menu
   rebuild mid-provision can't snap the chip back to a stale label
   (`apply_vm_status` already did this on the poll/push path).

## Deferred (low value / not this pass)

- **GAP 2 (phase vocabulary):** the download counter reads "Downloading Fedora
  Cloud image N/M MB (P%)" rather than the spec's "Downloading Fedora rootfs…".
  The counter is *more* informative (moves), so kept as-is; verbatim-string
  alignment is a cosmetic follow-up.
- **Failure-chip `— Retry` affordance + "Ready (VM may idle out)"** wording
  parity: XS cosmetic, deferred.

## Verification

- `cargo build --release -p tillandsias-macos-tray` — clean.
- `cargo test --release -p tillandsias-macos-tray` — 77 passed, 0 failed.
- Runtime-visible on tray relaunch: the boot→ready window now shows
  Starting Fedora Linux… → Connecting… → Ready (no false Reconnecting…), and the
  tooltip shows the version. The download-phase vocabulary is only exercised on a
  fresh cold provision (not a warm relaunch).
