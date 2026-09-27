# Smoke e2e findings — v56.9.27.2 — 2026-09-27 — macOS — tlatoanis-macbook-air

- run_start: 2026-09-27T16:01:45Z
- evidence_dir: target/smoke-e2e   (the v56.9.27.1 run is archived under _archived-20260927t160145z/)
- forge_lane_outcome: NOT RUN — §4's --opencode forge lane is Linux/Podman-only; this is the macOS lane (§1, §1s, §2, §3 plus the real first-boot path). Not a completed cycle and not a guard stop.
- signature_verification: cosign:verified:1/1

**Verdict: PASS** — macOS lane of v56.9.27.2 (daily prerelease, fix-forward of v56.9.27.1; the promotion candidate). Operator approved the destructive legs for this release (2026-09-27).

Host: macOS 27.0, arm64, /bin/bash 3.2.57. Release base pinned:
`https://github.com/8007342/tillandsias/releases/download/v56.9.27.2`. Pre-state: tray v56.9.27.1 running.

## Steps

| Step | Result | Evidence |
|---|---|---|
| §1 curl-install (`install-macos.sh` from the pinned base) | PASS in 49 s: install_exit=0, curl_exit=0, `/Applications` (no fallback), `--reset-state` ran, `tillandsias-tray 56.9.27.2 (git 52e3bc32e)` EXACT, `PENDING: none` | 01-install-macos.log, 01-install-macos-exit.txt, 01-version.txt |
| §1s signature of the installed tarball | `cosign:verified:1/1` (`verify.sh` against `tillandsias-tray-56.9.27.2-macos-arm64.tar.gz.cosign.bundle`) | 01s-cosign.txt |
| §2 destroy (`scripts/e2e-step2-macos.sh`) | PASS: `ok:e2e-step2-macos:destroyed`, app-support gone, residue empty, tray stopped | 02-step2.log, 02-macos-residue.txt |
| §3 `--provision` from pristine | PASS: provision_exit=0, full download + in-process expand, `rootfs.img` newer than the destruction marker, `"status":"provisioned"` | 03-provision.log, 03-provision-exit.txt |
| §3+ real first BOOT (`open -a`, as the installer does) | PASS: guest `provision.state` = `phase complete` 18 s after launch; headless `active` / `success`, 0 restarts | 03b-boot-times.txt, 03c-provision-state.txt |
| §3 health check, LAST | PASS: `--diagnose --json` rc 0, provisioned=true, rootfs_present=true, version=56.9.27.2 | 03-diagnose.json |

Cheap 1377-hcnv recheck (the arm itself was closed on v56.9.27.1): `vm-swap.img` present beside `rootfs.img`, 4.0 KiB allocated, `tmutil isexcluded` → `[Excluded]`.

## Ledger claims (row read in §0.2b: 00-ledger-row.txt)

- **EXERCISED:** the macOS artifact installs, verifies (cosign + sha256) and provisions from a destroyed substrate, and a real first boot completes guest provisioning; 1425-8wir (the release integrity gate reports cosign's own reason) — its effect is that this release's asset set published, which this lane consumed.
- **NOT APPLICABLE:** the Windows MSYS cosign-regexp fix (Windows lane); 1427-utmy / 1432-x3ug (gate and fixture changes, not the installed product).
- **NOT CHECKED:** the `tillandsias-progress-tty` renderer crate (1420-9vpk) ships in this release but nothing in the 27.2 macOS tray uses it yet (its first consumer, 1420-83vf, landed after the cut); the GitHub login / QR flow (no login performed); the forge lane (§4, Linux-only).

## Known behaviour this release still has (fixed on trunk after the cut, not new findings)

v56.9.27.2 was cut before the macOS bundle (1420-inak, 1426-cb6g, 1244-9dx3, 1420-83vf, 1420-299a) landed on trunk, so this release still: stops a running tray with the executable-name `osascript` quit and an unhandled SIGTERM (the VM stop path is skipped and `vm-swap.img` can survive a reinstall), writes no `tray.log`, shows one opaque red chip on a provisioning failure, and prints `{"phase":…}` JSON from `--provision`. All five are fixed on origin/linux-next and ship in the next cut.

## Findings

None new. The smoke ran clean end to end: install, destroy, provision and the real first boot.
