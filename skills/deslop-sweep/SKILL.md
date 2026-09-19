# De-slop Sweep (order 829-dkuc)

The scheduled reconciler that removes what CRDT-style accretion leaves behind:
branches guarded by variables nothing sets, rows the fold still offers after
their work landed, ceremony that survives because each piece looks deliberate
alone. This skill is the PROTOCOL half of 829-dkuc; criteria 1-3 (the
detectors, the clock, the ritual detector) landed earlier. It was written
from the first supervised run on macuahuitl, 2026-09-13, under an operator
budget, and every rule below was applied there before it was written here.

## Authority

`methodology.yaml` is the source of truth. The sweep is a scheduled
meta-orchestration step, never a build gate. Its clock, record grammar and
kill rule live in `scripts/check-deslop-due.sh` and
`scripts/check-deslop-sweep-health.sh`; this file does not redefine them.

## 0 — Is it due, and is it budgeted?

```bash
scripts/check-deslop-due.sh check     # exit 0 = NOT due; prints ok:deslop-not-due:… or deslop-due:…
scripts/check-deslop-sweep-health.sh  # the ritual detector; a red here retires the sweep, not the queue
```

Due is event-counted (200 orders since the last sweep, 48 h floor, no
calendar ceiling). A sweep that is not due runs ONLY as an operator-paired
supervised run with an explicit budget — the sweep is a fan-out, the shape
the token directive bounds, and the first run ended one host's session.
Record the budget the operator gave (agents, tier, minutes) in the record's
note so the next sweep can compare.

## 1 — The corpus is a detector's worklist, never a judgement call

The sweep judges; a detector detects. Each run names its corpus from a
committed detector whose output is a list a stranger can reproduce:

```bash
scripts/check-dead-env-branches.sh        # TILLANDSIAS_* vars live code reads and nothing assigns or documents
scripts/check-stale-ready-rows.sh         # ready rows a landed commit subject cites (1144-jfr5)
```

Group findings by FILE before fanning out, so two agents never mutate one
file, and cap the fan-out at the operator's number (first run: 11 agents,
sonnet at medium effort, one Rust bundle because cargo is the cost, plus one
opus judge). Rust mutations are verified with `CARGO_TARGET_DIR` pointed at
the main checkout's warm target and the untracked router sidecar copied into
the worktree, or build.rs refuses before the compiler judges anything.

## 2 — One (mutation, predicted-observable) pair per finding, EXECUTED

For each finding the worker records, in this order:

1. what the guarded branch does (read the sites);
2. the HUNT for a setter or documentation the detector may have missed —
   Containerfiles, units, `*.env`, docs, workflows, and above all Rust code
   that builds a child environment (`.env(`), the forge launcher being the
   most likely blind spot for anything read inside `images/default`;
3. the verdict: DEAD (delete the branch and simplify), SEAM (a setter the
   detector cannot see — refuted, no deletion, the detector's blind spot
   named), DOCUMENT (a deliberate knob to document where the detector reads),
   REFUTED_BY_EXECUTION (the mutation broke the observable), INCONCLUSIVE
   (what would settle it);
4. the pair, prediction stated BEFORE the run: for shell `bash -n`, the
   file's own fixture, and `check-dead-env-branches.sh | grep -c VAR` going
   to 0; for Rust `cargo check` and the module's tests;
5. the observed output, verbatim to the verdict lines, and the diff.

A verdict without executed evidence is not a verdict. A worker that runs out
of budget returns what it finished as executed and the rest as INCONCLUSIVE;
it never rounds up.

## 3 — The judge applies the rules the packet names

- **Evidence**: any verdict without executed=true is downgraded, with why.
- **Refutation band**: the fraction refuted over examined is reported; zero
  refutations suspects rubber-stamping, near-total refutation suspects the
  detector; the band is scored across sweeps by the ritual detector.
- **Net-negative diff**: lines removed minus lines added over the confirmed
  set must be positive, or the offending mutations are dropped.
- **Filing cap**: at most 5 packets per sweep, and retractions (detector
  false positives fixed or allowlisted) must be >= packets filed.
- **Safety**: a deletion touching a fail-closed gate, a credential path, a
  consent gate or a fixture's planted evidence is downgraded and named.
- **Closing a multi_cycle packet drops its long-running row in the same
  land.** One of the first run's four land launches was refused because a
  multi_cycle packet was closed without removing its `plan/long-running.md`
  row in the same commit. The filing cap's packets are the sweep's own
  output, so this lands on the sweep: if a packet you file or confirm-close
  is multi_cycle, the row goes in the same commit that closes it, or the
  gate refuses the whole land (drill: plan/issues/fleet-restart-2026-09-12.md, Silverblue scope confirmed).

## 4 — Land once, record, measure

**Take the boundary before the cycle's first ledger write.** On the first run
the claim set-field and the claim event ran seconds before the boundary
snapshot in the same command, so the snapshot recorded the sweep's own two
untracked fragments as pre-existing dirt to preserve, and the guard refused
the land with `worktree differs from startup boundary` at finalisation — one
wasted land launch on the sweep's own record-and-file step. Order the cycle:
boundary snapshot first, then claim, then record and file. A boundary taken
after your own writes does not just refuse; it describes a tree that never
existed (drill: plan/issues/fleet-restart-2026-09-12.md, The coordinator's boundary read its own claim fragments as startup dirt).

**A present runtime symlink is not a tracked one.** The first run's land was
refused because a skill file's runtime link existed in the worktree but was
untracked: the single-source check reads TRACKED links only, so it passed
locally and the gate refused. Before landing, if any confirmed diff touches a
skill or runtime file, confirm its links into `.claude .opencode .codex
.github .gemini` are tracked, not merely present (drill: plan/issues/fleet-restart-2026-09-12.md, Silverblue scope confirmed).

The coordinator applies the confirmed diffs from the workers' returned text
(never from their worktrees), re-runs the detector, lands through
`scripts/land-on-platform-branch.sh` in ONE land, files the packets the judge
allowed, then records:

```bash
scripts/check-deslop-due.sh record --examined <n> --confirmed <n> --findings <n> --retracted <n> --filed <n> --net-lines <±n>
scripts/cycle-metrics.sh --emit-tokens host=<h> cycle=<id> main_ctx=<n> subagent_tokens=<n> agents=<n> by_model=<sonnet:11,opus:1> label=deslop-sweep
```

The record line is what the kill rule and the refutation band read; the
token line is what the next budget is set from. A sweep that confirms the
corpus is clean has done its job and records it as such.

**Record the whole cost, land attempts included.** The first run was written
up at ~21 min end to end; measured with its four land launches (skill-link
rule, self-kill, long-running-view rule, push race) it was ~44 min and ~140k
coordinator main-context. Since this section gates the sweep on an operator
budget and the token line is what the next budget is set from, a figure that
stops at fan-out and judging halves the next sweep's allowance. The recorded
end-to-end time and main-context count cover every land attempt for this
cycle's filings, not the fan-out and the judging pass alone (drill: plan/issues/fleet-restart-2026-09-12.md, The coordinator's boundary read its own claim fragments as startup dirt).

## What the first run taught (2026-09-13, macuahuitl)

Numbers: examined 29, confirmed 6 (deletions, net -49 lines), refuted 6
(all detector blind spots — the refutation band read 20.7%, honest by the
judge's own test), inconclusive 2, downgraded 15, packets filed 5 against 6
retractions. Cost: 12 agents (11 sonnet pairing, 1 opus judge), 1,024,451
sub-agent tokens, 918 s of fan-out wall clock, about 21 minutes end to
end including the coordinator's re-verification and landing; ~110k
coordinator main-context tokens.

- **The workers' worktrees were based on a stale commit**, not on the
  coordinator's HEAD (the harness branched them from an older ref). Their
  executed evidence was real but measured on the wrong tree: the coordinator
  re-runs every observable on trunk before landing, and the protocol treats
  the workers' verdicts as candidates, never as landings.
- **Take diffs from the worktrees, not from the returned text.** A returned
  diff truncated to a size cap is not a diff (the judge downgraded a real
  109-line deletion for that reason alone); `git -C <worktree> diff -- <files>`
  is the artifact, restricted to the confirmed finding's files so a bundle's
  unconfirmed mutations do not ride along.
- **Net-negative per mutation kills every DOCUMENT verdict.** Twelve of 29
  findings were deliberate knobs that only needed documenting where the
  detector reads; documenting adds lines, so the rule as written dropped all
  of them and they will be re-listed next sweep. The protocol finding for
  829-dkuc: compute net-negative over deletions, and give DOCUMENT findings
  one registry line each in a place the detector's DOCUMENTED pass reads
  (packet 1169-zw44's self-reference fix is the precondition), or the sweep
  cannot ever clear a knob.
- **The detector's blind spots were the sweep's main product**: four of the
  five packets are detector fixes (env-prefix assignments after `$(`, Rust
  reads with defaults bucketed as gating, Rust doc comments and wrapper
  setters invisible, the detector's own comments counted as reads). A sweep
  that refutes its detector 6 times in 29 is calibrating the instrument,
  which is what the refutation band is for.
- **One behavioural finding needed a fixture first, not a deletion**: the
  forge launch in orchestrate-enclave.sh is nested inside a never-taken
  conditional; the judge refused to land a 100-line de-nesting of live code
  in a script with no test (1170-e5im).
- **Clean the worktrees** (`git worktree remove --force`, prune, delete the
  `worktree-wf_*` branches) after the diffs are taken; ten of them held
  applied mutations.

- **A mutation control run from a scratch COPY of the script re-roots itself.**
  Every fixture and detector here derives its root from its own location
  (`REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`), so the
  pre-fix copy under `$TMP` looks for its siblings beside itself and reds for
  the wrong reason (rc=127, "No such file"), which reads as a valid "before".
  Run the pre-fix control from the repo path (`scripts/.pre-fix-control.sh`,
  removed after) or hand the root in explicitly, and read the control's
  failure LINE before counting it: a red for the wrong reason is not a
  control (macuahuitl and yolanda, 2026-09-13, the same trap twice in a day;
  six fixtures in scripts/test-*.sh copy a script into a temp dir).
