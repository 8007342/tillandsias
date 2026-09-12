# Smoke E2E findings — v56.9.12.1 — linux_immutable / lenovinha — 2026-09-12

**PASS — v56.9.12.1, §1–§4c complete, immutable Fedora Silverblue (lenovinha), 13 GiB.**
Curl-install clean, destructive reset clean, pristine init clean, forge lane
`opencode_exit=0` in 89m47s with its supervisor surviving, final health check green.

- Release: `v56.9.12.1` (daily; stable-promotion candidate)
- Regime: immutable Linux / Podman rootless / Fedora Silverblue / 13 GiB / 8 cores
- Operator authorization for the destructive reset: obtained for THIS run, per 1004-vsh2.
  ~34.5 GB destroyed (20.18 GB images, 14.37 GB volumes incl. the Vault store and every
  project mirror). A coordinator's assignment was NOT treated as that authorization.

## Results

| Step | Result | Evidence |
|---|---|---|
| §1 curl-install | `install_exit=0` | `01-install-exit.txt`; `01-version.txt` = `Tillandsias v56.9.12.1` (asserted with `grep -qF`, so a stale PATH binary could not have passed) |
| §2 destructive reset | `reset_exit=0` | `02-reset-exit.txt`; `02-empty-store.txt` — 0 containers, 0 volumes, 0 images asserted |
| §3 pristine init | `init_exit=0` | `03-init.log` (3955 lines); Vault bootstrapped from nothing, 12 policies, unsealed |
| §4 forge lane | `opencode_exit=0` | `04-opencode-exit.txt`; `smoke-forge-lane duration_ms=5387253 exit=0` (89m47s) |
| §4b egress | proxy alive alongside lane | `04b-containers.txt` — taken WHILE the lane was up, all six containers |
| §4c health (LAST) | green | `05-health.log` — `"sealed":false`, proxy/vault/router up, lane-scoped gone by design |

## Timing records (`.cache/metrics/tillandsias-timing.jsonl`, phase=smoke)

    smoke-curl-install       231207 ms   exit 0
    smoke-destructive-reset  100008 ms   exit 0
    smoke-init-pristine      282743 ms   exit 0
    smoke-forge-lane        5387253 ms   exit 0     <- 89m47s

## The 1026-ps4n floor question — a sub-15 GiB datapoint

**lenovinha is 13 GiB and BOTH the lane AND its supervisor survived §4.** Run detached
(`setsid nohup`) from the first attempt, on yoga's advice.

This is the second host below the supposed boundary to complete §4, after yoga at 14 GiB
(84m46s, supervisor lost, lane fine). Taken together the two runs say the floor symptom
reported on pirria was **observer death, not lane death** — and on this host not even the
observer died. yoga has already retracted the stronger reading of their own measurement.
1026-ps4n's framing wants rewriting rather than extending: the design argument for the
on-disk stamp still stands (it is what captured yoga's run), but "the floor cannot do §4"
is not what the evidence says.

No kernel oom-kill at any point; all six containers healthy throughout.

## Ledger claims (order 380) — from the README row for v56.9.12.1

**EXERCISED**
- *Release-gate install side effect documented with the roll-forward ruling (1122-6sqz).*
  Observed directly: the §1 curl-install did not stop at installing — it ran a full image
  build and Vault bring-up as a side effect of `install.sh`. That is the documented
  behaviour, seen on the published artifact.
- *The plan-only push lane hole is filed (1124-7f3u).* Verified present on trunk:
  `plan/index.d/20260912t021027z-1124-7f3u-plan-lane-skips-guards-when-binary-absent-macuahuitl.yaml`.
- *The fragment-status-loss guard understands a reopen after falsification (ac0ea1089).*
  Ran the guard on the merged checkout: `ok:no-fragment-status-loss:15 checked`, rc 0.
  QUALIFIED: this is a repo gate, not a property of the shipped binary, so it was checked
  in the source tree and not through the release artifact.

**NOT APPLICABLE**
- *Windows tray placeholder check covers exactly the embedded arch (1122-xi2f).* Windows lane.
- *`~/src` retirement verified on macuahuitl (776-jcf3).* Claim is about another host;
  macuahuitl's own report for this tag records it holding there.

**NOT CHECKED** — this lane could have looked and did not
- *1115-yvrq selector fix (claimability is satisfaction, not containment).* A plan-selector
  property; reachable from here via `tillandsias-plan` but not exercised by this run.
- *Fleet restart drill and assignments (`plan/issues/fleet-restart-2026-09-12.md`).*
  Read for my own assignments, not validated as an artifact.

## Observations — no packets filed

1. **`podman image failed: status=1 stderr=` on the expected path.** Ten occurrences in
   `03-init.log` on this host (lines 10, 71, 178, 249, 411, 459, …), each immediately
   before `BUILD <name> (DigestMissing)` acted correctly on it. `podman image exists`
   returns 1 for ABSENT, which is the right answer on a store the reset had just emptied.
   The stderr is EMPTY, which is the tell.

   NOT FILED, deliberately: macuahuitl's report for this same tag
   (`…-linux_mutable-macuahuitl.md:26-32`) already records it as an observation and
   explicitly asks the next reader not to file it. Recorded here instead, with two
   additions:
   - **the count differs by regime** — 5 lines on macuahuitl (mutable), 10 here
     (immutable). This host builds more images from cold, so the expected-path noise is
     twice as loud on the lane that starts coldest.
   - **yoga dissents** and argues it is worth a packet, on the grounds that it teaches
     every reader of a clean-room init log to skim the word "failed", so a real failure in
     that stream arrives pre-discounted. That is the same family as three defects the
     fleet hit tonight (a guard whose pass and whose never-ran were both `violation:0`;
     a check whose exit status disagreed with its verdict; a lock that warned instead of
     refusing). I think yoga is right about the cost and macuahuitl is right that it is
     not a defect — which makes it a p3 `--debug` wording change, and I am leaving the
     decision recorded rather than filing over a peer's explicit "do not file".

2. **The in-forge agent hit a push refusal and gated itself.** `04-opencode.log:~477` —
   the forge's pre-push hook required a `--check` stamp in its fresh checkout and the
   in-forge agent ran the gate rather than overriding. Working as designed, and incidental
   evidence that the forge lane can gate.

3. **Order-298 teardown is the fix, not a regression.** `04-opencode.log:3696` carries
   `no active lane containers; cleaning project + shared stack` WITH the
   `keeping application-lifetime: tillandsias-vault, tillandsias-proxy, tillandsias-router,
   tillandsias-nix-cache` clause. Recorded because grepping the first half of that line
   alone would file a false regression, as the runbook warns.

## Note for the next triager (not a finding of this run)

My 1087-h2z9 land earlier tonight wired 16 checks into `--check` on the strength of
"measured green" — measured on linux/rootless, on one host. Two exceptions were found by
other hosts within the hour: `test-spec-index-durable-tier-demotion.sh` fails as root
(chmod 000 cannot constrain root; the Windows gate runs as root in WSL) and
`check-cheatsheet-refs.sh` exits 2 without `rg`. Moving a check from `--ci-full` to
`--check` changes WHICH HOSTS RUN IT, which is the one axis a single-host measurement
cannot see. Recorded in the 1087-h2z9 ledger; repeated here because this report is the
kind of document someone reads before wiring the next batch.
