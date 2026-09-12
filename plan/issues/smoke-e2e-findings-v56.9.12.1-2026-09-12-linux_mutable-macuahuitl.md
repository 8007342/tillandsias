# PASS v56.9.12.1 on linux_mutable macuahuitl (Fedora 44, 20c/62 GB, native overlay on btrfs, bare-metal coordinator desktop) — curl-install clean, clean-room reset, pristine init, forge lane COMPLETED, proxy alive, Vault unsealed

Lane: `/smoke-curl-install-and-test-e2e`, channel `daily`, run 2026-09-12T03:25:00Z–03:38:25Z,
detached (`setsid nohup`) with per-step assertions (727-kmks) and timing records (1013-qv7c).
Operator authorization: the operator's instruction of 2026-09-12 ("perform smoke tests and
promote to stable") and, relayed by yoga, "macuahuitl is also the strongest fastest host, if
the host doesn't matter then let Macuahuitl handle it". Release run 34668648875 concluded
`success` on all three jobs at 03:40:51Z.

| step | verdict | evidence |
|---|---|---|
| §0.2b ledger row | FOUND | README row written at cut time (7433f373d) |
| §1 curl-install | PASS, 212 s | `install_exit=0`; `tillandsias --version` = `Tillandsias v56.9.12.1` (exact tag) |
| §2 destructive reset | PASS, 21 s | `reset_exit=0`; containers, volumes, images all EMPTY |
| §3 init from pristine | PASS, 332 s | `init_exit=0`; Vault bootstrapped, 12+ policies, `base_url https://127.0.0.1:8201`; every image rebuilt |
| §4 forge lane | PASS, 240 s | `opencode_exit=0`; the in-forge agent (smoke mode) returned `MO-SMOKE: PASS` with "Substrate verdict — all checks hold: checkout resolves on linux-next @ c235ec2a, working tree byte-clean" |
| §4b egress | PASS | `tillandsias-proxy` alive alongside the lane (assertion taken at t+240 s by a concurrent watcher, not a grep for the teardown trace) |
| §4c health (LAST) | PASS | vault `"initialized":true,"sealed":false`; proxy, router, vault up; inference and the lane torn down by design |

Total wall: 13 min 25 s. Timing records (phase=smoke): curl-install 212317 ms, reset 20540 ms,
init 331660 ms, forge-lane 240107 ms, health-check 197 ms — no `supervisor-lost` record; the
detached run kept its supervisor on this host (62 GB, MemAvailable 57 GB throughout).

## Findings

None filed. Two observations, neither a defect:

- `03-init.log` carries five lines `[tillandsias] podman image failed: status=1 stderr=`
  (lines 10, 71, 178, 249, 411), each immediately before the build of the image it names and
  each on a store the reset had just emptied — the existence probe reporting "absent", printed
  by `--debug`. Init exited 0 and every image exists afterwards. Worth a friendlier `--debug`
  line, not a packet; recorded so the next reader does not file it.
- `~/src` on this host is ABSENT after the forge lane (`tillandsias . --opencode`) ran from the
  checkout: the launch created no host checkout. That is 776-jcf3's "must not come back on its
  own" holding on a real launch of the published binary, on the host the operator removed it from.

## Ledger claims (order 380) — the row for v56.9.12.1

EXERCISED
- "Windows tray placeholder check covers exactly the embedded arch (1122-xi2f)": not by this
  lane, but the SAME run's Windows job concluded success and published
  `tillandsias-tray-56.9.12.1-windows-x64.zip` (9,535,947 bytes); yolanda-windows confirmed
  local packaging and the 8/8 fixture arms. Cited here because the promotion decision reads
  this report.
- "~/src retirement verified on macuahuitl (776-jcf3)": exercised by §4 — no `~/src` after a
  real launch (above).

NOT APPLICABLE
- 1115-yvrq selector fix, the fragment-status-loss guard reopen rule (ac0ea1089), 1124-7f3u,
  the fleet-restart note, the 1122-6sqz runbook sentence: gate and ledger properties, exercised
  by lands, not by an install.

NOT CHECKED
- The forge lane ran the in-forge agent in SMOKE mode (verify-only) rather than a full
  continuous-enhancement cycle; the forge-internal findings stream is therefore the substrate
  verdict only. A full-mode lane on the promoted tag is the next thing this host can add.
- `tillandsias --version` after the run reports v56.9.12.1 — the local build label of this
  desktop rolled forward through the published installer, consistent with the operator's
  2026-09-12 ruling (1122-6sqz).
