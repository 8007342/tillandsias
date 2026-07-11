# macOS overnight cycle 6/8 — destructive local-build e2e PASS on merged HEAD (2026-07-10T09:57Z)

- host: macos, osx-next @ 447451db (code-clean; only plan/ ledger files
  uncommitted at build time), unattended (overnight 6 of 8)
- preflight: `eligible`
- purpose: prove the full stack still provisions cleanly after order 267
  (strict litmus exit-code default) + order 260 (LocalProjects wire) merged.

## Gate

- build+codesign (build-macos-tray.sh, exit 0) → install ~/Applications →
  DESTRUCTIVE substrate wipe → cold provision (528MB Fedora image download +
  convert) `{"status":"provisioned"}` exit 0.
- Smoke via `--exec-guest` (idiomatic layer, no ssh): fresh disk boots to a
  healthy guest; `guest_up=yes`, guest headless v0.3.260710.8 present.

## Order 272 regression re-verify (fresh build)

- `sshd=masked`, `listen22=0` — SSH backdoor stays closed on this build.
- `fstab_mount=1` — home-src virtio-fs mount persistence (F-B) present.

## Notes

- Substrate left provisioned (disk only; --exec-guest stops the VM on exit,
  no tray launched). Clean for the morning operator or the next cycle.
- No new findings — clean run.
