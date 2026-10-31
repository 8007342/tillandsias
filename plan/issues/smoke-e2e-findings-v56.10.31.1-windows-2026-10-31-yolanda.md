# Smoke e2e findings — Windows (yolanda) — release 56.10.31.1 — FAIL

## Run 2026-10-31T17:17Z→17:32Z — **FAIL** (tag v56.10.31.1, tray 25dd6362f)

Lane: /smoke-curl-install-and-test-e2e, Windows, requested by macuahuitl-fedora
(ledger row d47783fc5). Upgrade over a WARM host, not clean-room: the
`tillandsias` distro was not unregistered and the vault entries in Credential
Manager were not cleared (operator's real credentials; hard rule on this host).
Evidence: target/smoke-e2e/ on yolanda.

| step | verdict | evidence |
|---|---|---|
| 1 pre-flight step 4 (run_start) | PASS | 00-run-start.txt run_start=2026-10-31T17:17:14Z; prior round archived |
| 2 pinned install (TILLANDSIAS_VERSION) | PASS | 01-install-exit.txt install_exit=0 |
| 3 tray reports the release | PASS | 01-version.txt `tillandsias-tray 56.10.31.1 (25dd6362f)` |
| 4a vault unseals (#750) | PASS | guest journal 17:18:07 "unseal key material loaded", 17:18:08 "vault unsealed (sealed=false)"; no "keyring locked"; wipe-and-sign-in path did not appear |
| 4b forge lane reaches the forge | FAIL | 04-forge-lane.log, 04-forge-lane-retry.log |

### 4b — the refusal, twice

`tillandsias-headless --cloud 8007342/ranitas --opencode` as a `systemd-run`
unit in the guest, tray running, 4.5 GB host free at start:

    event:service_ready_failed service=proxy container=tillandsias-proxy reason=no_ready_event_within_125s retry_after=5s
    Error: readiness gate: a hard requirement is not ready (tillandsias-proxy: no ready event within 125s); retry_after=5s. The forge was not started; launch again after retry_after.
    rc=1

Retried once per the refusal's own remedy: identical (17:31:42Z). Deterministic.

The proxy WAS ready: the resident headless (pid 330508, started by the tray)
logged `event:service_ready service=proxy status=proxy_listening` at
17:18:51Z and `bringup: step=proxy-ready ms=13839`; podman shows it
`healthy, restarts=0`, and its access log shows the lane's own git mirror
tunnelling github.com through it during the wait. The lane is a SECOND
headless process started ~17:27Z. Reading: its readiness gate waits for a
NEW ready event from an application-lifetime service that had already
announced ready before the lane existed, instead of reading current state.
Not host memory (lane ran to its own rc=1; no reaper involved).

Not a vault failure: the #750 fix held on this host.
