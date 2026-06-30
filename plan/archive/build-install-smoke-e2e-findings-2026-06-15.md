# Local build/install smoke findings — 2026-06-15

## macOS Run (Pass + 1 finding) — 20260615T204805Z

- Discovered by: `/build-install-and-smoke-test-e2e (macos)`
- Host: macOS (Apple Silicon), branch `osx-next`, commit `11bd4e40`
- Built/installed: `tillandsias-tray 0.3.260614.9` → `~/Applications/Tillandsias.app`
- Evidence: `target/build-install-smoke-e2e/20260615T204805Z/`
- Passed gates:
  - `scripts/build-macos-tray.sh` exited 0; codesign valid + DR satisfied.
  - `--version` printed + exited 0 with **no VM boot** (regression guard for
    macos-tray/version-help-flags-boot-vm — holds).
  - Local install (atomic `.new`+`mv`) OK.
  - DESTRUCTIVE destroy of the VFR VM (1.3 GiB) — verified gone (top-level gate).
  - Cold re-provision exited 0: 528 MB Fedora Cloud image → converted →
    `rootfs.img` (5 GiB). `--diagnose --json`: `provisioned: true`,
    `release_tag: fedora-44`, schema stable.
- Forge lane: n/a (linux-only).
- Outcome: **PASS** — one quality finding filed (provision progress log spam).

## macOS Run 2 (Pass — verifies throttle fix, no new findings) — commit 21f62c3a

- Discovered by: `/build-install-and-smoke-test-e2e (macos)` (outer-loop iter 2)
- Re-ran the full lane after fixing macos-tray/provision-progress-log-spam.
- All gates PASS (build/codesign, --version no-boot, install, destroy 1.x GiB,
  cold re-provision provisioned:true fedora-44, diagnose schema stable).
- **Throttle verified**: provision log = **105 lines** (was 64,477 — ~614×
  reduction); `0 phase strings appear >1x` (perfect dedup).
- **No new findings.** macOS smoke loop is clean end-to-end on this commit.

## Work Packet: macos-tray/provision-progress-log-spam

- id: `macos-tray/provision-progress-log-spam`
- type: fix
- title: Fedora-cloud download emits ~64k duplicate progress lines (unthrottled on_phase)
- owner_host: macos
- capability_tags: [rust, macos, vm-layer, logging]
- status: done
- completed_at: 2026-06-15T21:05Z
- completion_note: >
    Added an AtomicI32 last_percent throttle to the Fedora-cloud download
    callback in vz.rs (mirrors the rootfs path) so on_phase fires only on
    integer-percent changes. Build + cargo test green (macos-tray 49 passed).
    Effect (≤101 vs ~64k lines) verified by the next smoke iteration's
    re-provision — see below.
- discovered_by: `/build-install-and-smoke-test-e2e (macos)`
- owned_files:
  - `crates/tillandsias-vm-layer/src/vz.rs`
- evidence:
  - `target/build-install-smoke-e2e/20260615T204805Z/03-provision.log` — 64,477
    lines for one ~528 MB download (632 distinct phase strings → ~100 identical
    lines per state, e.g. hundreds of `…3/528 MB (0%)`).
  - `crates/tillandsias-vm-layer/src/vz.rs:185-195` — the Fedora-cloud
    `download_verified` progress callback calls `on_phase(...)` on EVERY chunk
    with no change-detection, unlike the rootfs path at `vz.rs:563,577-588`
    which throttles via `last_percent`.
- repro:
  - any `tillandsias-tray --provision` from a pristine state; `wc -l` the
    streamed phases.
- next_action: >
    Mirror the rootfs path's integer-percent throttle on the Fedora-cloud
    download callback: only call on_phase when the percent changes. The callback
    must stay `Send + Sync` (download_verified bound), so use an `AtomicI32` for
    last_percent rather than a `Cell`. Expected: ≤101 download phase lines
    instead of ~64k.
- events:
  - type: discovered
    ts: "2026-06-15T20:55:00Z"
    agent_id: macos-claude-opus
    host: macos
