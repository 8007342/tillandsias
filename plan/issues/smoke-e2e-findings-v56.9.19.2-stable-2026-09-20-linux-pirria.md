# Smoke: curl-install e2e — v56.9.19.2 — STABLE channel — linux / pirria — 2026-09-20

- run_start: `2026-09-20T09:17:12Z`
- evidence_dir: `target/smoke-e2e` (prior runs archived under `_archived-<ts>/`)
- channel: **stable, one-shot post-promotion.** `TILLANDSIAS_RELEASE_BASE` was
  deliberately UNSET so the installer performed its OWN `/releases/latest`
  resolution. The two daily-channel runs of this tag PINNED the base and
  therefore could not test this path; this run is not a repeat of them.
- forge_lane_outcome: **cold-host guard stop (EXPECTED PASS)** — and the lane
  RAN TO COMPLETION, which no Linux run had achieved on either tag.
- host: pirria, linux_immutable, 4 cores, 15 GiB. Branch `linux-next`.

## Verdicts

| § | verdict | evidence |
|---|---|---|
| §1 curl-install | **PASS** | `install_exit=0`; default resolution served `v56.9.19.2`, confirmed by the image tags produced (`localhost/tillandsias-proxy:v56.9.19.2`), not only by `--version` |
| §2 destructive reset | **PASS** | `reset_exit=0`, `clear_exit=0`, **no manual intervention** |
| §3 pristine init | **PASS** | `init_exit=0`; 0 hard failure classes; `vault healthy (initialized=true sealed=false v=1.18.5)`; `credential-cold` |
| §3b shutdown | **PASS** | `tillandsias-vault elapsed=1s grace=10s exit=0 oom=false` |
| §4 forge lane | **PASS** | guard stop, asserted from the guard line; lane exited on its own in 8m36s |

PASS entry: v56.9.19.2 stable channel — install clean, reset clean, init clean;
forge lane brought the enclave up and stopped at the credential guard, which is
the correct cold-host outcome.

## §4 — the first completed Linux forge lane, and the rate limit is gone

Launched `2026-09-20T09:29:58Z`, exited on its own `09:38:34Z` — 8m36s,
`opencode_exit=0`, the automated early call never fired, and **zero
`Rate limit exceeded` lines in the agent's own log**. Both daily runs of this
tag died at minute 2 on that limit. **The credential therefore recovered
between 2026-09-19T22:05Z and 2026-09-20T09:30Z**; this run dates it.

The outcome asserted from the guard line, never from exit 0 (order 1190-swen):

```
line 96: [check-credential-channel] The mirror is reachable but has NO upstream
         credential readable from Vault (mirror-published verdict: no-credential)
         ... stop BEFORE worker drain
line 97: blocked:upstream-no-credential
```

Residue: `git_status_empty=yes`, `head_matches_origin=yes`. The in-forge agent
claimed nothing, drained nothing, pushed nothing, and recorded its own smallest
next action (restore the mirror's Vault GitHub token). 384 lines of real agent
work — §4 finally exercising what it exists to exercise.

## A DEFECT IN THIS RUNBOOK'S OWN §4a-cold CRITERION, found by it passing

The residue check reports `mo_full_marker_present=yes`, and §4a-cold states the
expected cold-host value is **`no`** ("the ABSENT marker is correct and loud").
The marker present is:

```
MO-FULL: BLOCKED 7e33445f9988f69cf1bc95feff051670af97d2d4 linux-next 7e33445f9988f69cf1bc95feff051670af97d2d4
```

**That is correct behaviour and the criterion is wrong.** The meta-orchestration
skill sanctions it explicitly — `MO_FULL_DISPOSITION=BLOCKED
scripts/mo-full-attest.sh self`, and *"BLOCKED is exempt: a cycle saying it did
not finish must still be able to say so."* The check greps `^MO-FULL: `
generically and cannot distinguish `COMPLETE` from `BLOCKED`, so it flags a lane
that behaved exactly as designed and would send the next reader to investigate a
correct run.

Filed as an event on 1190-swen (whose criterion this is — mine, from
2026-09-18). The fix is on `work/1190-swen-cold-criterion` for relay, kept out
of this push so the report does not wait behind a gate.

## Regression checks that HELD

- **1284-jf86** — §2 cleared a subuid-owned `vault-data` with no
  `warn:clear-vault-credentials:partial` and **no manual intervention**, on a
  run not prepared to test it. Three hours earlier the same step needed
  `podman unshare rm -rf` by hand. The check is built into the run script, so
  every future run prints `1284-jf86 HOLDS` or `REGRESSION` rather than relying
  on someone noticing an absent warning.
- **1134-u934** — third confirmation: `elapsed=1s grace=10s exit=0`.

## Ledger claims (order 380)

Row read at `17bc1854c`, carrying the **STABLE** marker.

- **EXERCISED**: "promoted ... on three curl-install PASS reports" — this run is
  the post-promotion proof that the promoted artifact installs via the DEFAULT
  channel resolution an ordinary operator gets.
- **NOT APPLICABLE**: the macOS and Windows halves of the promotion.
- **NOT CHECKED**: the release workflow's own job results.

**A CORRECTION TO MY OWN EARLIER READ**: at run_start this host's checkout
predated `17bc1854c`, so §0.2b initially reported a row with no STABLE marker.
That was a stale tree, not a missing marker. Synced and re-read before relying
on it; recorded so the timestamps in this report cannot be mistaken for a
promotion that had not happened.

## Findings

**None new.** Both regression checks held, §4 passed for the first time, and the
only defect this run surfaced is in the runbook's own criterion (above), filed
against 1190-swen.
