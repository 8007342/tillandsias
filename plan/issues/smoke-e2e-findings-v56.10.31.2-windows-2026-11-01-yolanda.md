# Smoke e2e findings — Windows (yolanda) — release 56.10.31.2 — PASS

## Run 2026-11-01T01:09Z→01:21Z — **PASS** (tag v56.10.31.2, tray 5c81b9247)

Lane: /smoke-curl-install-and-test-e2e, Windows, requested by macuahuitl-fedora
(ledger row 1a03d4ca1). Upgrade over a WARM host, not clean-room: the
`tillandsias` distro was not unregistered and the vault entries in Credential
Manager were not cleared. The wipe approval arrived relayed by a peer session;
this host takes a vault wipe only on the operator's own word in its own
session, so the cold run is still owed. Evidence: target/smoke-e2e/ on yolanda.

| step | verdict | evidence |
|---|---|---|
| 1 pre-flight step 4 (run_start) | PASS | 00-run-start.txt; prior round archived |
| 2 pinned install (TILLANDSIAS_VERSION) | PASS | 01-install-exit.txt install_exit=0 |
| 3 tray reports the release | PASS | 01-version.txt `tillandsias-tray 56.10.31.2 (5c81b9247)` |
| 4a vault unseals | PASS | 04-vault-journal.txt: 01:10:47Z "vault unsealed (sealed=false)", from the stored key; no "keyring locked"; wipe-and-sign-in path did not appear |
| 4b readiness gate (#770) | PASS | 04-forge-lane.log 01:17:45Z `event:service_ready service=proxy status=ready-earlier` — the already-ready proxy that refused v56.10.31.1 twice is now accepted |
| 4c lane reaches the forge | PASS | `bringup: step=forge-start ms=26`; tillandsias-ranitas-forge Up; cloned 8007342/ranitas, seed branch main |

The lane was stopped after the forge came up (the agent run itself was not a
step of this request; host had 5.7 GB free).

### Observation (not a verdict): stopping the lane orphans the forge

`systemctl stop` of the lane unit tore down router, git-ranitas and inference,
but left tillandsias-ranitas-forge running. `podman stop -t 10` then needed
SIGKILL ("conmon exited prematurely"). Lane form: `tillandsias-headless --cloud
8007342/ranitas --opencode` as a systemd-run unit in the guest. Candidate
packet if it reproduces: the lane's SIGTERM path should stop the forge it started.
