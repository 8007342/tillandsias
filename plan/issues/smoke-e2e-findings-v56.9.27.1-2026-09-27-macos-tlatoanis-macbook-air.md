# Smoke e2e findings — v56.9.27.1 — 2026-09-27 — macOS — tlatoanis-macbook-air

- run_start: 2026-09-27T03:15:08Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-<ts>/)
- forge_lane_outcome: NOT RUN — §4's --opencode forge lane is Linux/Podman-only; this is the macOS lane (§1, §1s, §2, §3 only). Not a completed cycle and not a guard stop.
- signature_verification: cosign:verified:1/1

**Verdict: PASS** — macOS lane of v56.9.27.1 (daily prerelease; stable is v56.9.25.2). Operator approved the destructive legs for this release (2026-09-26/27).

Host: macOS 27.0, arm64 (Apple Silicon, 10 cores / 16 GiB), /bin/bash 3.2.57. Release base pinned:
`https://github.com/8007342/tillandsias/releases/download/v56.9.27.1`. Sibling heads at start: main 6bf78b7ab,
linux-next c567fdede, windows-next b38f71052, osx-next 1d0e3c5ae (00-sibling-heads.txt).

## Steps

| Step | Result | Evidence |
|---|---|---|
| Pre-state (banked before §1, which resets) | tray v56.9.25.2 running, VM live, no vm-swap.img | 00-pre-state.txt |
| §1 curl-install (`install-macos.sh` from the pinned base) | PASS in 63 s: install_exit=0, curl_exit=0, sha256 ok, `/Applications` (no `~/Applications` fallback), `--reset-state` ran, `tillandsias-tray 56.9.27.1 (git 6bf78b7ab)` EXACT, `PENDING: none` | 01-install-macos.log, 01-install-macos-exit.txt, 01-version.txt |
| §1s signature of the installed tarball | `cosign:verified:1/1` (cosign v3.1.3, `verify.sh` against `tillandsias-tray-56.9.27.1-macos-arm64.tar.gz.cosign.bundle`) | 01s-cosign.txt |
| §2 destroy (`scripts/e2e-step2-macos.sh`) | PASS: `ok:e2e-step2-macos:destroyed`, app-support dir gone, residue empty, tray stopped, 0 rootfs holders | 02-step2.log, 02-macos-residue.txt |
| §3 `--provision` from pristine | PASS in 14 s: provision_exit=0, full 528/528 MB download + in-process qcow2 expand, `rootfs.img` newer than the destruction marker | 03-provision.log, 03-provision-exit.txt |
| §3+ first BOOT on the real user path (`open -a`, as the installer does) | PASS: guest `provision.state` = `phase complete` at 03:18:19Z (16 s after launch), headless `success`, 0 restarts; `cloud-init status: done`; no failed units | 03c-provision-state.txt, 03c-1377-guest.txt |
| §3 health check, LAST | PASS: `--diagnose --json` rc 0, provisioned=true, rootfs_present=true, version=56.9.27.1 | 03-diagnose.json |

The §3 `--provision` block stages the disk image but never boots the VM, so the guest's first-boot provisioning —
the stage most likely behind the 2026-09-27 clean-MacBook field failure (1420-inak) — was exercised by an added
`open -a` step. It completed cleanly here, which is itself evidence for 1420-inak: the failure is host- or
network-specific, not a deterministic defect of this release.

## 1377-hcnv live arm (captured during the re-provision, read-only)

Guest (`--exec-guest`): `/proc/swaps` lists `/dev/vdb` 24 GiB priority 10 (virtio serial `tillandsias-swap`) and
`/dev/zram0` 2 GiB priority 100 (lzo-rle); `free` shows 25 GiB swap. Host: `vm-swap.img` beside `rootfs.img`, 24 GiB
apparent / 4.0 KiB allocated (sparse), `tmutil isexcluded` → `[Excluded]`. Per-launch lifecycle: removed by the
graceful stop path (`--exec-guest`); NOT removed when the tray is killed with SIGTERM (finding 1 below).
(03c-1377-guest.txt, 03c-1377-host-swap.txt, 03c-1377-after-stop.txt)

## Ledger claims (row read in §0.2b: 00-ledger-row.txt)

- **EXERCISED:** the release's macOS artifact installs, verifies (cosign + sha256) and provisions from a destroyed substrate; 1406-9ctt (the macOS upload job is gated) — the macOS assets this lane consumed were published and verified.
- **NOT APPLICABLE:** Windows/Linux-only claims; CentiColon R line, Lua runtime verbs, jq ratchet, drain-queue, deciders/fixture-regime claims (gate/tooling, not the installed product); 1200-ih38 Vault share validation (in-guest Vault is not exercised before a GitHub login).
- **NOT CHECKED:** 1401-p3k7 (Mac gates no longer delete `/Applications/Tillandsias.app`) — a gate property, not exercised by this smoke; 1411-b5fk / 1412-n5cp / 1414-mjdw / 1258-u8re (tooling, not the installed product); the GitHub login / QR flow (no login performed); the forge lane (§4, Linux-only).

## Findings

### Work Packet: smoke-finding/tray-sigterm-leaves-swap-image

- id: `1426-cb6g` (ledger row filed alongside this report)
- owner_host: macos
- capability_tags: [macos, tray, lifecycle, vm-layer]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.27.1`
- evidence:
  - `target/smoke-e2e/03c-1377-after-stop.txt` — after `pkill -TERM -x tillandsias-tray`: tray exits in 1 s, VM torn down (0 rootfs holders after ~2 s), `vm-swap.img` still present; after `--exec-guest`'s graceful stop: `vm-swap.img: No such file or directory`.
- repro: launch the tray, wait for the VM, `pkill -TERM -x tillandsias-tray`, `ls ~/Library/Application\ Support/tillandsias/vm-swap.img`.
- next_action: >
    Give the tray a SIGTERM handler that runs the same stop path (vz.rs `stop()` → `boot::remove_swap_image`,
    and the Drop impl that calls the same). install-macos.sh's own escalation is pkill -TERM, so every reinstall over a
    running tray takes this path. Impact is small (4 KiB allocated; relaunch recreates the file) but a
    SIGTERM that skips the VM stop path may skip more than swap cleanup.

### Event on existing packet 1244-9dx3 (install-macos.sh graceful quit)

MEASURED with the tray RUNNING (the case 1244-9dx3 could not probe): `osascript -e 'tell application
"tillandsias-tray" to quit'` left the tray alive for 30 s; `pkill -TERM` then stopped it in 1 s. The installer's
graceful stage is therefore a no-op in practice and every reinstall falls through to SIGTERM (see 1426-cb6g).
