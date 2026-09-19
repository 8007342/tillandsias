# Smoke: curl-install e2e — v56.9.19.2 — linux / pirria — 2026-09-19

- run_start: `2026-09-19T20:44:12Z`
- evidence_dir: `target/smoke-e2e` (v56.9.19.1's evidence archived under `_archived-20260919t204412z/`)
- forge_lane_outcome: **no verdict — known red.** The in-forge agent failed on the
  Console rate limit and the automated early call terminated the lane 2m02s after
  launch. NOT `cold-host guard stop` and NOT `completed cycle`: the lane never
  reached the Credential Channel Guard.
- channel: daily (prerelease). Release base pinned to the tag.
- host: pirria, linux_immutable, 4 cores, 15 GiB. Branch `linux-next`.

## Verdicts

| § | verdict | evidence |
|---|---|---|
| §1 curl-install | **PASS** | `install_exit=0`; `Tillandsias v56.9.19.2` exact-matched; lock released 20:44:24Z |
| §2 destructive reset | **PASS**, after manual intervention | 2nd instance of the clearer failure — see below |
| §3 pristine init | **PASS** | `init_exit=0`; 0 hard failure classes; `vault healthy (initialized=true sealed=false v=1.18.5)`; no `preserving existing data volume` |
| §3b shutdown | **PASS** | `tillandsias-vault elapsed=1s grace=10s exit=0 oom=false` |
| §4 forge lane | **NO VERDICT — known red** | early call at 22:05:13Z; `opencode_exit=early-called:rate-limit` |
| §4c health | not run | the lane was terminated by the early call; §3b had already stopped the substrate cleanly |

PASS entry: v56.9.19.2 — install clean, reset clean (after intervention), init clean;
forge lane produced no verdict on the release's pre-declared known red.

## What this run does and does not establish

**ESTABLISHES**: the published v56.9.19.2 Linux artifact installs, the substrate
destroys, and the enclave re-provisions from a genuinely cold room. The three
Linux binaries in this tag are DIFFERENT ARTIFACTS from v56.9.19.1 — same
sizes, different SHA256 (VERSION embedded; `tillandsias-router-sidecar` is
identical because it does not embed it) — so this run executed bytes no prior
run had.

**DOES NOT ESTABLISH**: that the forge lane works. §4's purpose — the in-forge
continuous-enhancement run — went unmeasured on BOTH tags today, because the
agent dies on the known rate limit before doing any work. §1-§3b must not be
read as standing for §4.

## Ledger claims (order 380)

The README row was FOUND this time (`ca33ccb7b`), unlike the v56.9.19.1 run
which read `NO LEDGER ROW` at 17:05:41Z before the row landed at 17:32Z.

- **EXERCISED**: "FIX-FORWARD of v56.9.19.1 ... ZERO code delta" — confirmed at
  the source level and REFINED: zero source delta, but three rehashed Linux
  binaries. §1 installed and ran them.
- **NOT APPLICABLE**: the Windows tray this fix-forward exists to ship — not
  this lane's platform.
- **NOT CHECKED**: release run 35459238928's own job results; the forge lane's
  work (see above).

## Recorded, not findings

- The lane was launched twice. The first launch seeded from `plan/pirria-1270`,
  a plan branch, and the launcher REFUSED LOUDLY: `SEED NOT A PLATFORM BRANCH`,
  naming the remedy. That was operator error (this checkout was left on a plan
  branch after a push) and the banner caught it. Relaunched from `linux-next`
  with `behind=0 fetch-age-h=0 verdict=fresh` — a fresher seed than the .1 run,
  which ran `behind=6`.
- **A SCOPING DEFECT IN THIS RUN'S OWN EARLY-CALL POLLER.** The forge container
  started at 22:02:52Z, during the mis-seeded lane; the correctly-seeded lane
  launched at 22:03:11Z; the agent log holds exactly one run id (`aa1ea8eb`).
  The poller greps that log without scoping to a run, so **it cannot be proven
  that the error it saw belonged to the lane it was watching.** The verdict is
  unaffected — the rate limit is real and is the third independent observation
  today — but the claim "the early call fired on its own lane" is not
  supportable. This is 1189-7yvu's shape (a previous run's artifact read as this
  run's result) arriving inside the instrument written to fix 1275-ngrc.
  Recorded on 1275-ngrc; a real implementation must scope on run id, session id
  or a post-launch timestamp.

## Findings

Both of this run's findings are SECOND INSTANCES of packets already filed
against v56.9.19.1 (`plan/issues/smoke-e2e-findings-v56.9.19.1-2026-09-19-linux-pirria.md`)
and are recorded as events on those rows rather than re-filed:

1. `smoke-finding/vault-data-survives-the-clearer-on-a-subuid-owned-volume` —
   byte-identical warn line, `clear_exit=0`, same `podman unshare` intervention.
   **Now deterministic on this host**: the directory it failed to clear was
   created minutes earlier by THIS run's own §1 install, so it is not inherited
   state. Recorded with the S2_NOTE line.
2. `1275-ngrc` (the §4 lane) — the early call's 2m02s measurement against .1's
   2h21m32s, plus the poller scoping defect above.

**Positive, for the promotion basis**: `1134-u934` confirmed fixed a SECOND time
— `elapsed=1s grace=10s exit=0` here, `0s/10s/exit 0` on .1.
