# Published-release smoke — v0.4.260815.1 — windows FULL lane re-run — PASS (run-scoped; does NOT clear promotion)

- Date: 2026-08-16 (05:54Z–06:05Z), host `Yolanda` (Windows 11 26200, WSL 2.7.11.0)
- Skill: `smoke-curl-install-and-test-e2e`, FULL destructive Windows lane
  (operator-authorized tonight; the bounded lane ran earlier today)
- Release under test: `v0.4.260815.1` (channel `daily`), resolved live by
  `scripts/resolve-smoke-release.sh daily` — still the newest daily; no tag has
  been cut since this morning's FAIL record
  (`plan/smoke-e2e-v0.4.260815.1-windows.md`)
- Logs: `target/smoke-e2e/full-20260816/` (00b-asset-integrity, 01-install-windows,
  01-version, 02-destructive-reset, 03-provision-once, 04-status-once,
  05-guest-inspect, 06-status-final, 07-diagnose-final) — local evidence
- Branch: windows-next. Sibling heads at start: main 0548ee1f2,
  linux-next d1f61faba, windows-next 40516c610, osx-next 566d66538

## Verdict by step

| step | result |
|---|---|
| 0 — resolve release (daily) | pass — `channel:daily tag:v0.4.260815.1` |
| 0b — installer integrity | still-FAIL, known — 756-rfdr unchanged (`violation:release-asset-integrity:1`, install-windows.ps1) |
| 1 — curl install, version pin | **pass** — `sha256: ok (324046c5…390a)`, `tillandsias-tray 0.4.260815.1 (0548ee1f2)` |
| 2 — destructive substrate reset | **pass** — `wsl --unregister tillandsias` + 258 MB cache purge |
| 3 — pristine cold-boot provision | **pass** — `[provision] RESULT: VM Ready — control wire up ✓`, `provision_exit=0` |
| 4 — forge `--opencode` run | N/A on Windows (Linux/Podman lane only; no such surface on the Windows tray) |
| final post-condition (after last mutating step) | **pass** — wire reachable, phase Ready, podman_ready true, tray=guest=0.4.260815.1 |

## The finding that matters: the morning FAIL did not reproduce — the cold-boot readiness path is NONDETERMINISTIC in the shipped artifact

This morning's clean-room provision of the SAME tag on the SAME host failed
(757-4hdt: the `ExecStartPost` readiness probe killed the healthy daemon;
`preflight vsock_loopback missing` made the probe unsatisfiable). Tonight's
clean-room provision of the same published artifact PASSED:

- `05-guest-inspect.txt` — the shipped unit STILL carries the hazard:
  `ExecStartPost=/usr/local/lib/tillandsias/headless-ready.sh 42420`
  (with `StartLimitIntervalSec=120` / `StartLimitBurst=3`). The defect is in
  the artifact; it simply did not fire tonight.
- Cold boot bound the wire within ~1s of daemon start:
  `headless-ready.sh[397]: [tillandsias-ready] vsock_listener=bound port=42420`
  (first boot 06:58:26Z), and `journalctl | grep -c NOT-BOUND` = **0** across
  all boots (packet 757-4hdt exit-criterion-1 wording).
- `[tillandsias] preflight vsock_loopback loaded` — where the morning logged
  `vsock_loopback missing`. The module's availability is the variable that
  flipped; nothing in the artifact changed between the two runs.
- Vault bootstrap and the proxy image work happened AFTER the bind tonight;
  the proxy image materialized from the embedded imagestore in ~5s
  (`image tag … localhost/tillandsias-proxy:v0.4.260815.1`), not the
  minutes-long build the morning's daemon was killed inside.

Consequence, stated so nobody averages the two runs into "flaky-ok": one PASS
and one FAIL on identical artifact+host means the cold-boot readiness path is
environment-dependent. **The promotion verdict for v0.4.260815.1 remains the
morning's FAIL.** The fix is in `windows-next` (see the morning report); the
tag that carries it gets the one decisive re-run. No new packet filed —
this observation is appended as an event on
`guest-readiness-probe-kills-the-healthy-daemon-on-a-cold-first-boot`
(757-4hdt) per the de-duplication rule.

## Step detail and literal evidence lines

1. **Install** (`01-install-windows.log`): pinned to v0.4.260815.1, fetched
   SHA256SUMS-windows, `sha256: ok (324046c5c918f7a6685d40d1518068b9a5231e138f7e604a75fbd7bf70ba390a)`,
   extracted, `tillandsias-tray 0.4.260815.1 (0548ee1f2)` — the tagged commit.
   Smart App Control did not block (no os error 4551). `version_assert=PASS`
   (`01-version.txt` grep for the tag, per 727-kmks).
2. **Destructive reset** (`02-destructive-reset.log`): tray processes stopped;
   `wsl --terminate tillandsias` + `wsl --unregister tillandsias` both
   "The operation completed successfully"; post-list shows the distro GONE;
   `%LOCALAPPDATA%\tillandsias\cache` purged (258,506,328 bytes).
   Deliberate deviation from the skill's `wsl --shutdown`: shutdown stops the
   ENTIRE WSL VM including the unrelated `tillandsias-build` build distro
   (operator hard rail: never touch it). `--terminate` of the runtime distro
   alone is sufficient for `--unregister` and achieves the same pristine
   substrate. The skill text should adopt terminate-over-shutdown.
3. **Pristine provision** (`03-provision-once.log`): rootfs re-downloaded
   (66 MB), Fedora base + systemd/podman installed (143 transaction items),
   units enabled with no error, `[provision] phase: 🔵 Starting Fedora Linux…`
   → `Connecting…` → `[provision] RESULT: VM Ready — control wire up ✓`,
   `provision_exit=0`. Wall time ≈ 3.5 min.
4. **Post-provision idle-shutdown observation** (`04-status-once.json`): a
   status probe ~1 min after `--provision-once` exited returned
   `reachable:false … WSA_ERROR(10060)` because WSL had idle-stopped the
   distro (nothing held a keepalive once the one-shot CLI exited; the GUI
   tray was intentionally not running yet). Restarting the distro brought the
   wire back with zero intervention (warm binds at 06:00:10Z and 06:00:35Z).
   Expected lifecycle, not a defect; recorded so the next agent doesn't
   misread a 10060 immediately after a one-shot provision as a wedge.
5. **Guest inspection** (`05-guest-inspect.txt`): headless
   `Tillandsias v0.4.260815.1`; `tillandsias-headless.service` active
   (running), ExecStartPost exit 0; fetch service exit 0;
   `tillandsias-proxy` container RUNNING (egress/4b analog on Windows:
   proxy alive alongside the guest workload); podman 5.8.4; images
   proxy/vault present; `vsock_loopback` loaded. Benign known noise:
   vault `path is already in use at approle/` on re-bootstrap.
6. **Final post-condition** — taken AFTER the last mutating step (tray GUI
   relaunch, restoring the normal operator end state):
   `06-status-final.json`: `reachable:true, wire_version:2, phase:"Ready",
   podman_ready:true, exit_code:0`. `07-diagnose-final.json`:
   `version 0.4.260815.1, guest_version 0.4.260815.1, build_commit 0548ee1f2,
   distro_registered true, distro_running true, exit_code 0, wire Ready`.

## What this run does not establish

- The `--opencode` forge lane (Linux/Podman today) — no claim, as before.
- Promotion-worthiness of v0.4.260815.1 — explicitly NOT established; see the
  nondeterminism section. Tonight's PASS is evidence the lane and the host
  are healthy, and evidence the 757-4hdt failure is intermittent — it is not
  evidence the defect is gone (the probe is verbatim in the shipped unit).

## PASS entry (skill §5 "no silent passes")

v0.4.260815.1 (daily) — windows FULL destructive lane 2026-08-16: install
clean, unregister+cache-purge clean, pristine cold-boot provision to wire-Ready
clean (NOT-BOUND count 0), final diagnose clean. Forge lane N/A on Windows.
