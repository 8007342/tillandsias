# Smoke e2e findings — Windows (yolanda) — release 56.11.1.1 — PASS

## Run 2026-11-01T08:53Z→09:04Z — **PASS** (tag v56.11.1.1, tray 05341632f)

Lane: /smoke-curl-install-and-test-e2e, Windows, requested by macuahuitl-fedora
(ledger 991183d89). Upgrade over a WARM host, not clean-room (no distro
unregister, no Credential Manager wipe: that needs the operator's own word in
this session). No OpenCode, no agent turn (fleet pause to 2026-11-02 ~03:00Z):
the lane was `tillandsias-headless --cloud 8007342/ranitas --bash`, a
systemd-run unit in the guest, tray running, 5.5 GB host free.
Evidence: target/smoke-e2e/ on yolanda.

| step | verdict | evidence |
|---|---|---|
| 1 pre-flight step 4 | PASS | 00-run-start.txt; prior round archived |
| 2 pinned install | PASS | install_exit=0 |
| 3 tray reports the release | PASS | `tillandsias-tray 56.11.1.1 (05341632f)` |
| 4a vault unseals | PASS | 04-vault-journal.txt 08:54:06Z "vault unsealed (sealed=false)"; no "keyring locked"; no wipe-and-sign-in path |
| 4b readiness gate | PASS | 04-forge-lane.log `bringup: step=proxy-ready ms=54` for the already-running proxy; mirror `service_ready … mirror_seeded_(1)` |
| 4c forge up | PASS | `bringup: step=forge-start ms=23`; tillandsias-ranitas-forge-maintenance Up |

### Finding: stopping the lane still leaves the forge running (recurs from v56.10.31.2)

### Work Packet: smoke-finding/windows-lane-stop-orphans-the-forge-container

- owner_host: any (reproduced on windows; the lane runs inside the guest, so likely linux too)
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on v56.10.31.2 and v56.11.1.1
- evidence: 04-forge-lane-watch.txt. 15 s after `systemctl stop smoke-lane4`
  router, git-ranitas and inference were gone; tillandsias-ranitas-forge-maintenance
  was still Up. `podman stop -t 10` on it then failed SIGTERM and needed
  SIGKILL: "conmon exited prematurely, exit code could not be retrieved:
  conmon process killed". Same on v56.10.31.2 with the `--opencode` lane
  (container tillandsias-ranitas-forge), so it is not agent-specific.
- exit_criteria: SIGTERM to the lane's headless stops the forge container it
  started within the stop timeout, and the forge honours SIGTERM without a
  SIGKILL fallback.
