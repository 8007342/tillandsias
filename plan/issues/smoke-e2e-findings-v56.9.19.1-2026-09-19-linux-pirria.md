# Smoke: curl-install e2e — v56.9.19.1 — linux / pirria — 2026-09-19

- run_start: `2026-09-19T17:05:41Z`
- evidence_dir: `target/smoke-e2e` (previous runs archived under `_archived-<ts>/`)
- forge_lane_outcome: **no verdict — the agent failed at 2026-09-19T17:19:38Z on
  the known-red Console rate limit; lane killed at 02:21:32 elapsed.** This is
  NOT `cold-host guard stop` and NOT `completed cycle`: the lane never reached
  the Credential Channel Guard, because its agent died two minutes in.
- channel: daily (prerelease). Release base pinned to the tag.
- host: pirria, linux_immutable, 4 cores, 15 GiB. Branch `linux-next`.

## Verdicts

| § | verdict | evidence |
|---|---|---|
| §1 curl-install | **PASS** | `install_exit=0`; `Tillandsias v56.9.19.1` exact-matched the tag |
| §2 destructive reset | **PASS**, after manual intervention | see finding 1 |
| §3 pristine init | **PASS** | `init_exit=0`; no failure classes; Vault re-initialized from cold |
| §3b shutdown | **PASS** | `3b: 0 container(s) did not stop cleanly` |
| §4 forge lane | **NO VERDICT** | agent died 17:19:38Z; see finding 3 |
| §4b egress | **PASS** | no sample with lane containers up and proxy absent |
| §4c health | **PASS** | vault `sealed:false`; proxy present; version correct |

PASS entry: v56.9.19.1 — install clean, reset clean (after intervention), init
clean; forge lane produced no verdict on the release's pre-declared known red.

## Ledger claims (order 380)

**The README row for v56.9.19.1 did not exist at run start** — `NO LEDGER ROW
for v56.9.19.1` at `2026-09-19T17:05:41Z`. The row landed at `17:32Z` in
`d120ca863`, 26 minutes into this run. Per §0.2b a missing row is a finding, not
a skip; filed below. **The substitute read was the PR #117 body**
(`target/smoke-e2e/00-pr117-claims.txt`), which is an improvisation this runbook
does not sanction, and it is stated here rather than hidden.

PR #117's claims, accounted for:

**EXERCISED**
- "launcher built and installed" — §1 installed the published artifact and
  `--version` exact-matched the tag.
- "runtime residual 5/0" — §3's pristine init reached a healthy state from a
  genuinely cold room, and §4c found vault unsealed and proxy alive.
- The one declared red, `litmus:opencode-prompt-e2e-shape` on the Console rate
  limit, RECURRED here at 17:19:36Z and is recorded verbatim. This lane
  independently corroborates that the rate limit is live.

**NOT APPLICABLE**
- The Windows tray job's failure and the macOS job — not this lane's platforms.
  v56.9.19.1 shipped Linux assets only.

**NOT CHECKED**
- "pre-build litmus 369 pass / 0 fail" and "post-build smoke 12/13" — gate
  results on trunk, not re-run here; this lane tests the published artifact, not
  the gate.
- `scripts/release-preflight.sh ok` — not re-run.
- The forge's continuous-enhancement work the lane exists to exercise — the
  agent died before doing any, so §4's whole purpose went unmeasured.

## Recorded, not findings

- `seed-staleness: branch=linux-next local=5125754dd152 last-fetched-origin=e2c5fbe712d9 behind=6 fetch-age-h=1 verdict=stale` — the forge seeded from this checkout, 6 behind origin. The launch banner asks that it be checked; it was.
- `tillandsias-plan expert-serve --port 11436` running 1h33m at 0.0% CPU beside a `tail -f /dev/null` — the designed keep-stdin-open idiom, sleeping on a futex, NOT the 1004-8vkv stdin block. Recorded because the shape is close enough that the next reader will wonder.
- Lane-scoped containers were still up at §4c because the lane was KILLED rather than exiting; the runbook expects them torn down after a normal exit. A consequence of the kill, not a defect.
- **1134-u934 is confirmed FIXED in this release.** `tillandsias-vault`'s process tree is exactly the `1 bash / 10 vault / 11 tee` shape that row named as the cause, and it stopped in **0s with exit 0** — not the 30s-grace `Exited (137)` the row was filed for.

### Work Packet: smoke-finding/vault-data-survives-the-clearer-on-a-subuid-owned-volume

- id: `smoke-finding/vault-data-survives-the-clearer-on-a-subuid-owned-volume`
- owner_host: linux
- capability_tags: [podman, vault, release, testing, fail-loud]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.19.1`
- evidence:
  - `target/smoke-e2e/02-reset.log` — `warn:clear-vault-credentials:partial (cleared: keychain:vault-shamir-share-v1 keychain:vault-root-token-v1 failed: dir:vault-data) — the room is NOT cold; a partial clear is the state that looks clean and is not`
  - `target/smoke-e2e/02-clear-exit.txt` — `clear_exit=0`
  - `target/smoke-e2e/02-cred-before.md` — `credential-warm`, share created `2026-09-16T18:52:48Z`
  - ownership measured: `524388:lapto 755 vault-data`, subdirs `700` — a rootless `rm` as uid 1000 is refused
- repro:
  - on a host whose `~/.cache/tillandsias/vault-data` was written by a container under a subuid: `scripts/clear-vault-host-credentials.sh; echo $?; ls -la ~/.cache/tillandsias/vault-data`
- EXIT CRITERION, stated as the OUTPUT rather than the mechanism:
    after `scripts/clear-vault-host-credentials.sh` returns, the `vault-data`
    directory is ABSENT and `scripts/probe-credential-cold-state.sh` answers
    `credential-cold`, on a host where that directory is owned by a subuid.
    PRE-FIX RESULT: FAILS — `warn:clear-vault-credentials:partial … the room is
    NOT cold`, exit 0, directory intact, probe answers `credential-warm`.
    `podman unshare rm -rf` is ONE remedy (it worked here, rc=0) and the
    implementer may choose another; the criterion does not name it.
- NEGATIVE CONTROL: a host where the directory is owned by the invoking user
  must still be cleared, and a clearer that "succeeds" by no longer attempting
  the directory fails this criterion — absence is the requirement, not silence.
- next_action: >
    Make the clearer remove a subuid-owned vault-data, or refuse loudly when it
    cannot. Today it does neither: it fails, says so in a `warn:` line, and
    exits 0. WHY THIS MATTERS BEYOND ONE RUN: §2's own assertion
    `test ! -e "$VAULT_DATA_DIR"` is the only thing standing between this and a
    Linux smoke reporting a cold room it does not have — and the runbook records
    that every Linux pass since at least 2026-06 silently carried exactly this
    gap. Measured consequence when the room IS cold: §3 creates a fresh unseal
    secret from HKDF and does NOT log `preserving existing data volume`, so the
    keychain-volume resync path is genuinely exercised. Without the fix, a lane
    that trusts `clear_exit=0` tests nothing and says it tested everything.
- events:
  - type: discovered
    ts: `2026-09-19T17:12:00Z`
    agent_id: `linux-pirria-claude-20260919t170541z`
    host: linux

### Work Packet: smoke-finding/no-ledger-row-for-v56-9-19-1-at-smoke-time

- id: `smoke-finding/no-ledger-row-for-v56-9-19-1-at-smoke-time`
- owner_host: any
- capability_tags: [release, testing, docs]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.19.1`
- evidence:
  - `target/smoke-e2e/00-ledger-row.txt` — `NO LEDGER ROW for v56.9.19.1`
  - run start `2026-09-19T17:05:41Z` (`target/smoke-e2e/00-run-start.txt`)
  - the row landed at `2026-09-19T17:32Z` in `d120ca863` — 26 minutes AFTER this
    smoke began, so the finding is correct as of run start and stale as of now
- repro:
  - `awk -v tag=v56.9.19.1 …` §0.2b block against `README.md` at a commit before d120ca863
- next_action: >
    The release's README row is appended AFTER the tag is published and after
    the smoke lanes start, so a lane that reads it at §0.2b — which is where the
    runbook puts it, deliberately, so the run can be steered at the release's
    own claims — finds nothing. This lane therefore could not account for
    v56.9.19.1's claims in the way order 380 requires, and substituted the PR
    #117 body (`target/smoke-e2e/00-pr117-claims.txt`) with that substitution
    stated in the report. Either the row is appended before the smoke lanes are
    told to go, or §0.2b names the PR body as the sanctioned fallback so the
    substitution stops being improvised per-run. macneo filed the same finding
    for the same tag, which makes it a property of the release sequence rather
    than one lane's timing.
- events:
  - type: discovered
    ts: `2026-09-19T17:05:41Z`
    agent_id: `linux-pirria-claude-20260919t170541z`
    host: linux

### Work Packet: smoke-finding/forge-lane-hangs-forever-when-the-agent-errors-and-every-runbook-discriminator-reports-health

- id: `smoke-finding/forge-lane-hangs-forever-when-the-agent-errors`
- owner_host: linux
- capability_tags: [forge, opencode, testing, release, fail-loud]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.19.1`
- evidence:
  - `target/smoke-e2e/04-opencode-agent.log` (opencode's own log, captured from
    `/home/forge/.local/share/opencode/log/opencode.log` — a path this runbook
    never names):
    - `17:19:36.019Z ERROR stream error ... "AI_APICallError: Rate limit exceeded. Please try again later."`
    - `17:19:38.767Z ERROR stream error ... "AI_RetryError: Failed after 3 attempts. Last error: Rate limit exceeded."`
    - then NOTHING but `cleanup prune=7.days` at 17:20, 18:20, 19:20
  - `target/smoke-e2e/04-lane-diagnosis.txt` — lane killed at 02:21:32 elapsed
  - `target/smoke-e2e/04-opencode.log` — 23 lines, static from 2 minutes in
  - `target/smoke-e2e/04-opencode-exit.txt` — `opencode_exit=killed-no-verdict`
- repro:
  - run §4 with a credential that is rate-limited; the agent errors within
    minutes and the lane never terminates
- THE FINDING IS NOT THE RATE LIMIT. That is the release's known red and was
  pre-declared. The finding is that **§4 has no failure detection for its own
  central failure mode**: when the agent stops, opencode does not exit,
  `opencode_exit` is never written, and the lane runs until something external
  kills it. This run sat 2h19m past the agent's death.
- AND EVERY RUNBOOK DISCRIMINATOR REPORTED HEALTH. §4a's checks exist to
  separate "supervisor killed" from "product broken" and both answered in
  favour of waiting:
    - all six containers Up 2 hours, inference and git and vault healthy
    - `journalctl | grep -iE 'oom-kill|Killed process'` — empty
    - supervisor process alive
  A CPU-delta probe (sample `ps -o time` 60s apart) was added mid-run by the
  coordinator and also reported ALIVE — correctly: the process burns ~1 second
  of CPU per minute on an idle event loop plus an hourly cleanup timer. **A
  frozen process is detectable; a live process idling after its agent died is
  not, by any check the runbook currently prescribes.**
- EXIT CRITERION, stated as the OUTPUT: §4 terminates with a recorded verdict
  when the in-forge agent stops, whatever the cause, and the agent's terminal
  error appears in the host-side evidence. PRE-FIX RESULT: FAILS — the agent
  errored at 17:19:38Z and §4 was still running at 19:41Z with
  `opencode_exit` unwritten and every host-side signal reporting health.
- NEGATIVE CONTROL: a lane whose agent is genuinely still working must NOT be
  terminated. A fix implemented as a wall-clock timeout fails this — the
  historical ~70-minute figure for this host came from runs where the agent
  WORKED, so a timeout tuned to it would kill healthy long lanes and still wait
  70 minutes to notice a death at minute 2.
- next_action: >
    Surface the in-forge agent's terminal state to the host. The cheapest
    version is that the lane tails opencode's own log for a terminal error and
    exits; a better one is that the forge entrypoint exits non-zero when its
    agent does. Note for whoever takes it: the ONLY evidence that distinguished
    this state was a log file the runbook does not mention, inside the
    container, which means today the smoke cannot diagnose its own §4 without
    someone knowing to look there. That is the part to fix first — even a
    §4a line saying "read /home/forge/.local/share/opencode/log/opencode.log"
    would have turned two hours into two minutes.
- events:
  - type: discovered
    ts: `2026-09-19T19:41:00Z`
    agent_id: `linux-pirria-claude-20260919t170541z`
    host: linux
