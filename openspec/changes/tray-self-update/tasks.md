# Tasks — tray-self-update (2014-auup)

Design first. Nothing is built until the operator answers design §9. Each task
becomes one packet with a test that fails today.

## 1. Release side
- [ ] 1.1 The release workflow writes and signs `update-manifest.json` (Ed25519,
      minisign format); the public key is a build constant.
- [ ] 1.2 Each release's component declarations (restart, recreate, upgrade).

## 2. Verify and fetch
- [ ] 2.1 Event-driven check (start, menu open, 6 h cache), signature then digest,
      the three refusals; macOS code-signing requirement check.

## 3. Apply
- [ ] 3.1 Linux: atomic swap, `tillandsias.previous`, `--upgrade-handoff` (1490-gttj).
- [ ] 3.2 macOS path A: Vault stop, VZ save, swap, restore, credential re-delivery.
- [ ] 3.3 Guest headless replaced by a staged binary and a systemd path unit (macOS, WSL).
- [ ] 3.4 Windows: the update quit keeps the distro running.

## 4. Forges
- [ ] 4.1 `forge.update_status` (with 2003-stbf), and the fleet inbox line.
- [ ] 4.2 `required` restarts gated on a clean, pushed workspace.

## 5. Rollback and controls
- [ ] 5.1 Ready-within-120 s watchdog, `update-helper` on macOS and Windows.
- [ ] 5.2 `update.mode`, postpone, the tray rows (after operator review of the text).

## 6. Closure
- [ ] 6.1 A real update between two published stable releases on a Linux host with
      a forge running; macOS and Windows measured afterwards.
