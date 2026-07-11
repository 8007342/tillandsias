# macOS overnight cycle 1/8 — local-build e2e + order 272 verification PASS (2026-07-10T05:33Z)

- host: macos, osx-next @ 33151e4d, agent macos-...-fable5-20260710T0533Z (unattended)
- gate: build (scripts/build-macos-tray.sh, codesign OK, v0.3.260710.3) →
  install (~/Applications, embedded SHA == HEAD) → DESTRUCTIVE substrate wipe
  (2.1G) → cold provision (528MB Fedora image download + convert, exit 0) →
  first-boot cloud-init → guest probes via `--exec-guest` (idiomatic layer;
  no ssh, per orders 271/272).

## Order 272 verification (fresh guest, first boot on the new template)

- `sshd_service=masked`, `sshd_active=inactive`, `listen22=0` — no SSH
  daemon reachable on any interface; systemd-ssh-generator nulled (no
  AF_VSOCK ssh socket).
- `/root/.ssh/authorized_keys` and `/home/fedora/.ssh/authorized_keys`
  exist but are EMPTY (0 key-material lines) — cloud-init image stubs, not
  injections; no `ssh-ed25519`/`ssh-rsa`/`ecdsa` material anywhere.
- `fstab_mount=1` — order F-B mount persistence present on the fresh
  template too.
- wsl.rs audited: no SSH usage on the WSL2 path (criterion 3).

## Notes

- `--exec-guest` worked exactly as designed with no tray running — the F-E
  packet (order 277) remains about coexistence with a LIVE tray only.
- Tray left installed but NOT launched (unattended night; destructive
  cycles may repeat). Operator relaunch in the morning gets the fixed
  template on the already-provisioned rootfs.
