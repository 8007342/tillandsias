---
name: meta-orchestration
description: "Host-aware Tillandsias recurring runtime loop: sync remote state, drain claimable plan work, run eligible e2e smoke gates, coordinate integrations on mutable Linux, release when warranted, update plan, commit, and push before exit."
---

# Meta Orchestration

This is the top-level unattended loop intended for:

```bash
./repeat --prompt "Use the /meta-orchestration skill"
```

It composes the worker, coordination, e2e, and release skills without replacing
their detailed runbooks.

## Invocation Modes — check FIRST, before anything else

The skill is parameterized by the invoking prompt. **Before doing any work —
before host classification, before `git fetch`, before reading the plan —
inspect the prompt that invoked this skill and pick the mode.** Full cycles
are token-expensive; running one when a smoke pass was requested wastes a
rate-limited provider budget (operator directive, 2026-07-11).

- **Full mode** (default): the prompt is a bare "Use the /meta-orchestration
  skill". Run the complete cycle described in the rest of this document.
- **Smoke Mode** (early break): the prompt contains the word `smoke` (e.g.
  "Use the /meta-orchestration skill in smoke mode (verify-only)"). You are
  inside a short e2e smoke test with a hard budget of a few minutes. Do NOT
  run a full cycle. Follow "Smoke Mode Runbook" below and exit.
- **Targeted verify** (a variant of Smoke Mode): the prompt names specific
  packets, orders, specs, or files (e.g. "…smoke mode, verify order 283" or
  "…smoke: spec git-mirror-service"). Same rules as Smoke Mode, but the
  verification set is the named targets' verifiable closures instead of the
  generic checks.

### Smoke Mode Runbook

Purpose: give fast, cheap feedback that the forge lane and the work under
test are healthy — WITHOUT advancing the plan or consuming a full-cycle
token budget. Hosted e2e gates (`litmus:opencode-prompt-e2e-shape`) invoke
this mode whenever the full cycle is rate-limited
(`scripts/forge-e2e-rate-limit.sh`, one full cycle per 4h per host).

Hard rules:

1. Do NOT claim ledger nodes, drain plan work, file routine findings, run
   nested e2e gates, release, commit, or push. A smoke run leaves the repo
   untouched. (Exception: a real defect discovered during verification may
   be reported in your final output text — the HOST files it, not you.)
2. Keep it small: prefer `scripts/run-litmus-test.sh --size instant
   --phase pre-build --compact` scoped with a spec filter when targets are
   named, plus cheap direct checks (parse `plan/index.yaml`, `git status`,
   `git fetch --dry-run` reachability, the targets' named verifiable
   closures). Skip anything that builds, launches containers, or exceeds
   the budget.
2a. **WHAT DECIDES THE VERDICT** (order 822-4vwa). Rule 2's last sentence and
   its first are in tension INSIDE A FORGE, because a large fraction of
   pre-build litmus needs vault, podman or vsock — none of which a forge has.
   An agent that runs the unscoped suite there gets a near-total failure that
   says nothing about the lane. So:

   - The VERDICT is the forge SUBSTRATE: the checkout resolves and is on the
     expected branch, the plan ledger parses, the plan/methodology experts
     answer, and the harness came up. If those hold, the lane is healthy.
   - Litmus results in a forge are a **REPORT**, on the same footing as the
     credential verdict in 3a. Quote the pass rate; do NOT convert it into
     `MO-SMOKE: FAIL` on its own.
   - When the invoking prompt NAMES targets, their scoped closures ARE part of
     the verdict — that is the whole point of a targeted verify.

   MEASURED on macuahuitl 2026-08-18, the same prompt on the same host 25
   minutes apart with a verified-fresh seed, disagreeing with itself:
   run 20260818T053811Z returned `MO-SMOKE: PASS` (post-build 11/11), and run
   20260818T063931Z returned `MO-SMOKE: FAIL litmus pre-build 0% pass rate
   (1/252); infrastructure-dependent failures expected but unconfirmed`. The
   second agent was right to refuse to bless what it could not confirm; the
   first agent's PASS is the one that should worry you. A gate whose result
   depends on how much the agent chose to run is not a gate.
3. Budget: finish well inside ~5 minutes of wall time.
3a. The **Credential Channel Guard is a REPORT here, never a gate** (order
   818-cgpn). That guard is a precondition for COMMITTABLE work, and rule 1
   says a smoke run performs none — it claims nothing, commits nothing and
   pushes nothing, so an absent or stale push credential cannot harm it.
   Report the verdict in your output and carry on verifying; do NOT return
   `MO-SMOKE: FAIL` for it.

   MEASURED on macuahuitl 2026-08-18, twice: with the mirror's upstream-auth
   verdict stale, the FULL lane blocked (correctly — it would have pushed) and
   the SMOKE lane returned `MO-SMOKE: FAIL credential channel blocked
   (upstream-auth-stale, 22880s > 900s max)`. Smoke exists precisely as the
   cheap path for when the expensive one is unavailable; gating it on the same
   credential leaves NO path, and takes the substrate-idempotence e2e (§2/§3,
   which never touch a credential) down with it — see 808-zrzz.
4. Verdict grammar: your FINAL output line MUST be exactly one of
   `MO-SMOKE: PASS` or `MO-SMOKE: FAIL <one-line reason>`. The launching
   litmus greps for this marker; a smoke run that exits without it is a
   failure by definition.

## Full-Mode Terminal Attestation (order 614-2gqx)

Smoke mode has a machine-grepped verdict (`MO-SMOKE:`); full mode did not, so
a normal provider exit between tool calls could discard local commits while
every outer launcher returned zero (the `4a1410a2` breach; see
`plan/issues/meta-orchestration-full-mode-exit-attestation-gap-2026-08-05.md`).

Full mode therefore MUST emit a typed terminal marker as its FINAL output
line, and MAY emit it ONLY after every finalization obligation below has
passed (boundary verification, `./build.sh --check`, commit, push):

```text
MO-FULL: <DISPOSITION> <LOCAL_SHA> <BRANCH> <REMOTE_SHA>
```

- `DISPOSITION` ∈ {`COMPLETE`, `BLOCKED`} — the cycle's terminal disposition.
- `LOCAL_SHA` = final local HEAD (`git rev-parse HEAD`) at emission time.
- `BRANCH` = the working branch the cycle committed to.
- `REMOTE_SHA` = the remote branch head after the push.

Invariants the outer gate (`scripts/mo-full-attest.sh`, wired into
`scripts/litmus-opencode-e2e-launch.sh` for `litmus:opencode-prompt-e2e-shape`)
enforces before it accepts exit zero:

- `LOCAL_SHA == REMOTE_SHA` — a marker may never follow an unpushed local
  commit. If the push failed after three rebase retries, do NOT emit the
  marker; mark the packet `blocked`/`failed-retryable`, include the push
  output, and stop — the missing marker is itself the loud failure.
- `BRANCH` must match the host's current branch.
- The claimed `REMOTE_SHA` must actually converge on
  `git ls-remote origin refs/heads/<BRANCH>` within the bounded relay window.
- A startup boundary must have been snapshotted at Start Of Cycle and verified
  at Finalization, at the HEAD being attested (order 717-3bvv). The guard writes
  cycle-scoped stamps into `$GIT_DIR`; `self` reads them. Skipping the snapshot
  therefore costs you the marker — which is the point: cycle 16 on windows
  skipped it, `verify` answered with a missing-directory message about the
  PREVIOUS cycle's already-removed temp path, and a valid marker printed anyway.
- `MO-SMOKE:` grammar and the shared full-cycle rate limit are unchanged; a
  smoke run never emits `MO-FULL:`.

**DERIVE the marker, never type it — and let the self-check emit it.** A
hand-typed SHA, or one half-copied from `git push` output, must be structurally
impossible. Do NOT assemble the line yourself. Run the self-attestation, which
reads every field from live git state, verifies local HEAD is durably on the
remote, and prints the verified line FOR you:

```bash
scripts/mo-full-attest.sh self   # prints the marker on success; MO-FULL: FAIL + non-zero otherwise
```

Emit its stdout verbatim as your final line. `self` derives the same values the
raw form would —

```bash
printf 'MO-FULL: COMPLETE %s %s %s\n' \
  "$(git rev-parse HEAD)" \
  "$(git symbolic-ref --short HEAD)" \
  "$(git ls-remote origin "refs/heads/$(git symbolic-ref --short HEAD)" | cut -f1)"
```

— but ALSO refuses to print anything when local HEAD is not the converged
remote head, so an unpushed or fabricated value is caught at emission, in every
lane. (`MO_FULL_DISPOSITION=BLOCKED scripts/mo-full-attest.sh self` for a
blocked-but-pushed cycle.)

**Make the marker durable — the transcript is not the record (order 651-2x5s).**
`self` verifies at emission time, but the emitted line lands in a transcript
nothing parses unless the litmus launcher runs; an operator-prompt or `./repeat`
cycle emits it into the void. `record` closes that: it runs the SAME
verification and appends the verified line to the per-host ledger under
`plan/mo-full-attestations.d/<host>.md`, a committed, machine-parseable log the
local gate (`scripts/check-mo-full-attestations.sh`, wired into
`./build.sh --check`) re-verifies. Automation consumes the ledger, never the
transcript. The ledger line attests the cycle's WORK head; committing the
ledger moves the head, so the terminal marker is re-derived at the head that
CONTAINS the record (see Finalization step 9 and
`methodology/mo-full-attestation.yaml`). Do not hand-write a ledger line: only
`record` may append, and only after the verification passes.

This is not pedantry. On 2026-08-10 a full-mode cycle on this host emitted a
marker whose first eight characters came from the `git push` output and whose
remaining **32 were invented to look like a SHA**. The work was genuinely
committed, pushed and green; only the proof was false (651-2x5s).

It went unnoticed because `scripts/mo-full-attest.sh check` — which would have
rejected it instantly, since it requires `git ls-remote` to converge on the
claimed value — is wired into exactly one caller, the
`litmus:opencode-prompt-e2e-shape` launcher. A cycle driven by an operator
prompt, a `./repeat` loop, or a cron emits the marker into a transcript nothing
parses, so that `check` never runs. **Without a check the marker is decorative,
and an unverified attestation is worse than none: it reads as proof and carries
none.** The `self` mode closes that gap by moving the same convergence
verification to emission time: EVERY lane self-checks, because the cycle proves
its own marker in the one command that prints it.

Any full-mode run that exits without a valid, converging `MO-FULL:` marker
has not completed its exit contract — regardless of the process exit code.
`scripts/mo-full-attest.sh fixture` / `scripts/test-mo-full-attest.sh`
reproduce the breach shapes hermetically (missing marker, malformed, unpushed
local commit, branch mismatch, remote-head mismatch, a well-formed but
fabricated SHA that matches nothing on the remote, clean pass — 7/7).

## Non-Negotiable Exit Contract

Local state is volatile. Before a successful exit, every meaningful result must
be committed and pushed to the correct remote branch.

- Exit cleanliness is relative to the startup worktree boundary. No
  uncommitted change created by this cycle may remain.
- Pre-existing tracked changes and status-visible untracked files are
  sibling/operator work, not temporary artifacts. Every path recorded by the
  startup boundary MUST remain byte-identical on every exit, including blocked
  exits. Never run broad `git clean`, `git checkout --`, `git restore`, or
  `git reset` against a worktree that was dirty at startup. Ignored trees are
  not hashed because they may contain an arbitrarily large build cache; they
  are not thereby cycle-owned and must not be overwritten.
- Automated finalization must never delete or restore worktree paths. Put every
  disposable diagnostic or scratch artifact under the unique external
  `$boundary_dir/tmp/` directory. Files created in the worktree are meaningful
  cycle output: commit and push them, or stop with a blocker and leave them for
  explicit operator disposition.
- Ensure any `tillandsias` background binaries or test processes are fully terminated.
- No local-only commits.
- No completed work without a `plan/` event or finding.
- No e2e pass/fail without a dated plan report.
- No blocked state without a blocker, owner if known, and smallest next action.
- Explicitly log things that make you slower (e.g., repeated steps, invalidated caches, uncoordinated scripts) into `plan/issues/`.

**SALVAGE BEFORE YOU REFUSE (order 872-c9nd). This is not optional and it comes
FIRST — before the handoff, before the blocker, before anything else.**

```bash
scripts/salvage-dirty-worktree.sh <slug>   # -> ok:salvaged:<ref>:<sha>
```

It pushes a COPY of the dirty tree — tracked modifications, deletions and
untracked files — to `salvage/<host>/<yyyymmdd>-<slug>` on origin, and it CANNOT
touch the worktree: it builds the commit through a temporary `GIT_INDEX_FILE`
and plumbing (`write-tree` / `commit-tree`), never a stash, an add against the
real index, or a checkout. Verified: worktree status and `.git/index` are
byte-identical afterwards, and `git show <sha>:<path>` returns an untracked
file's full content.

WHY THIS RULE EXISTS, and it is the most expensive lesson in this file. On
2026-08-23 a host wedged with 16 modified paths and one untracked litmus file
belonging to two claimed packets. Three consecutive cycles refused the dirty
tree, verified all 17 paths byte-identical to their boundary snapshots, and
wrote increasingly detailed prose about the diff. On 2026-08-24T06:09Z the
checkout was replaced by a fresh clone. Four hours of finished work are
unrecoverable; the untracked file's name appears in no commit on any branch.

**The boundary guard did its job perfectly and protected a directory that
someone then deleted wholesale.** A guard that forbids the AGENT from touching
the work does not forbid anything else from touching it, and a prose description
of a diff is not a copy of it. The refusal path was a place work could sit
indefinitely; it is now a place work passes THROUGH on its way to origin.

A dirty-start preflight refusal is not a work cycle and is the sole exception
to in-checkout blocker filing: touching `plan/` would itself violate the
startup boundary. Report `blocked: dirty-start-worktree`, owner, the exact
status paths, **the salvage ref and sha**, and the smallest next action in the
final handoff so the clean host/orchestrator can file it durably. Do not create
then delete a blocker file inside either the shared checkout or `$boundary_dir`.

If the salvage itself fails, say so loudly and do NOT soften the refusal: an
unsalvaged dirty tree is the exact state that cost four hours, and the operator
needs to know the copy does not exist before deciding what to do with the
directory.

**AN OPERATOR LICENCE CAN GO STALE, AND A CLEAN TREE IS HOW YOU KNOW.** When a
prompt authorises you to land dirt — order 833-fpe7's `resumable:` verdict,
order 540's opsx merge, or an operator sentence naming specific work to review
and land — CHECK THAT THE DIRT IS STILL THERE before acting on it. If
`git status --porcelain --untracked-files=all` is empty, the premise of the
licence is gone: answer **"the premise is gone"**, say what the licence expected
to find, and stop. Do NOT reconstruct what you think it referred to and land
that instead. This is how 872-c9nd was discovered: an operator relaunched a host
with a verbatim unblock prompt hours after the checkout had been re-cloned, and
the honest answer was that there was nothing left to land.

If a push fails after three fetch/rebase retries, mark the active plan item
`blocked` or `failed-retryable`, include the failed push output, and stop.

## Host Classification

Detect host at the start of every cycle:

- `forge`: Inside the Tillandsias developer forge container (typically detected by checking if `TILLANDSIAS_HOST_KIND` is set to `forge`).
- `linux_immutable`: Linux with `/run/ostree-booted` present or `rpm-ostree` on PATH.
- `linux_mutable`: Linux without the immutable marker (and not inside the forge container).
- `macos`: Darwin.
- `windows`: Windows, MSYS, MINGW, or PowerShell host.

Canonical branches:

- Linux shared/integration: `linux-next`
- macOS code: `osx-next`
- Windows code: `windows-next`
- Release: `main` through PR only

All `plan/`, `methodology/`, `openspec/`, and `cheatsheets/` files consider `linux-next` their canonical home. However, agents working on platform branches (`windows-next`, `osx-next`) MUST commit and push all edits (including plan updates) directly to their active platform branch. The Linux coordinator will merge these branches back into `linux-next` during the `/multihost-orchestration` pass.

## Start Of Day / Post-Restart Gate (run FIRST, once per day; methodology `development_environment_lifecycle`)

Every host restarts with the prompt "Use the ./skills/meta-orchestration skill",
so THIS gate is how a restart or a new day gets its maintenance and verification.
It is idempotent and cheap when already done today, and the marker that makes it
so is now REAL and CHECKABLE (order 801-qasc) — run the check, do not eyeball it:

```bash
scripts/check-daily-maintenance.sh check     # exit 0 = today's gate ran; skip the body
```

It prints exactly one line matching
`^(ok:daily-maintenance-(current|stamped):[0-9]{4}-[0-9]{2}-[0-9]{2}|skip:forge-exempt|due:(no-marker|unreadable-marker|stale:[0-9]{4}-[0-9]{2}-[0-9]{2}))$`
and exits 0 only when today's gate is recorded. **`due:*` means run the body**;
a corrupt or missing marker is `due:`, never a pass. From 2026-08-13 to
2026-08-17 the marker this section names existed only as prose — nothing wrote
it, nothing read it — so "did today's gate run" had no answer at all, one cycle
inherited a false "already stamped" premise from its brief and skipped the body,
and the next found nothing to confirm. An unobservable gate is indistinguishable
from one that never runs, and the cheapest way to satisfy it is to skip it.

On a durable bare-metal DEVELOPMENT host (not an ephemeral forge):

1. **Post-restart verification** (only when the stack looks freshly booted — MCP
   experts just rebuilt, images/binary possibly toolchain-bumped): run the durable
   checklist `plan/issues/fleet-restart-post-restart-checklist-2026-08-13.md`
   (order 718-nuvm). Do NOT trust `plan_answer`/`project_answer` until the MCP
   experts serve `source_commit == git rev-parse HEAD`; verify clock/NTP sync
   (a skewed clock breaks SSH-CA cert TTLs + freshness stamps); rebuild forge
   images at the installed VERSION before launching any forge (version-skew DOA);
   reinstall per-checkout git hooks; ensure the router sidecar is staged as a
   build artifact (710-w9kc).
2. **Daily maintenance** (methodology `development_environment_lifecycle.start_of_day_maintenance`):
   build-cache GC per `build_cache_hygiene` (cargo clean when bloated/stale),
   `scripts/nix-toolbox.sh gc` — never a bare `nix store gc`, which would
   delete the whole persistent cache rather than prune it
   (`build_cache_hygiene.nix_store_policy`) — `podman image prune` of
   superseded versioned images,
   the nix-lane guards on hosts with nix (`scripts/test-nix-toolbox.sh`,
   `scripts/check-nix-deps-stability.sh` — daily, not per-commit: each is a
   flake evaluation), the enclave nix binary cache on Linux hosts with a
   running enclave (`scripts/nix-cache-service.sh ensure` then
   `scripts/test-nix-cache-service.sh` — order 801-kqme; serves the persistent
   795-h8er store to the enclave so a disposable forge lands warm without any
   host path being mounted into it), reap defunct delegate handles
   (`delegate-outcome.sh sweep`), verify the
   dev-environment expert containers are up + fresh (`dev_environment_experts` —
   the same ephemeral RAG experts + commit-hook RAG retraining the forge runs),
   and confirm this host is visible in the capability matrix (order 850-bif2):
   ```bash
   scripts/check-capability-row.sh   # ok:capability-row-current:<host> | due:no-capability-row:<host>
                                     # | stale:capability-row-drifted:<host>:row-only=…,probe-only=…
                                     # | stale:capability-row-expired:<host>:age=<n>s
   ```
   Report scratchpad headroom in the same breath (order 915-wkm2) — one line,
   ADVISORY, exits 0 on every path:
   ```bash
   scripts/check-scratchpad-headroom.sh   # ok:/warn:scratchpad-headroom-low:/skip:
   ```
   The agent scratchpad is tmpfs; systemd sizes /tmp at 50% of RAM but a
   usrquota can sit far below that, so `df` reports gigabytes free while every
   write returns EDQUOT — the host stays healthy and only the agent's tooling
   dies. That wedged macuahuitl for several cycles: it presents as "my shell is
   broken", not "I filled a disk". On `warn:` do NOT build in the scratchpad;
   build in the checkout. The threshold is absolute (one cold Rust `target/`,
   2.6-4.4 GB) rather than a percentage, because the fleet's quotas span 4.6x —
   lenovinha warns at 29% used while macuahuitl is fine at 62%, so any
   "warn above N%" rule passes the host that will wedge and warns the one that
   will not.

   On `due:`, publish the row THIS cycle — the matrix was silent for 5 of 7
   hosts because nothing ever asked, and capability routing (847-wgy4) cannot
   route to hardware it cannot see:
   ```bash
   bash scripts/host-capability-probe.sh --fragment \
     > "plan/index.d/$(date -u +%Y%m%dt%H%M%Sz)-capability-row-$(hostname -s | tr 'A-Z' 'a-z').yaml"
   ```
   then commit it with the cycle's plan changes. Never hand-assemble a row
   (the unquoted-heredoc incident on 850-bif2 is why the generator exists).
3. Stamp the marker, NAMING what actually ran — the stamp is refused without
   `--steps`, because a stamp that records "something happened" without
   recording what restores the same unfalsifiability one level up:

   ```bash
   scripts/check-daily-maintenance.sh stamp --host <host> \
     --steps 'delegate-sweep:<result>,podman-prune:<result>,nix-gc:<result>,cargo-gc:<result>'
   ```

   Record `skipped-absent` / `deferred-<reason>` honestly for steps this host
   cannot or did not run; a partial pass that says so is worth more than a
   green that says nothing. `scripts/check-daily-maintenance.sh show` prints the
   last claim. Ephemeral forges skip this whole gate (they discard their
   substrate on teardown) and read `skip:forge-exempt`.

Then favor the expert system for the cycle's work-pull/triage/debug/research
(methodology `expert_first_work`): ask the experts first; on a gap, fall back
with a loud warning naming the gap, never silently.

## How to invoke the gate (read this before your first `./build.sh`)

Two environment variables are not optional and neither is discoverable by
reading `build.sh`. They were carried in operator prompt text for ten cycles
before anyone noticed the skill never mentioned them — which meant the
bootstrap contract ("Use the ./skills/meta-orchestration skill." and nothing
else) was quietly false for any fresh host.

```bash
TILLANDSIAS_SKIP_VERSION_BUMP=1 ./build.sh --check                  # every time
TILLANDSIAS_SKIP_VERSION_BUMP=1 TILLANDSIAS_FORCE_CHECK=1 ./build.sh --check   # to VERIFY
```

- **`TILLANDSIAS_SKIP_VERSION_BUMP=1` — always.** Without it the gate bumps
  VERSION as a side effect and the pre-push hook then refuses YOUR OWN push,
  because VERSION may not change on a platform branch (643-64bx). The blast
  radius is six files — VERSION, Cargo.lock and four crate Cargo.tomls — so a
  remedy that reverts only VERSION leaves the tree dirty and the push still
  refused. Measured live on linux-next 2026-08-20.
- **`TILLANDSIAS_FORCE_CHECK=1` whenever the green matters.** Since 765-tkq2 a
  plain `--check` MEMOISES: on an unchanged tree it prints `ok:gate-fresh` and
  re-runs nothing, in 0.4s instead of 10s. That is correct for the inner loop
  and useless as evidence. A green you did not force proves only that the tree
  has not changed since some earlier green.

## Where standing direction lives

Ask, do not guess:

```bash
tillandsias-plan answer "what is the current Direction?"
tillandsias-plan next <role>
```

The Direction section is operator-owned and is the one place a theme is
declared. Per-row carry-forward lives in each row's `next_action`, which
`next` prints beside the row it belongs to.

**A caveat learned the hard way, 2026-08-22.** Cross-cutting direction parked in
the `next_action` of a CLAIMED row is invisible: claiming removes the row from
selection, so `next` never shows it and a fresh host cannot find it. That is
R1 working as designed, and it means a claimed row is the wrong home for
anything a future host must read. Standing direction belongs in the Direction
section or in this skill; `next_action` is for the row's own next step.

## Joining the fleet (read this if you are not macuahuitl)

As of 2026-08-23 the fleet is FIVE working hosts, not one: macuahuitl
(`linux_mutable`, coordinator), lenovinha and yoga (Silverblue, `linux-next`),
tlatoanis-macbook-air (`osx-next`), and yolanda (Windows 11, `windows-next`).
All five have completed attested cycles. The staged rejoin this section used to
describe is DONE; the three mechanisms it was gating on — claiming, the
first-attestation lane, and capability rows — all landed on 2026-08-22/23.

NOT EVERY HOST IS A DRAIN HOST. Machines with roughly four cores are the
fleet's deliberate LOWER BOUND and take profiling and characterization work in
their own tier, never the general queue (operator mandate 2026-08-16 for
esmeraldinha, extended 2026-08-23 to its Silverblue cousin). A slow host in the
general queue produces slow duplicates of work a faster host already claimed.
The SELECTOR now enforces this (847-wgy4): it probes physical cores locally,
routes a <=4-core host to `low-end`-tagged work only, refuses loudly
(`refused:no-tier-work`) rather than falling back to the general queue, and
subtracts that tier from everyone else's pool — a fast host running the
floor's profiling work would measure the wrong machine. Override with
TILLANDSIAS_HOST_TIER when the probe misreads a host. Separation between
general hosts is ordinal: your rank in the capability-matrix roster picks
your epic (route=rank:<r>/<n> in the batch header), so publishing your row
(850-bif2, above) is what buys you a collision-free lane; a rowless host
falls back to the seeded pick and R1 claiming.

The criteria that gated the original rejoin, kept because they are still what
"working" means:

- **Claiming is live.** `expire-claims` reports a non-zero `in_progress`, and a
  claimed row is genuinely hidden from `next <role>`. Verified on a real claim,
  both halves. What one host CANNOT prove is the cross-host half — a row
  claimed HERE being skipped THERE. That is the second host's first job, and it
  is worth doing deliberately before it drains anything.
- **The selector separates hosts.** `select-work-batch.sh <role> --seed <host>`
  returns disjoint batches for different seeds — different epic, different
  packets, and `urgent=` no longer forces every host to one head. This FAILED
  on 2026-08-19 (three seeds, one byte-identical batch) and the `--seed` flag
  did not exist then. **Pass your hostname as `--seed`.** The default is
  `${TILLANDSIAS_HOST_KIND:-host}-$(date -u +%Y%m%d)`
  (`scripts/select-work-batch.sh:232`), which varies by host KIND and date — not
  by host. Two Linux boxes therefore derive the same seed every day whether or
  not that variable is set, so separation is available but NOT automatic: a
  second host that forgets the flag collides exactly as the fleet did before.

The third is a fleet property no single host can close: the queue must stop
growing faster than it drains. One host currently measures well inside the
bound, but that reading says nothing about what a second host does to it —
which is precisely why hosts rejoin one at a time and the number is re-measured
after each.

**If you are on immutable Linux (Silverblue/Kinoite), two things differ.**
First, `./build.sh` transparently re-execs inside the `tillandsias-builder`
toolbox (`scripts/with-tillandsias-builder.sh`), creating it with
`toolbox create --assumeyes` on first use. So unlike a mutable host, your gate
NEEDS a working podman — a Silverblue box with podman broken cannot run
`--check` at all, where a mutable box happily would. The first `--check` of a
fresh checkout spends its opening minutes building the toolbox — measured on
yoga (Silverblue, Ryzen AI 5 340, ~250 Mbit/s registry link, 2026-08-23; filed
as an event on 850-bif2): image pull 11.5s (355 MiB compressed), `toolbox
create` 0.1s, then 131.9s for the first forced `--check` (dnf 17s, rustup 14s,
gate ~100s), with a warm `~/.cargo` — a truly pristine home also pays crates.io
downloads on top. That is the toolbox being built, not a hang. (The previous
"minutes" figure here was an unmeasured inference written on a mutable host
that never executes this path — b629bb379.)
Second, `scripts/e2e-preflight.sh` carries NO immutability logic and will report
`eligible` to you. Do not believe it: the skill's E2E table routes immutable
Linux to `/smoke-curl-install-and-test-e2e` (test a PUBLISHED release), never to
`/build-install-and-smoke-test-e2e` (test a LOCAL build). The preflight is
answering a narrower question than the one you are asking it.

**If you are on macOS (Darwin), most defaults hold — these are the parts that
do not** (851-gpb5, learned by the first Mac to join). Your branch is
`osx-next`: commit and push everything there, and before EVERY push merge
`origin/linux-next` into it — methodology's pre-push gate
(`pull_merge_cadence.pre_push_gate`; Finalization step 6). Run
`scripts/install-hooks.sh` once so the v5 pre-push hook actually enforces that
merge on your checkout. `./build.sh --check`/`--test` work natively (host
tools: Xcode Command Line Tools for gcc, `brew install pkg-config`, rustup
with the rustfmt and clippy components), but `--install` is REFUSED by design
(723-whrx): the macOS build path is `scripts/build-macos-tray.sh` — wrapped by
`/build-macos-tray`, which also files findings to
`plan/issues/macos-build-findings-<DATE>.md` — and local-build e2e
(`/build-install-and-smoke-test-e2e`) destroys and re-provisions the
Virtualization.framework VM directory, not a podman store. The system shell is
bash 3.2 with BSD userland: no GNU-only flags in anything a Mac must run (no
`xargs -r`, no suffix-less `sed -i`), and `sha256sum` only exists on macOS
13+ — use the `sha256sum`-or-`shasum -a 256` dispatch
(`scripts/build-sidecar.sh`, `scripts/gate-stamp.sh`). Expect the MCP experts
to be DOWN on first boot (`down:forge-plan`, `degraded(not-built)`):
`scripts/cycle-preflight.sh` builds `./target/release/tillandsias-plan`, the
same binary the MCP wrapper serves — work through it by path and record the
outage, per `mcp_first_read_path`. And like every joining host, pass your
hostname as `--seed` to `select-work-batch.sh`.

**Publish your capability row before you drain anything** (order 850-bif2).
`scripts/check-capability-row.sh` answers whether the matrix can see you AND
whether what it sees is still true (order 889-ewvt); on `due:`, `stale:…drifted`
or `stale:…expired` generate and commit a row with
`scripts/host-capability-probe.sh --fragment` (Linux/macOS/forge loci; the
windows-host locus keeps its own generator). `drifted` is the urgent one: the
committed row disagrees with a live probe, and routing that consumes it will
send work to hardware this host does not have — that is how the release gate
was routed to yoga for a `gpu/container/ollama` engine yoga never had. A joining host that drains work
while publishing nothing is how the matrix went silent for 5 of 7 hosts —
and capability-aware routing (847-wgy4) cannot route to hardware the matrix
cannot see.

**Expect to be offered other hosts' abandoned work.** Claims expire on a 24h
lease, and expired rows return to the pool with their history intact — a row
you are offered may have been started elsewhere and dropped. Read the row's
events before assuming it is fresh.

The bootstrap prompt is `Use the ./skills/meta-orchestration skill.` and nothing
else. If you needed something said to you beyond that sentence, the thing you
needed was missing from this skill or the ledger, and THAT is the defect worth
filing — not the prompt.

## Start Of Cycle

0. **Rebuild the instrument before using it** (operator directive 2026-08-13):

   ```bash
   scripts/cycle-preflight.sh   # -> ok:cycle-preflight:<plan>:<inference>
   ```

   The project believes in idempotency and ephemerality — everything should be
   safe to destroy and relaunch at any moment, Erlang style — so a cycle never
   inherits a component from the previous one and hopes it is current. This
   rebuilds `tillandsias-plan` (the binary every expert call, the batch
   selector, every ledger write and every closure check goes through) and
   re-establishes the dev inference endpoint. Both are idempotent; the common
   path costs a no-op `cargo build` and one HTTP round trip, measured at ~2.8s.

   It rebuilds the INSTRUMENT, not the product: `./build.sh --check` already
   compiles what it validates, and rebuilding everything on a schedule is a
   heavier decision than this step is making.

   A `blocked:preflight:*` verdict means do not start the cycle — selecting work
   with an unverified instrument is the one failure the loop cannot reason its
   way out of, because the tool it would reason WITH is the stale thing. That is
   not hypothetical: a selector change on 2026-08-13 added a subcommand every
   host's binary predated, and this checkout went on refusing until someone
   rebuilt by hand. Inference is a REPORT inside that verdict, never a gate —
   the deterministic expert tiers work without it, and a host with no network is
   degraded, not broken. When inference cannot be established, the report
   segment reads `degraded:<reason>` (never `blocked:*` — the gate word is
   reserved for `blocked:preflight:*`); continue the cycle.

1. Record UTC time, host kind, current branch, worktree path, and sibling heads.
   Report this host's scheduler posture in the same breath — it is one line and
   it answers the question an operator otherwise has to read a transcript for:

   ```bash
   scripts/check-cycle-scheduler.sh   # armed? last fire? next due?
   ```

   ADVISORY, NEVER A GATE (order 856-s56y exit criterion 5, wired 865-j3kd).
   `due:not-installed` is a true and acceptable answer: macuahuitl is driven by
   an external hourly loop rather than a systemd timer, and a host with no
   durable timer is differently-scheduled, not broken. What the line buys is
   that "no scheduler is armed here" becomes a stated fact rather than something
   nobody discovers until a host has been quietly not-cycling for a day — which
   is the 856-s56y failure, and the same shape as a wedged host reading as
   silent (864-t4nq).

   It is wired here because the guard shipped invoked by nothing and
   audit-guard-activation therefore failed `./build.sh --ci-full`, one of three
   checks that left the trunk unreleasable for a week (865-n8vq). The auditor
   greps for the guard's NAME, so a mention would have cleared the verdict while
   leaving the guard as dead as it was; an orphaned guard is fixed by invoking
   it. Arming an actual scheduler is 856-s56y's own work and remains yoga's.

2. `git fetch origin --prune`, then run the Credential Channel Guard and the
   Committable Branch Guard below before any committable work. Run the MCP
   Expert Health Probe here too — it is advisory and never blocks, but it must
   run BEFORE the cycle's first expert read, or an outage during that read has
   no recorded baseline to be visible against.
2b. **Acquire the checkout lock — EVERY lane, before the boundary snapshot**
   (order 873-zcim):

   ```bash
   TILLANDSIAS_CYCLE_HOLDER_PID=$PPID scripts/cycle-checkout-lock.sh acquire \
       --lane <how-this-cycle-was-launched> --source "<prompt source, one line>"
   ```

   The no-stacking lock used to be taken only by the driver lane
   (tillandsias-cycle-driver.sh), so a cycle launched by an operator prompt, a
   /loop cron, or a cloud schedule acquired nothing and STACKED on a running
   driver in the same worktree — measured on yoga 2026-08-24, 21 minutes into
   a driver cycle, duplicating its claims. The lock guarded the driver lane;
   the thing two agents contend for is the CHECKOUT.

   On `skip:overlap-lock-held:<holder>` DO NOT PROCEED: the verdict names who
   holds the checkout (lane, pid, start, source). Report it as the cycle's
   final output and exit — this is the designed outcome, not a failure, and
   the refusal is recorded durably OUTSIDE the checkout in
   `~/.cache/tillandsias/overlap-refusals.jsonl`, so a refused-for-overlap
   cycle is distinguishable in the record from a cycle that ran and found
   nothing (873-zcim criterion 3). Do not retry in a loop; the next scheduled
   fire retries on its own clock.

   `TILLANDSIAS_CYCLE_HOLDER_PID=$PPID` must be evaluated in YOUR shell — it
   anchors liveness to the agent-harness process that spans the whole cycle.
   The script's own default is one shell too deep and dies with the tool call.

   DECIDED (873-zcim criterion 4): a second agent NEVER works in a locked
   checkout. The sanctioned path for concurrent work on one host is a separate
   git worktree or a clean temp clone — the technique yoga used to file its
   wedge record and 873-zcim itself while another cycle held its checkout.
   Release at Finalization (step 9b) with
   `TILLANDSIAS_CYCLE_HOLDER_PID=$PPID scripts/cycle-checkout-lock.sh release`.

3. Snapshot the startup boundary before classifying or changing any path:
   ```bash
   boundary_dir="$(mktemp -d "${TMPDIR:-/tmp}/meta-orchestration-boundary.XXXXXX")"
   scripts/meta-orchestration-worktree-guard.sh snapshot "$boundary_dir"
   ```
   The guard records `git status --porcelain=v1 -z --untracked-files=all`
   plus content hashes for every status-visible dirty path. If the worktree is
   dirty, treat every recorded path as immutable sibling/operator work unless
   the operator explicitly identifies it as disposable in the current prompt.
   Refuse the cycle and do not begin committable work. Report the dirty-start
   blocker through the final handoff as defined above. Do not commit, discard,
   restore, reset, or clean unknown startup dirt.

   **Before that refusal, run `scripts/salvage-dirty-worktree.sh <slug>`**
   (order 872-c9nd, full rationale in the Exit Contract above). Refusing
   protects the work from YOU; it does not protect it from a fresh clone, and on
   2026-08-24 a fresh clone is exactly what took it. The salvage cannot touch
   the worktree — temporary index and plumbing only — so it is safe to run on
   dirt you have just been forbidden to alter, and it must run BEFORE the two
   detectors below: whether the dirt turns out to be `ok:opsx-only` or
   `resumable:` changes what you may LAND, never whether a copy should exist.
4. **Generated opsx sync merge (deterministic, order 540)**: before refusing on
   startup dirt, run the deterministic detector:
   ```bash
   scripts/check-opsx-generated-dirt.sh
   ```
   It prints exactly one line matching `^(ok:opsx-only|ok:clean-tree|non-opsx:.*)$`
   and exits `0` only when every status-visible dirty path is exactly the
   22-path opsx/openspec generated set (`.opencode/commands/opsx-*.md` +
   `.opencode/skills/openspec-*/SKILL.md`) — the launch-generated artifact from
   the installed openspec CLI (see
   `plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md`). On
   `ok:opsx-only`, the dirt is INTENDED versioned project content, not operator
   work: commit it as its own sync change on the canonical branch before worker
   drain, then re-anchor the startup boundary:
   ```bash
   git add .opencode/commands/opsx-*.md .opencode/skills/openspec-*/
   git commit -m "chore(opsx): sync generated openspec commands and skills"
   scripts/meta-orchestration-worktree-guard.sh re-snapshot "$boundary_dir"
   ```
   A `non-opsx:` verdict means real sibling/operator dirt — fall through to the
   dirty-start refusal exactly as written; never commit, discard, or clean it.
   An `ok:clean-tree` verdict means there is nothing to merge. The checker is a
   falsifiable machine decision; do not substitute prose judgment for it.
4b. **Resumable claim dirt (deterministic, order 833-fpe7)**: when the dirt is
   NOT the opsx set, run the second detector before refusing:
   ```bash
   scripts/check-resumable-claim-dirt.sh
   ```
   It prints exactly one line matching
   `^(resumable:<order>(,<order>)*|ok:clean-tree|unattributable:.*)$` and exits
   `0` only when EVERY dirty path is tracked, the folded ledger names a live
   claim OWNED BY THIS HOST (`tillandsias-plan expire-claims --list-live`:
   claim-convention event host, both claim and activity inside the TTL), and
   every dirty path's mtime postdates the oldest such claim. That is the
   signature of this host's OWN previous cycle interrupted between implement
   and commit — the dirt the refusal would otherwise deadlock on until
   expire-claims launders finished work into lost work (the 833-fpe7 shape;
   814-iyu7 arriving by a second route).

   `resumable:` is a licence to REVIEW AND LAND, never to auto-commit: read
   the diff against each named order's packet, land what implements it as its
   own commit(s) citing the orders, then re-anchor with the guard's
   `re-snapshot` — the same sequence order 540 sanctions. Whether an edit
   IMPLEMENTS the packet beside it is the agent's judgment; the detector only
   removes the deadlock. Any `unattributable:` verdict falls through to the
   dirty-start refusal exactly as written. Pinned by
   `litmus:resumable-claim-dirt-shape`.
5. Update the active local branch from remote with fast-forward or an explicit
   merge from `origin/linux-next` into the platform branch when appropriate.

5a. **NOW check for sibling overlap** (methodology `sibling_heads_up_protocol`).
   Hosts can message each other directly — `ListAgents` to see who is live,
   `SendMessage` to reach them. **The capability is new and you will not
   discover it on your own**; the fleet coordinated exclusively through the
   ledger and the trunk for months before anyone noticed it existed.

   ```bash
   tillandsias-plan query --status in_progress   # who is holding what, right now
   ```

   **AFTER THE MERGE, NOT BEFORE, AND THIS ORDERING IS THE WHOLE STEP.** This
   check first shipped as step 2a — before the branch update — and was MEASURED
   BROKEN on the next cycle by its own author:

   ```
   before the merge:  831-ezea only            <- the other host's claim INVISIBLE
   after the merge:   642-fedr + 831-ezea      <- yoga's fragments.rs claim
   ```

   `git fetch` at step 2 updates remote-tracking refs; it does NOT update the
   worktree ledger that `tillandsias-plan` reads. So a check placed before the
   merge answers about the claims as of your LAST merge, not as of now.

   **THE STALENESS IS NOT ONE-DIRECTIONAL, and the earlier wording here said it
   was.** This passage used to end "a stale ledger always shows FEWER claims,
   never more." Measured on yoga 2026-08-26T07:26Z, one cycle after that
   sentence landed, running the same query either side of the merge:

   ```
   before the merge:  799-tb7q + 831-ezea    <- 799-tb7q was a PHANTOM
   after  the merge:  831-ezea only          <- another host had released it
   ```

   `799-tb7q` was `in_progress` in the stale ledger and `ready` at the new head:
   a sibling finished a slice and released it in commits this host had fetched
   but not merged. So a pre-merge check can show a claim that no longer exists
   as easily as it can hide one that does — **fewer claims when siblings have
   been claiming, more when they have been releasing.**

   Both directions are harmful and they fail differently. Missing a live claim
   fails toward "no overlap", which is the safe-LOOKING answer and the one that
   costs a union. Seeing a released claim fails toward a needless heads-up, or
   toward skipping a packet that is free — cheaper, but it teaches the reader
   that the step produces noise, which is how a step stops being run.

   `expire-claims --list-live` is the tool again as of 905-wjfj: it now prints
   one row per in_progress packet and a `rows:` accounting line whose total must
   equal the summary's `in_progress=N`. Before that fix it printed the count and
   no rows — two hosts hit it on the same day — and the workaround here was
   `query --status in_progress`, which still works and is a fine cross-check.

   **READ THE ROW TYPE, because the two mean opposite things.**

   - `live-claim <order> <pid> <host> <claimed-at> <last>` — a sibling holds
     this. If it touches your surface, message that host.
   - `unclaimed-in-progress <order> <pid> - - <last>` — in_progress, recent
     enough that no reaper will touch it, and **nobody to send a heads-up to**.
     The dashes are the actionable part. This row is not the quiet case; it is
     the one where the protocol has no addressee, so if it touches your surface
     you inspect the diff yourself rather than assuming silence means free.
   - `attention:list-live-partition-mismatch` — a packet is in no bucket or in
     two. The enumeration is under-reporting; do not trust a `no overlap`
     verdict derived from it.

   MEASURED 2026-08-26: `831-ezea` sat in the unclaimed row for at least a day —
   in_progress, with a gate step wired into `./build.sh --check`, last activity
   18h old and therefore inside the 24h TTL, so neither the reaper nor the
   live-claim list would ever surface it. Exactly the row an overlap check
   exists to show you, and the only one it could not.

   If a live claim touches the SAME SURFACE your batch touches — a wire type, a
   shared struct, a script another lane runs, a schema, a guard wired into
   `--check` — send one HEADS UP before implementing: what you are touching, the
   shape of the change, any sibling call sites you know of, and the ask. They
   reply ACK plus comments. Two short messages.

   **WHY, structurally: THE UNION IS A STATE NO SINGLE BRANCH'S GATE OBSERVES.**
   Every branch can be green alone and the merge still broken, because no
   branch's `--check` compiles the other's configuration. Care cannot close
   that; only a second lane looking can. MEASURED 2026-08-26: macbook's
   731-eupn was green on both branches and `E0063 + E0308` in the union — a red
   gate and ~30 minutes of coordinator cycle.

   **Prefer the message to the resolve-to-be-careful: a heads-up is a
   falsifiable act, care is not.** "I considered the siblings" cannot be checked
   by anyone, including you an hour later.

   DO NOT broadcast routine drain. Most work touches only your own lane, and a
   channel that carries everything is one nobody reads — the recipient is
   mid-cycle, holding a checkout lock, with expensive context. The heads-up is
   for what the ledger cannot carry in time: **intent, before the fact.**

## Credential Channel Guard

Run immediately after `git fetch` and before any worker drain or committable
work.

**Close the interactive escape hatches around EVERY push** (order 860-g798,
exit criterion 3):

```bash
export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
```

A credential problem must fail FAST AND LOUDLY, not hang. Measured on
esmeraldinha: the guard reported green (`gh auth status` held a token), the
cycle entered committable work, and the first push sat >10 minutes behind Git
Credential Manager's interactive prompt — a hang with no output, presenting as
a slow build on the host least able to afford the misdiagnosis. With the
prompts closed the same failure surfaces in seconds as an auth error the guard
now names (`blocked:interactive-credential-helper`, remedy printed). The guard
itself verifies the PUSH path since 860-g798 — `ok:gh-keyring-push-verified`
means a bounded non-interactive dry-run push actually authenticated, not
merely that a token exists somewhere. In SMOKE mode it is a REPORT, not a gate — a smoke run
performs no committable work, so a stale push credential cannot harm it (order
818-cgpn; see Smoke Mode Runbook rule 3a). The Cowork scheduled-task runtime can inherit dangling session sockets
(`DBUS_SESSION_BUS_ADDRESS`, `SSH_AUTH_SOCK` pointing into a non-existent
`/run/user/<uid>`) so anonymous reads succeed while every `git push` silently
fails for lack of a credential. See
`plan/issues/cowork-headless-credential-isolation-2026-06-20.md`.

Run the executable guard instead of re-deriving the check in prose. 
*(On Windows: ensure you run this via Git Bash, e.g. `& "C:\Program Files\Git\bin\bash.exe" scripts/check-credential-channel.sh`. PowerShell's `bash` alias defaults to an isolated WSL session that lacks host credentials).*

```bash
scripts/check-credential-channel.sh
```

It prints exactly one line matching the falsifiable grammar
`^(ok:[a-z0-9-]+|blocked:[a-z0-9-]+|missing:no-credential-channel)$` and exits
`0` when a usable git-push credential channel is present, non-zero when it is
absent or blocked. A usable channel is present when ANY of these holds (the
script checks them in order):

- `<git-dir>/.gh-credentials` exists and is non-empty (repo-local store helper), or
- `GH_TOKEN` or `GITHUB_TOKEN` is set in the environment, or
- `gh auth status` succeeds (reachable, unlocked keyring), or
- `TILLANDSIAS_HOST_KIND=forge` is set AND the enclave git mirror is reachable
  for `origin` AND the mirror's published upstream write-authorization verdict
  (`refs/tillandsias/upstream-auth/<state>/<epoch>`, refreshed non-mutatingly by
  `images/git/probe-upstream-auth.sh`) is fresh and `authorized` (or
  `local-only`). Order 756-2jnj: reachability alone said `ok` on 2026-08-15
  while GitHub 403'd the mirror's credential, and a forge lost two commits it
  discovered only at first push. `ok:forge-git-mirror` now means BOTH halves —
  forge→mirror reachable AND mirror→upstream currently write-authorized.

Pinned by `litmus:credential-channel-check-shape` and
`litmus:forge-upstream-auth-gate`. A non-zero exit (verdict
`missing:no-credential-channel`, or any `blocked:*` verdict — e.g.
`blocked:upstream-push-unauthorized` for the 403 state,
`blocked:upstream-no-credential`, `blocked:upstream-auth-stale`,
`blocked:upstream-auth-unpublished`) fails the cycle on its own; do NOT proceed
into worker drain or any committable work. Instead
fail loud: file or update a blocker in `plan/issues/` recording the exact
verdict, the owner (operator), and the smallest next
action (re-seed `.git/.gh-credentials` via the gh token, inject `GH_TOKEN`
into the task environment, or — for `blocked:*` — repair the mirror's Vault
GitHub token / its repo push permission), then stop. Accreting local-only
commits that cannot be pushed violates the Non-Negotiable Exit Contract and is
the precise velocity-killer this guard prevents.

Reads (`git fetch`/`git ls-remote`) succeeding is NOT evidence of a credential
channel — public-repo reads are anonymous. Verify write capability explicitly.

## Committable Branch Guard

Run alongside the Credential Channel Guard, before any committable work.
Direct commits/pushes to `main` are forbidden — `main` advances only through
PR merges. Breach record: 34e60965, an antigravity forge cycle running ON
`main` that pushed a ~42k-line `plan/index.yaml` reserialization straight to
`origin/main` (reverted via PR #81; see
`plan/issues/main-branch-direct-push-guard-2026-07-24.md`).

Run the executable guard instead of re-deriving the check in prose:

```bash
scripts/check-committable-branch.sh
```

It prints exactly one line matching the falsifiable grammar
`^(ok:branch-[A-Za-z0-9._/-]+|blocked:(committable-cycle-on-main|detached-head|not-a-git-repo))$`
and exits `0` when HEAD is on a committable branch (any named branch except
`main`), non-zero when the checkout is on `main`, detached, or not a git
repository (fail closed). On any `blocked:*` verdict do NOT proceed into
worker drain or any committable work: switch to the host's canonical branch
(`linux-next`, `windows-next`, `osx-next`) or run the cycle read-only.
Read-only/inspection cycles on a `main` checkout remain allowed — the guard
gates committable cycles only. Pinned by
`litmus:committable-branch-guard-shape`.

## Forge Expert Base Guard

Run before launching a forge from this checkout. Run the executable guard
instead of re-deriving the check in prose:

```bash
scripts/check-forge-expert-base.sh
```

It prints exactly one line matching
`^(ok:(expert-base-ready|no-plan-crate)|blocked:(expert-sources-absent|not-a-git-repo))$`
and exits `0` when a forge seeded from this checkout can build a working plan
expert, non-zero when it cannot.

Why this is a separate guard from the branch guard above: the launcher seeds a
forge's branch from **this checkout's current branch**
(`read_host_project_current_branch` → `TILLANDSIAS_FORGE_SEED_BRANCH`), so
whatever branch you are parked on becomes the next forge's base. `main` carries
no `crates/tillandsias-plan/src/answer.rs`, so a forge seeded from it builds a
**pre-expert binary** and then reports `experts: ready` truthfully while every
`plan_answer` / `methodology_path` returns `confidence=unsupported`. Truthful
state, wrong artifact. Breach record: 2026-07-30, an in-forge session found both
experts refusing the milestone's own exemplar question; two earlier cycles had
absorbed the same condition by noticing and hand-rebasing
(`plan/loop_status.md:203`, `:243`). Order 531.

The test is **source presence, not a branch name** — deliberately. The names
`linux-next`/`windows-next`/`osx-next`/`main` are Tillandsias's own conventions
and are explicitly *not* a runtime convention of the product
(`methodology/multi-host-development.yaml:21-27`), so a forge on an end user's
project must not assume them. Source presence is a fact about the checkout, and
it also catches the case a branch-name test cannot: when the seed and the actual
branch agree because this checkout was itself parked on a pre-expert base,
nothing looks wrong.

On `blocked:expert-sources-absent`, do NOT launch a forge expecting expert
answers. Switch this checkout to a branch carrying the expert sources first. On
`ok:no-plan-crate` the target project simply has no plan expert, which is normal
off-Tillandsias.

## MCP Expert Health Probe (advisory — record, never block)

Run at Start-Of-Cycle, alongside the guards above:

```bash
scripts/check-mcp-expert-health.sh
```

It speaks the MCP `initialize` handshake to each expected expert and prints
exactly one line matching
`^(ok:experts-healthy|down:[a-z0-9-]+(,[a-z0-9-]+)*|absent:not-registered|skip:[a-z0-9-]+)$`,
appending one JSONL record per server to `$TILLANDSIAS_EXPERT_HEALTH_LOG`
(default `/tmp/forge-expert-health.jsonl`). ~40ms when healthy.

**This is the concrete referent for `mcp_first_read_path`'s "fall back and keep
going, THEN RECORD IT".** That rule named no destination, and on 2026-08-14 two
hosts skipped the recording half on the same day: windows lost all 28 MCP tools
mid-session and fell back to `tillandsias-plan.exe` silently; linux ran an entire
cycle whose session had never loaded the servers at all. Both outages were
invisible in the ledger and would have stayed invisible (order 737-zcj5).

Unlike the guards above, a non-zero exit here **does not fail the cycle** — an
unavailable expert is a degraded read path, never a blocked one. Record and
continue:

- `down:<csv>` / `absent:not-registered` — keep working through
  `./target/release/tillandsias-plan` (the same binary the MCP wrapper wraps) and
  let the `mcp_outage:` line carry it into the handoff. Name the fallback reason,
  as the rule has always required.
- `ok:experts-healthy` — say nothing further. The probe is silent by design when
  healthy; a signal that fires every cycle is one nobody reads.

### The handshake is not the surface (order 801-m9tk)

`ok:experts-healthy` means the registered servers answered when the PROBE
launched them. It does not mean the tools reached YOUR session. For three
consecutive windows cycles the probe printed `ok:experts-healthy` while not one
`mcp__forge-plan__*` / `mcp__project-info__*` tool was bound to the agent, so
every read silently fell back to `./target/release/tillandsias-plan`. A server
that is up but not exposed is exactly the outage worth catching, and the
handshake probe calls it healthy — the order-531 shape again.

A script cannot see your tool surface; nothing in this repo can. **You** are the
only observer of that fact, so the surface half is **attested, not measured** —
and an unattested cycle reads `unattested:no-surface-claim`, never `ok:`.
Immediately after the health probe, look at your own tool surface and say so:

```bash
scripts/check-mcp-surface.sh attest exposed      # mcp__* tools resolved this session
scripts/check-mcp-surface.sh attest unexposed    # they did not — every read is a fallback
scripts/check-mcp-surface.sh check               # the joined verdict
```

`check` joins the measured handshake with the attested surface and prints
`ok:surface-exposed` / `unexposed:handshake-ok` / `down:<csv>` /
`absent:not-registered` / `unattested:*` / `skip:no-health-log`. Advisory, never
a gate — like the probe it extends. `cycle-metrics.sh` folds a fresh `unexposed`
attestation into `mcp: health=ok-unexposed` and fires the `mcp_outage:` line, so
the degraded read path reaches the ledger without anyone choosing to write it
down. An `exposed` attestation leaves `health=ok` unchanged, and a claim older
than the freshness window labels nothing: a previous cycle's marker never
vouches for this one.

**And the third question: is the server you reach running current code?**
(order 823-u3k9). The handshake probe launches its OWN instance from the
registration, so it validates the FILE. It cannot see that your session's
long-lived MCP process was started before a fix landed and is still serving the
old text — measured on macuahuitl 2026-08-18, where 799-j4xd's fix was in the
file, the index was fine, L0 was fine, and the expert answered with prose the
fix had deleted while every signal read green. A fix in a file does not reach a
process that already read it.

Like the surface, only **you** can observe this, and for the same reason: a
subprocess cannot reach your server, and launching one is the defect. Call the
live tool, read the build line out of its answer, attest it:

```bash
# 1. mcp__forge-plan__expert_capability   (through YOUR tool surface, not a shell)
# 2. read its `server_build: forge-plan=<id> source=<path>` line
scripts/check-mcp-live-build.sh attest forge-plan=<id> --source <path>
scripts/check-mcp-live-build.sh check            # the joined verdict
```

If the answer carries **no** `server_build:` line, that is the finding, not a
reason to skip: the running server predates the emitter. Attest
`forge-plan=unreported` and it reads `stale:live-server-build-unreported:…`.
`check` prints `ok:live-build-current:<server>` /
`stale:live-server-build:<server>:<attested>!=<ondisk>` /
`stale:live-server-build-unreported:<server>` / `unattested:*` /
`unavailable:*`. Advisory, never a gate. On any `stale:`, relaunch the forge (or
the session's MCP servers) before trusting an expert answer — and record the
fallback, per `mcp_first_read_path`.

Do NOT substitute `test -x` or a registration-file check for the handshake. A
server that exists but wedges on startup is precisely the outage worth catching,
and a file-existence test calls it healthy. (The first draft of the probe read
`.command` while dropping `.args`, launched a bare `bash`, and reported both
healthy experts as `down` — a false outage is as bad as a missed one.)

## Local Expert System Probe (advisory — at cycle start, before work drain)

Run at Start-Of-Cycle, AFTER the MCP Expert Health Probe and BEFORE worker
drain — and ONLY on hosts with `TILLANDSIAS_HOST_EXPERTS` set, the same gate
the commit hooks use for host-expert work. On every other host skip this
section entirely rather than paying a connection timeout probing an ollama
that was never provisioned:

```bash
[ -n "${TILLANDSIAS_HOST_EXPERTS:-}" ] && scripts/check-local-expert-health.sh
```

It pings the local Ollama inference endpoint and prints exactly one line matching
`^(ok:local-experts-healthy|degraded:local-experts[^;]*|down:local-experts[^;]*|skip:not-applicable)$`.

On `ok:local-experts-healthy` you MAY ask the local pipeline for a triage hint:

```bash
TILLANDSIAS_EXPERT_DOMAIN=methodology \
  ./target/release/tillandsias-plan pipeline "what is pending and neglected in the plan?" \
    --domain methodology 2>/dev/null | jq -r '.responses[0].answer // empty'
```

The pipeline emits `{tier, domain, rag_freshness, rag_source_commit,
responses}`, and each `responses[].answer` is RAW local-model text: no
retrieval, no validation, no grounding (that wiring is packet
wire-local-experts-mode-through-grounded-pipeline). Treat the output as an
ungrounded hunch, never a directive — anything it claims about specific
packets must be re-checked against `tillandsias-plan next <role>` and the
plan ledger before acting.

With the gate unset, or on `down:*` / `degraded:*`, skip the query and
continue the cycle. The local expert system is a convenience, not a gate —
the deterministic expert tiers and MCP experts work without it.

## Reduction Engine

The loop is a reduction engine, not just a worker. Its job is the project's core
principle — **Monotonic Reduction of Uncertainty Under Verifiable Constraints**
(`methodology/philosophy.yaml`). Every cycle must move the system toward a
verifiable implementation of the spec by *reducing* open uncertainty, and must
never let an observed problem evaporate.

### Capture: nothing gets lost

Any time a worker notices "welp, this isn't great" — an inefficiency, a rough
edge, a fragile assumption, an advisory-only guard, a repeated manual step, a
log warning, a deprecation notice — it MUST be filed before the cycle exits.

**CAPTURE IS MANDATORY. A NEW ROW IS NOT.** These are different acts and
conflating them is what grew the ready queue to 410 rows against a service rate
of ~19/day. Route every capture:

- **A new ROW** only if INDEPENDENTLY SCHEDULABLE — it names owned files no open
  row already owns, OR a different `pickup_role` can claim it than every open
  row covering that scope.
- **Otherwise an EVENT on the row it belongs to**, or a `next_action` clause on
  that row. The finding is recorded in full either way; only its *selectability*
  differs.

**When a row's events show a confirmed pattern — several independent
observations, ideally from different hosts or cycles, converging on one defect
or one missing capability — that row has OVERFLOWED and is a promotion
candidate. NOTE it; do NOT promote it. Promotion is Tlatoāni-gated** (operator
ruling, 2026-08-19): what counts as a confirmed pattern is not yet expressible
as a threshold, and an agent promoting on its own judgment restores unbounded
arrival by a longer path.

Why this is safe, and why it is not a throughput cut: with arrivals
λ = a + b·μ, the queue moves at `dL/dt = a + (b−1)·μ`. Above b = 1 every extra
host and every shortened cycle fills the queue FASTER; below b = 1 the same
velocity drains it. Measured b is 1.80. So curation at the acceptance boundary
is the *precondition* for velocity paying off at all — see
`methodology/distributed-work.yaml` → `why_velocity_is_the_other_lever`.

### Standing FRESHNESS audit class (order 372, methodology `component_freshness`)
Each cycle, after worker drain, treat the top component the `freshness-advisory`
CI phase flagged as a claimable audit source. Re-validate ONE component against
the audit question — *last properly looked at and confirmed still meaningful,
useful, efficient, sound, and complete?* — and end in exactly one disposition:
**refreshed** (re-validated, update its `# freshness:` stamp), **updated**
(fixed/tuned, update stamp), or **obsoleted** (delete/tombstone with same-commit
removal of dependents). Apply the **discard-over-repair bias**: discard a stale
component rather than repair it when a fresh implementation would be better.
`scripts/freshness-inventory.sh` emits the coverage report + top stale
components each `./build.sh --ci` run; the report grammar is pinned by
`litmus:freshness-inventory-shape`. A freshness audit is a valid reduction step
on its own and counts toward burndown.
This is mandatory, not optional (`methodology.yaml` →
`cooperative_work_discipline`; Non-Negotiable Exit Contract → "Explicitly log
things that make you slower"). File it as a dated issue in `plan/issues/`,
classified as one of: `research/`, `exploration/`, `enhancement/`, or
`optimization/`. An unfiled finding is a lost finding and a contract violation.

### Ledger compaction (check each cycle; act only when eligible)

```bash
tillandsias-plan fragments     # -> compaction: eligible=<bool> fragments=N bytes=N malformed=N reason=<name>
tillandsias-plan compact       # only when eligible=true
```

`plan/index.yaml` is a compacted BASE; `plan/index.d/*.yaml` are append-only
fragments that concurrent hosts write freely. Reads fold them transparently, so
**an uncompacted ledger is slower, never wrong** — compaction is garbage
collection, not a correctness step. Never let it block filing work.

Two rules, both easy to get wrong:

- **Compaction deletes only the fragments it folded, by name.** Never
  `rm plan/index.d/*`. A fragment another host wrote while you were compacting
  has not been folded, and removing it silently destroys their work.
- **Compaction is TEXT-LEVEL and never re-serializes the base.** It ran on the
  real ledger for the first time on 2026-08-03 (order 582-4wdi, commit 81e12b65):
  28 fragments folded, 120 comment lines preserved exactly, 535 packets
  preserved, and the `plan/index.yaml` diff was 1021 added lines and zero removed
  lines. **Do not read that zero as the invariant** — it was a true measurement of
  a fold that could only APPEND, taken before `set-field` fragments existed, and
  it has been unreachable since. A fragment that reassigns a field must remove the
  superseded line; a fold carrying nine status transitions removes nine `status:`
  lines and that is the fold working.

  THE PROPERTY TO PROTECT, stated so a healthy compaction cannot fail it: no line
  is removed EXCEPT one whose field a fragment explicitly reassigned. Comment
  lines, packet count (minus none, plus the new ones), and the four-space item
  prefix `append-event` locates by all survive unchanged. Check THOSE, in one
  command, rather than eyeballing the removal count:

  ```bash
  git diff --numstat plan/index.yaml                  # removals are expected
  git diff plan/index.yaml | grep '^-' | grep -v '^---' | head -40   # READ them
  ```

  **Read the removed LINES, not a histogram of their keys.** This recipe used to
  end with `cut -d: -f1 | sort | uniq -c` and the question "ONLY field keys?".
  That works only while every reassigned field has a SCALAR value. A fragment
  that replaces a STRUCTURED value removes all of its lines, including list
  items that are not field keys at all — measured on yoga 2026-08-25, a fold
  whose 14 removals included `- container`, `- cpu`, `- gpu`, `engines`,
  `lanes` and `supported_device_classes`, because a stale capability row's
  `engines: [{name: ollama, ...}]` block was superseded by `engines: []`. The
  fold was correct; the histogram made it look like structure loss, which is
  the same stop-and-investigate 865-ng6r removed for the scalar case. The
  question is not "are these field keys" but "does each removed line belong to
  a field some fragment reassigned" — and the cheapest way to answer it is to
  look at the lines.

  MEASURED TWICE, on two hosts, each of which stopped its cycle to investigate:
  lenovinha 2026-08-23 (+888/-17 — five `status`, one multi-line `next_action`)
  and yoga 2026-08-25 (+556/-12 — nine `status`, two `next_action`, one
  `next_action_ts`; 37 comments and all 526 packet prefixes intact). Both folds
  were correct. The prose is what cost the time, which is why it is corrected
  here rather than merely noted (865-ng6r).

  It refused for months before that, correctly: a `serde_yaml` round-trip drops
  comments and re-indents items to column 0, after which `append-event` silently
  stops finding packets. If compaction ever regresses to round-tripping YAML,
  restore the refusal rather than accepting a lossy fold. The candidate base must
  still PARSE and pass the integrity gate before it may replace the base.

If `malformed=N` is non-zero, a fragment did not parse and was SKIPPED — its
contents are absent from every answer. Treat that as a finding, not noise.

### De-slop sweep clock (consult each cycle; act only when due)

```bash
scripts/check-deslop-due.sh check    # exit 0 = NOT due; exit 1 = due; exit 2 = cannot compute
```

**Read the exit polarity before wiring anything to it.** The file is named
`check-deslop-due.sh` and exits **0 when the sweep is NOT due** — same
convention as `check-daily-maintenance.sh`, where the actionable state is the
non-zero one and the healthy steady state stays at 0 for callers under `set -e`.
The idiom is `if ! scripts/check-deslop-due.sh; then run_the_sweep; fi`, or
branch on the verdict token (`deslop-due` / `deslop-not-due`), which cannot be
inverted by a copy-paste.

It prints exactly one line carrying the numbers it decided on, e.g.
`ok:deslop-not-due:order=844 last=834 delta=10 hours=44 reason=under-threshold`.
The rule is **event-counted only**: due when
`(current_order - order_at_last_sweep) >= 200`, with a 48h floor so a filing
burst cannot fire two sweeps in a day, and **no calendar ceiling** — a ceiling
would fire low-yield sweeps over a quiet fortnight and
`red:two-sweeps-zero-confirmed` would then retire the reconciler for doing
nothing wrong. Time-decaying properties already have their own TTLs
(`expire-claims` 24h, `component_freshness`). This is **not** a build gate and
nothing in `./build.sh` runs it; it is a scheduler input for this section.

After running a sweep, record it — the marker is committed, not host-local, so
the whole fleet shares one clock:

```bash
scripts/check-deslop-due.sh record --examined <rows-looked-at> --confirmed <n> \
  [--retracted <n>] [--filed <n>] [--net-lines <±n>]
```

`--examined` and `--confirmed` are mandatory. The sweep's kill rule counts only
sweeps that **examined new rows**, and this is why: the first real sweep
retracted 51 of 410 rows (12.4%) against a modelled ~50%, and that pass drained
accumulated stock. Steady-state yield will be far lower, so **two consecutive
near-zero sweeps is a normal outcome for a healthy queue**, not evidence the
reconciler is broken. A sweep that confirms the queue is clean has done its job.

### Filing a packet: mint its order, never pick one

```bash
tillandsias-plan next-order          # -> 581-k3f9
```

**Write the packet to a FRAGMENT, not to `plan/index.yaml`.** Create
`plan/index.d/<utc>-<suffix>-<host>.yaml` with a top-level `packets:` list. Only
you can have produced that filename, so git never conflicts and no host waits on
another. Reads fold it in automatically — the packet is queryable immediately.
Fragments are IMMUTABLE: to change something, write a new fragment, never edit an
existing one (that is what makes the fold order-independent).

**Never compute "the next free order" yourself.** That number comes from a
ledger snapshot which is stale the moment another host commits, so two hosts
filing in the same window pick the SAME number deterministically. It happened
twice on 2026-07-31 (560–562, then 568–570), and six collisions sit at HEAD.

The minted token is **permanent**. Do not renumber it later, and do not ask a
coordinator to "normalize" it — order tokens leak into code comments, `@trace
order:` headers, and commit messages, and a pushed commit message can never be
corrected. Two hosts landing on prefix `575` produce `575-k3f9` and `575-m2p1`:
both correct, both permanent, nothing to reconcile. A shared prefix is normal.

Cite `packet_id` in anything durable — depends_on, specs, methodology, commit
messages. It is the identity and is unique by construction; the order token is a
human convenience. Canonical: `methodology/distributed-work.yaml` →
`order_id_allocation`.

### Reduce: smaller, simpler, verifiable packets

Filing is only the intake half. Each recurring cycle then *reduces* open
findings:

1. Pick the highest-value open finding that fits this host's capability.
2. Split it into the smallest packet that closes a slice of it under a
   **verifiable constraint** — a litmus test, an executable check returning a
   pass/fail exit code, or a parser/validator — never prose intent alone. A
   guard only an attentive agent honors is a suggestion, not a constraint;
   reduce it to something that fails loud on its own.
3. Promote that packet into `plan/index.yaml` as a `ready` node with a named
   verifiable closure, then drain it when a capable host can produce evidence.
4. When the verifiable check passes, the slice is retired; re-derive the
   remaining residual and repeat.

Reduction is monotonic: each step must lower residual uncertainty or preserve it
while increasing verification level (`convergence.yaml` → `drift_control`). A
"reduction" that adds ambiguity or removes a validated invariant is drift and
must be rejected. Shaping a finding into a well-formed `ready` packet *is* a
valid reduction step when the current host cannot yet implement it.

### Raising the bar is Tlatoāni-gated (do not self-escalate)

The scan bar is a fixed, declared depth. Reducing all open findings to zero **at
the current bar is a legitimate, clear convergence point** — a fixed point of
the refinement operator — not premature convergence. The loop MUST NOT raise the
bar on its own. Autonomous bar-raising would make the convergence point
undefined (the loop could never report "done"), which is exactly the failure
this rule prevents. See `methodology/convergence.yaml` → `bar_raise_governance`.

What the loop does as it approaches zero residual at the current bar:

1. Keep reducing open findings at the current bar until none remain.
2. Then *propose* bar-raise candidates — file them as `research/` or
   `exploration/` issues describing the deeper scan that could be enabled (e.g.
   treat build/test/runtime warnings, non-fatal errors, deprecation notices,
   flaky-test signals, slow steps, or stale caches as findings). A proposal is a
   candidate, not an enabled scan.
3. STOP there. Enabling any bar-raise — actually treating a deeper signal class
   as findings — is an explicit, one-off decision that **The Tlatoāni must
   approve every time.** Record the approval (who/when/scope) before the deeper
   scan becomes part of the loop's contract.

Rationale: much of the system is "build what works, then improve from there," so
each bar-raise is a deliberate scope expansion the operator owns, not an
emergent behavior. Automatable approval of *some* low-risk bar-raises may come
later; until The Tlatoāni declares such a policy, every bar-raise is manual.
Reaching zero at the current bar and filing bar-raise candidates is a complete,
successful cycle — not an excuse to escalate unprompted.

See `plan/issues/meta-orch-enhancement-opportunities-2026-06-20.md` for a worked
example of capture → reduce → promote.

## When the Gate Fails, Read check-logs.jsonl FIRST

`target/convergence/check-logs.jsonl` holds a per-run verdict for every check,
going back weeks. It is the authoritative record of what failed and when.

Do NOT diagnose from terminal scrollback. The next run overwrites the per-check
logs under `target/convergence/check-logs/`, and re-running to "get a better
look" is what destroys the evidence — the re-run may pass, and then the failure
is gone.

```bash
jq -r 'select(.status != "pass") | "\(.ci_run_id)\t\(.check_id)\t\(.status)"' \
  target/convergence/check-logs.jsonl | tail -20
```

`scripts/local-ci.sh` also prints a `Failed checks:` block naming each failure.
If you pipe the gate through `tail -N` or a grep filter, you will cut that block
off and lose the names — this host did exactly that twice on 2026-08-09, spent
two cycles calling an intermittent failure "unexplained", and filed a packet on
the false premise that the names were unrecoverable (637-df4z, closed
mis-diagnosed). The answer had been on disk the whole time: `rust-tests` and
`tray-contract`, two parallel tests racing on `$HOME` and a shared fixture
directory (638-ehzi).

An intermittent failure is a defect with a schedule, not noise. Treating it as
noise is how it survives.

## Reads Go Through MCP First

Before draining anything: **do not read whole ledgers.** `plan/index.yaml` is
31,678 lines and `plan/loop_status.md` is 7,875; pulling either in full to learn
one fact is the largest single consumer of orchestrator context in this loop, and
it is paid again by every agent on every host every cycle.

Ask `forge-plan` / `project-plan` (`plan_answer`, `plan_next`, `plan_query`,
`plan_status`, `plan_blocked_by`, `methodology_ask`, `spec_answer`) and
`project-info` (`search_code`, `grep_code`, `find_files`, `read_file`). Answers
are cited — keep the citations.

Drop to the filesystem for exactly three reasons, and name the one that applies:
**unavailable** (MCP down or `confidence=unsupported` — fall back and keep going,
then record it so a systematically-refusing expert stays visible);
**verification** (before any irreversible act, read the CITED SPAN, not the
file); **not exposed** (no tool covers it — and if the loop needs it repeatedly,
that is a missing tool, so file a packet).

Canonical: `methodology/distributed-work.yaml` → `mcp_first_read_path`.

## Worker Drain

#### Writing a validation packet: demand the post-condition AFTER the last MUTATING step

Any packet that asks a host to install, launch, switch channels, or otherwise
mutate its runtime must require the health check at the **end of everything the
host actually does** — not after the last step that felt like the test.

Earned 2026-08-10. A sibling's smoke reported 4/4 PASS on a `HEALTHY --diagnose`
taken at 04:32:20, then ran one more mutating step (a downgrade-to-stable /
restore-to-unstable round trip), which wedged the control wire at 04:33:27 and
left the host in a failed provisioning state for ~25 minutes until the operator
found it. Every per-step result was true; the verdict was still incomplete about
the host's end state, and a stable promotion was made on it.

Their own words are the rule worth copying: *"a post-condition check belongs
after the last MUTATING step, not after the last interesting one."*

So a validation packet this loop writes should say, explicitly:

> Final step, after everything above: re-run the health check. If any step after
> your last health check mutated the host, that check is stale and the run is
> not finished.

## Stranded-claim sweep (coordinator, every cycle)

```bash
scripts/check-stranded-in-progress.sh
scripts/archive-plan-packets.sh
```

A packet in `in_progress` is invisible in BOTH directions: `ready` queries skip
it so nobody claims it, and burndown does not count it so nobody notices it is
unfinished. 21 packets were in that state on 2026-08-09 — ~9% of the live
ledger, oldest at order 153 — every one with no progress event ever recorded
(641-e2qa).

Report the `summary:` line in the handoff. If the count is rising cycle over
cycle, claims are outliving their cycles and that is the thing to fix, not the
individual packets.

Advisory, never a gate: a packet legitimately in flight right now is
indistinguishable from one abandoned an hour ago. **Do not bulk-close what it
reports.** Closing a packet requires checking its exit criteria against the
tree; guessing marks unfinished work done, which is strictly worse than leaving
it stranded.

### Cycle batch triage — decide the batch BEFORE draining

```bash
scripts/select-work-batch.sh <linux|macos|windows|any>
```

Run this once, at the top of the drain, and take the batch it prints. It selects
ONE epic (`release_target`) and at most `budget` packets from it, so a cycle
drains a coherent slice instead of five unrelated subsystems — the scatter that
made small packets cost more in orientation than in work.

**THE BATCH IS A STORY, AND THE STORY IS THE UNIT OF WORK — not the packet.**
Take the whole batch, implement it as one coherent change, and pay the cycle's
fixed costs ONCE: one build/verify pass, one loop-status entry, one attestation.
Do not run `./build.sh --check` per packet, and do not attest per packet.

Why this is the rule and not a preference — measured on the fleet 2026-08-16..19:

| commits, 3 days | count |
| --------------- | ----- |
| `record(mo-full)` (attestation only) | 155 |
| `chore(plan)` (ledger bookkeeping)   |  88 |
| every category of actual product work | single digits each |

Over 5 days that is 127 product-code commits against 457 plan-only, 149
attestation-only and 219 merge commits. **Every cycle pays the same exit cost
whether it carried one packet or eight** — loop-status, attestation record,
attestation self-check at the new HEAD, and the merges each of those provokes.
A one-packet cycle spends most of itself on the exit contract. Bundling does not
make the overhead smaller; it amortizes it across more delivered work, which is
the only lever available without weakening the contract itself.

Budgets, which the selector already implements — do not restate a different
number here, and if this text and `scripts/select-work-batch.sh` ever disagree,
the SCRIPT is right and this paragraph is stale:

- non-forge hosts: adaptive **6 → 10** (order 682-yiz7, evidence-backed tuning)
- autonomous / pairing forge cycles: adaptive **4**, or `TILLANDSIAS_CYCLE_BUDGET`
- unattended litmus runs: 1 (order 707-3x9d)

This paragraph used to end "Budget is 1 on forge (order 264) and 3 elsewhere"
while its own opening sentence said 4 and 6, and the script said 6 → 10. Three
numbers for one budget, in one paragraph plus its tool. Agents read the smallest
one, which is how a fleet tuned to 10 spent its nights draining one packet at a
time.

It is minimax-ranked (largest residual first, per `convergence.yaml` →
`minimax_convergence_strategy`), with score-weighted entropy over the top-3.
The seed is printed; record it in the loop-status entry so the cycle can be
replayed. Budgets are stated ONCE, above — never restate them here.

**THE SEED DOES NOT SEPARATE CONCURRENT HOSTS. Do not rely on it to.** This
paragraph used to end "...so coverage spreads over time and two concurrent hosts
do not collide on one epic". The second half is false and was never measured.
Measured 2026-08-19 on macuahuitl against the live ledger: three distinct seeds
(`macuahuitl-`, `yoga-`, `esmeraldinha-20260819`) produced a byte-identical
batch — same `epic=socket-audit-master`, same `pick=2/3`, same score, same head
packet. Two independent reasons, and neither is fixable by reseeding:

- The default seed is `${TILLANDSIAS_HOST_KIND:-host}-<date>`
  (select-work-batch.sh:232). `TILLANDSIAS_HOST_KIND` is set only inside the
  forge, so every bare-metal host falls back to the literal `host` and they all
  seed identically. Even when set it is host KIND, so three Linux boxes collide
  with each other regardless.
- The `urgent=<packet>` override puts one globally-urgent packet at the head of
  the batch. Urgency is a property of the PACKET, so it is host-independent by
  construction and preempts the epic pick on every host at once.

**SEPARATION COMES FROM CLAIMING, which is the mechanism that already exists and
is sitting at zero.** `next`/`select-work-batch` filter to `unleased`, and
"leased" means `status: in_progress`. `expire-claims` (order 672-bz7u) reaps
claims older than 24h so a dead host cannot strand work permanently. As of
2026-08-19 `expire-claims` reports `in_progress=0` — nothing has been claimed at
all, so every host is offered every packet, and on 2026-08-18 two hosts
implemented 798-tk7b six minutes apart (order 814-iyu7, ~4h duplicated).

So, before you implement anything from the batch:

```bash
tillandsias-plan set-field <order> status in_progress \
    --host "$(hostname -s)" --reason "claimed for cycle <UTC ts>"
git add plan/index.d && git commit -m "claim(<order>): <host>" && git push
```

Push the claim BEFORE the work, not with it — an unpushed claim separates
nobody. Then:

- **Losing the race is normal and cheap.** The ledger is a CRDT; two hosts can
  claim in the same window. On your next fetch, if another host's claim event
  for that order carries an EARLIER timestamp (ties broken by lexicographically
  smaller hostname), you lost: release yours back to `ready` and take the next
  batch item. Do not both continue — that is exactly 814-iyu7.
- **Release on exit, always.** Completed work moves to its terminal status.
  Work you did NOT finish goes back to `ready` in the same cycle you abandon it.
  Leaving it `in_progress` hides it from `ready` AND from burndown until the 24h
  reaper runs — 21 packets were stranded that way on 2026-08-09 (641-e2qa).
  Claiming is only safe because releasing is unconditional.

The `triage:` line reports `ungrouped=N` — eligible packets with no
`release_target`. That number is the health of the epic tier itself: when it is
large, selection is degrading toward flat priority order regardless of what this
script does. Surface it in the handoff.

Canonical: `methodology/distributed-work.yaml` → `cycle_batch_triage`.

When choosing the builder role, run `/advance-work-from-plan` repeatedly in a `./plan` friendly way in fresh cycles until one of these is true:

- no eligible ready work remains for this host;
- every eligible item is blocked;
- a terminal failure was filed;
- the current cycle has already produced a coherent commit and the next packet
  would exceed the recurring-loop budget.

Forge-hosted cycles (`TILLANDSIAS_HOST_KIND=forge`) are the OPPOSITE of
greedy — decided by The Tlatoāni 2026-07-10 (order 264), replacing the earlier
"drain as many as possible" exception:

- Drain **as much of the batch as fits the envelope, as ONE story** — bounded by
  TIME, not by a count. Superseded 2026-08-19 by The Tlatoāni, who set order 264
  in the first place: *"that's also why I was asking for bundles of related
  packets in stories and epics, rather than the 'take a single packet' baked
  into the ./methodology that I've been fighting you to lift."*

  Order 264's REASONING survives intact and is the reason this is a time bound
  rather than a licence: a litmus-launched forge cycle lives inside
  `litmus:opencode-prompt-e2e-shape` STEP 3's 600s budget, and a cycle that
  overruns it dies mid-work with nothing pushed. What does NOT survive is the
  count. "One packet" was a proxy for "fits in 600s", and it is a bad proxy in
  both directions: three one-line ledger closures fit easily, and one large
  packet does not fit at all.

  So the forge asks the envelope question about the STORY, not the packet, and
  the selector's adaptive budget (4, or `TILLANDSIAS_CYCLE_BUDGET`) is the
  starting size.
- Before implementing, estimate whether implement+verify+commit+push for the
  whole story fits the launch envelope.
- If it does not fit, do NOT start implementing: **split** the packet into
  smaller ready child packets (`split_into` pattern), record the shaping
  events, commit and push. The shaping commit IS that cycle's completed work —
  a split that lowers residual ambiguity is a valid reduction step.
- Canonical statement: `methodology/distributed-work.yaml`
  `worker_agent_protocol.forge_cycle_budget`. Interim reliance on step
  timeouts is tracked by order 265 (forge heartbeat/liveness signals).

Each worker cycle must obey the non-negotiable exit contract above.

### Node-Closure Claim (avoid duplicated ledger-hygiene work)

Before re-deriving and closing or hygiene-editing a `plan/index.yaml` node,
claim it so a concurrent cycle does not independently produce the identical edit
(the idempotent-but-wasteful collision recorded in
`plan/issues/agent-concurrency-collisions-2026-06-20.md`). Run the executable
claim instead of eyeballing the ledger:

```bash
scripts/claim-ledger-node.sh claim <node-id>   # e.g. release-nix-cache-ref-scoping/choose-approach
```

It emits exactly one line matching
`^(claimed|reclaimed|in-flight|released|free):[a-z0-9._/-]+$` and exits `0` when
this cycle owns the node (`claimed:`/`reclaimed:`) or non-zero (`in-flight:`)
when a live lease is held elsewhere — in which case skip that node and pick the
next eligible one. The lease is an advisory, CRDT-friendly reservation, not a
mutex on the file: it respects the stable-ID + idempotent-merge preconditions in
`methodology/between-commits-work-discipline.yaml`, so a missed or expired lease
never corrupts state (at worst two cycles converge on the same safe edit).
Release with `scripts/claim-ledger-node.sh release <node-id>` after the closure
is committed; expired leases (default TTL 4h) are auto-reclaimed. Pinned by
`litmus:ledger-node-claim-shape`.

### Release-Targeted and Milestone Packets

Worker selection prefers packets carrying `release_target:
<milestone-packet-id>` before the general backlog; a host with no eligible
targeted work falls back normally (never idle). `kind: milestone` packets
are criteria holders — never claim one for implementation; claim children
and record burndown as progress events on the milestone. Large ambitious
goals follow `methodology/distributed-work.yaml` →
`ambitious_milestone_reduction` (fat-agent research → operator-signed
decision record → smallest demonstrable rungs → verification): the
coordinator mirrors the milestone's burndown in `plan/loop_status.md` each
cycle.

### Long-Running (multi_cycle) Packets

Packets marked `multi_cycle: true` in `plan/index.yaml` follow
`methodology/distributed-work.yaml` → `long_running_packets` (plan order 251):

- Claims are **cycle-scoped**; the packet returns to `ready` after each
  cycle's commit. A `ready` multi_cycle packet with prior progress events is
  normal, not stalled.
- Do NOT mark one `done` — even with all exit criteria implemented — until
  its `verification_required.completion_gate` is satisfied by `verified-by`
  events from every named agent. Implementation-complete means
  `phase: verification`, not `completed`.
- Treat a packet sitting at `phase: verification` as a dispatch item for the
  named verifier agents and surface it during coordination.
- The active set is mirrored in `plan/long-running.md`; keep that view in
  sync in the same commit as any phase/status/verification change.

## E2E Gates

Run eligible e2e gates after worker drain:

| Host kind | Local-build e2e | Curl-install e2e |
|---|---:|---:|
| linux_immutable | no | yes |
| linux_mutable | yes | yes |
| macos | yes | yes |
| windows | yes | yes |

Before running any local-build e2e gate, consult the structured host-eligibility
verdict instead of re-deriving the skip reason in prose: run
`scripts/e2e-preflight.sh eligibility`, which prints exactly one line matching
`^(eligible|skip:[a-z0-9-]+)$`. Proceed with the local-build gate only on
`eligible`; on any `skip:<reason>` (e.g. `skip:no-podman-user-session` in the
Cowork sandbox, which has no `/run/user/<uid>`, or `skip:smoke-lock-held` when a
parent/local sibling smoke already owns the host lock) record the verdict once
and skip the local-build gate without re-litigating it. Pinned by
`litmus:e2e-eligibility-probe-shape`.

Rules:

- Local-build e2e uses `/build-install-and-smoke-test-e2e`.
- On macOS the local build that gate exercises is
  `scripts/build-macos-tray.sh` (the `/build-macos-tray` skill wraps it and
  files findings to `plan/issues/macos-build-findings-<DATE>.md`);
  `./build.sh --install` is refused on Darwin by design (723-whrx), so there
  is no build.sh install path to look for.
- Published-release e2e uses `/smoke-curl-install-and-test-e2e`.
- Destructive substrate reset is expected setup on Tillandsias smoke hosts.
  `podman system reset --force` is a precondition for Linux idempotence tests,
  not a blocker. Do not pause, ask for confirmation, or skip the e2e gate for
  fear of wiping Podman when `TILLANDSIAS_DESTRUCTIVE_RESET_OK` is unset or `1`.
  Only treat reset as blocked when the environment explicitly sets
  `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`.
- If the plan records a latest tested release older than the current GitHub
  release, prioritize curl-install e2e.
- File every finding as a plan packet; write a PASS report for clean runs.

## Mutable Linux Coordinator Duties

Only `linux_mutable` performs global coordination:

1. Run `/multihost-orchestration` after worker drain or when sibling branches
   advanced.
2. Merge eligible `origin/windows-next` and `origin/osx-next` work into
   `linux-next`, with explicit conflict mediation if needed.
3. Run more frequent local-build e2e gates than other hosts.
4. Run `/merge-to-main-and-release` only when `linux-next` is green, plan
   evidence is current, and no release is already in flight.
5. After a release succeeds, ensure the plan records the new latest release so
   immutable Linux hosts know to run curl-install e2e.

## Cycle Metrics (report before the handoff)

Run `scripts/cycle-metrics.sh [<since-ref>]` and include its output verbatim in
the final handoff. It emits one `key=value` line per block — branch on those,
never on prose.

Every handoff MUST carry these lines; the two questions they answer are
distinct — measure before you optimize:

- **`mcp:`** — "are the servers used?" Per-server call volume (`servers=`,
  `plan-expert-calls=`). Today only the plan expert is instrumented; the other
  servers are named `uninstrumented-see-682-m8ek`, not faked as zero.
  Also carries **`health=`** (order 737-zcj5) — `ok` / `down:<csv>` / `absent` /
  `unprobed` — sourced from the health probe, NOT from usage. Call volume cannot
  see an outage: a server that is down writes no usage rows, and neither does one
  nobody called, so both render as absence in every count on this line.
  `health=unprobed` is deliberately not `health=ok`; reporting an unmeasured
  expert as healthy is the order-531 shape.

- **`mcp_outage:`** — emitted ONLY when a probe recorded a non-up state
  (`records=`, `health=`, `log=`). Its absence on a healthy cycle is the
  negative control, not an omission. When present, it is the ledger trace of the
  outage: the handoff pastes these metrics verbatim and the loop-status entry is
  built from the handoff, so the outage reaches `plan/loop_status.d/` without any
  agent choosing to write it down.
- **`expert_accuracy:`** — "are the experts RIGHT?" The groundtruth pass-rate
  (`pass=/total=/rate=`), graded against the committed rung-1 query set. Distinct
  from `answer_rate`: an expert can answer every question yet cite spans that do
  not support the answer. Accuracy is pass/total of graded cases, never call
  volume. It reads `deferred source=litmus:expert-groundtruth-harness` when no
  binary can grade in-cycle (then the quick-tier gate carries it).

- **`flow:`** — "does work-done-per-cycle outrun the fixed per-cycle overhead as
  batches grow?" The ROLLING packets-per-cycle view (`cycles=`,
  `avg_completed_per_cycle=`, `avg_commits_per_cycle=`, `overhead_ratio=`) over a
  per-host append log. `overhead_ratio` is total commits per total completed
  packet — the fixed per-cycle cost amortized across the work it produced — and
  is the number the greedier-batching decision (682-yiz7) consumes: if larger
  batches amortize overhead, this ratio FALLS as batch size rises. It reads
  `source=absent` until this host has appended at least one flow record.

  Each cycle MUST append its flow record so the rolling view stays live. Emit it
  here, right after running `scripts/cycle-metrics.sh` for the handoff and before
  Finalization commits — best-effort, the emit never fails the cycle:
  ```bash
  scripts/cycle-metrics.sh --emit-flow \
    host=<this-host> \
    batch_epic=<from select-work-batch `batch: epic=`> \
    batch_seed=<from `batch: seed=`> \
    batch_size=<from `batch: size=`> \
    budget=<from `batch: budget=`> \
    claimed=<packets this cycle claimed> \
    completed=<packets this cycle completed> \
    filed=<new packets/issues this cycle filed> \
    commits=<from cycle-metrics `repo: commits_this_cycle=`> \
    plan_open=<open packet count> plan_total=<total packet count>
  ```

- **`timing:`** — "where does the cycle's wall-clock go?" The ROLLING view over a
  per-host duration log (`steps=`, `build_check_ms_avg=`, `litmus_ms_avg=`,
  `slowest=<step>:<ms>`). "Time spent building, testing" is the most likely
  bottleneck and was invisible until the build/test/litmus entry points began
  appending one duration record per heavy step (packet 682-emvg). `build.sh
  --check` (the local gate), each `scripts/local-ci.sh` litmus phase, and each
  `scripts/run-litmus-test.sh` suite now self-instrument — best-effort, the
  timing write never changes the wrapped step's exit code or output. It reads
  `source=absent` until this host has run one instrumented step. `slowest` names
  the single step to attack first.

The two lines worth reading first:

- **`answer_rate`** — the experts' USEFULNESS. Not call count. An expert called
  two hundred times that refuses two hundred times is heavily used and
  completely useless, and a call counter reports that as healthy adoption. That
  is not hypothetical: order 531 had every `plan_answer` returning
  `confidence=unsupported` (the forge was seeded from a pre-expert branch) while
  launch state truthfully reported `experts: ready`.
- **`verdict`** — the single fact to look at first. `attention:` is not a
  failure; it is the cycle naming its own weakest point.
  `attention:expert-answered-nothing-check-base-branch` is the order-531
  signature and means the ARTIFACT is wrong, not that the questions were hard.

Two rules about these numbers:

- **Never report a metric the tooling did not produce.** `experts_substitution`
  reads `unknown` because it needs the agent harness's tool log, which is not in
  this repo. Leave it unknown. An estimated number makes an unmeasured thing
  look measured, which is worse than reporting nothing.
- **Never propose making expert metrics reward activity.** `answered` is
  reachable only via citations the compiled expert emits when it resolved a real
  packet or path, so calling tools more cannot raise the rate. A change that
  lets `answered` be reached without citations converts a quality signal into a
  volume signal and must be refused on that ground.

## Finalization

Before exit:

1. Reduction-engine capture check: confirm every "this isn't great" observation
   from this cycle is filed in `plan/issues/` (classified `research/`,
   `exploration/`, `enhancement/`, or `optimization/`) and, where reduced,
   promoted to a `plan/index.yaml` packet. An unfiled finding blocks exit. A
   dirty-start preflight refusal performs no reduction cycle; it uses the final
   handoff exception above and exits without touching the checkout.
2. Refresh `plan/index.yaml` if this cycle changed active work, blockers,
   tested release, or host assignments. Record THIS cycle's status as a NEW
   `## Cycle` fragment in `plan/loop_status.d/` via
   `tillandsias-plan loop-status-append --host <host> --ts <UTC-ISO>` — never
   edit the shared `plan/loop_status.md` directly, or a concurrent host's
   status write conflicts for the same reason the old monolithic ledger did
   (packet 582-nqw5). The folded view (`tillandsias-plan loop-status`) is the
   status every host sees; `loop-status-compact` folds fragments into the base
   when drift makes it eligible.

   **A long cycle's `--ts` legitimately predates its write, and `--backfill` is
   the sanctioned path for it (order 801-w4pn).** `--ts` must agree with the
   host clock within 900s or the write is refused; a cycle that read the clock
   at Start Of Cycle and appends at Finalization two hours later trips that by
   construction. Do not widen the window and do not invent a fresh timestamp —
   the limit is what catches a fabricated hour, and re-reading the clock would
   silently relabel when the work happened. Pass `--backfill` with the real
   timestamp, or omit `--ts` entirely when "now" is genuinely the right stamp:

   ```bash
   tillandsias-plan loop-status-append --host <host> --ts <cycle-start-UTC> --backfill
   ```

   `--backfill` only reaches BACKWARD (a future `--ts` is still refused), so it
   waives nothing the limit exists to protect, and the refusal already names it.
3. Validate touched YAML with a parser, using the one that EXISTS where you are:
   `tillandsias-policy validate-yaml <files>` where built, else
   `yq . <file> >/dev/null`, else `ruby -ryaml -e "YAML.load_file('<file>')"`.
   **`ruby` is NOT in the forge image; `yq` is** — a skill that names only ruby
   sends a forge agent to a tool that does not exist, and the tool sitting next
   to it is `python3`, which is FORBIDDEN for committed automation (see
   `plan/issues/meta-orch-enhancement-opportunities-2026-06-20.md` order 63).
   Its presence on PATH is not permission. The forge startup context lists what
   is actually available.
3b. **Re-verify the credential BEFORE the gate** (order 892-aw9p):

   ```bash
   scripts/check-credential-channel.sh reverify
   ```

   The Start-Of-Cycle guard runs once and cannot see a credential that dies
   afterwards. MEASURED on calmecacpilli 2026-08-25: it returned
   `ok:gh-keyring-push-verified`, two pushes succeeded on that credential, and
   ~50 minutes later the third failed with `remote: Invalid username or token`.
   Nothing the guard measured was wrong — the verdict was true when issued. Its
   RESULT simply outlived the thing it checked, which is the same shape as a
   stale gate stamp (887-bz88).

   Run it HERE, immediately before `./build.sh --check`, because that is the
   last point where the remaining cost is still worth saving: a dead credential
   then costs the gate's wall-clock (40s here, 276s on the slowest host) instead
   of being discovered after it, with the work done and the exit contract
   forbidding an unpushed exit. Not per push — the healthy path must not pay a
   round trip for every git operation, and a guard slow enough to notice is a
   guard that gets bypassed.

   On `blocked:credential-expired-mid-cycle` the credential WORKED and then
   stopped; that is distinct from never having had one, and the printed remedy
   is `gh auth refresh`, not seeding a store. Do NOT discard the cycle's work to
   get unstuck — salvage first (872-c9nd) and report blocked with the salvage
   ref.

4. Run the local gate: `./build.sh --check` and fix what it reports.
   An unparseable or unformatted push poisons every downstream clone. Push CI
   no longer exists on any working branch — only the manually-dispatched
   release workflow remains (litmus:github-actions-budget) — so this gate is
   the ONLY trunk protection. Do not push past a red gate (evidence case:
   `plan/issues/local-gate-evidence-query-packets-clippy-2026-08-09.md`).

   Terminology (851-gpb5): this skill called this step "the pre-push gate"
   for months while methodology used the SAME name for a different rule —
   the step-6 merge below — and the collision kept that rule invisible.
   Here "local gate" always means `./build.sh --check`; "pre-push gate" is
   reserved for methodology's `pull_merge_cadence.pre_push_gate`.
5. Commit targeted files only.
6. Satisfy methodology's pre-push gate (`pull_merge_cadence.pre_push_gate`,
   `methodology/multi-host-development.yaml`), then push the relevant branch.
   On a non-`linux-next` branch (`osx-next`, `windows-next`, any shared
   non-trunk branch; `agent/*` and `salvage/*` are exempt) that gate
   requires, before EVERY push — not just at cycle start:

   ```bash
   git fetch origin && git merge origin/linux-next   # resolve conflicts locally
   ```

   The v5 pre-push hook enforces the merge half on the two platform branches
   (`scripts/hooks/pre-push-linux-next-merged.sh`, installed by
   `scripts/install-hooks.sh`); the fetch half stays yours — the hook can
   only compare against the `origin/linux-next` your last fetch recorded. If
   the hook refuses, merge and push again; never `--no-verify` past it.
7. If a startup boundary was recorded, run the guard's `verify` mode. A guard
   failure is a blocker: do not attempt destructive Git cleanup. Finalization
   never deletes, restores, or resets a worktree path.

   **Do NOT remove `$boundary_dir` here** (order 725-bu54). Retirement belongs
   to the NEXT cycle's `snapshot`, which retires the previous boundary before
   taking its own. Removing it here treats this Finalization as THE end of the
   cycle — but an operator-driven loop has no single exit, and a cycle that
   continues after a completed Finalization then finds its own boundary gone
   and cannot attest. That happened twice in one night and cost a valid marker.

   Re-running `verify` after further commits is correct and expected: it still
   compares against the boundary taken BEFORE any work, and re-stamps the head
   it observed so the marker matches what was actually pushed.
8. Confirm there are no uncommitted changes created by this cycle and the
   branch is not ahead of upstream. Pre-existing dirty paths may remain only
   when the boundary guard verifies they are byte-identical to startup.

   Then prove the cycle's FINDINGS survive it (order 741-3y48):

   ```bash
   scripts/check-forge-findings-persisted.sh
   ```

   A GATE, not advisory — non-zero means work already done is about to be thrown
   away. It covers `plan/index.d/`, `plan/loop_status.d/`, `plan/issues/` and
   `plan/mo-full-attestations.d/`, and it catches what `git status` cannot: a
   COMMITTED fragment that was never pushed presents as a clean tree and is one
   teardown from gone. That is not hypothetical — on 2026-08-15 an in-forge
   review filed three valid fragments, `tillandsias-plan check` accepted them,
   and the container took all three with it; they survived only because a human
   happened to be reading stdout. A cycle that files nothing prints
   `ok:no-findings` and is silent, so a clean run stays quiet.

   This matters most inside a forge, where the checkout is a clone that dies with
   the container — but it is correct everywhere, and an unattended host that
   commits without pushing loses the same work to the next `git reset`.
9. Record the verified marker durably, then emit the terminal marker (orders
   614-2gqx + 651-2x5s) as your FINAL output line. `record` derives-and-verifies
   the marker exactly as `self` does and appends the verified line to the
   per-host ledger (`plan/mo-full-attestations.d/<host>.md`) so automation can
   consume a real, reachable hash without parsing a transcript. The ledger
   line attests the WORK head; committing it advances the head, so re-run the
   guard `verify` (permitted: further commits are expected, step 7) and
   re-derive ONCE more — the terminal marker must name the head that CONTAINS
   the ledger record:
   ```bash
   scripts/mo-full-attest.sh record                                  # verify + append + print the marker
   git add plan/mo-full-attestations.d/ && git commit -m "record(mo-full): attest <branch> cycle"
   git push
   scripts/meta-orchestration-worktree-guard.sh verify "$boundary_dir"   # re-stamp the new head
   scripts/mo-full-attest.sh self                                   # terminal marker at the head containing the record
   ```
   Emit the FINAL `self` line verbatim as your final line — do not retype or
   edit it. If any step prints `MO-FULL: FAIL …` and exits non-zero, do NOT
   emit a marker — treat it as a blocker (a missing marker is itself the loud
   failure). The ledger line and the emitted line differ by exactly the
   bookkeeping commit; both are real commits the local gate
   (`scripts/check-mo-full-attestations.sh`) verifies exist and are reachable.
   This gives EVERY full-mode lane the same convergence verification the
   litmus launcher's `check` applies to its one lane, and leaves a durable
   record that outlives the transcript. The marker is the machine attestation
   that finalization steps 1-8 all passed; the outer launcher rejects exit
   zero without it. See "Full-Mode Terminal Attestation" above for the grammar
   and invariants.

9b. Release the checkout lock (order 873-zcim) — AFTER the terminal marker is
   derived, as the cycle's last mutation:
   ```bash
   TILLANDSIAS_CYCLE_HOLDER_PID=$PPID scripts/cycle-checkout-lock.sh release
   ```
   The stale-reclaim bound (dead holder, or 3h) covers a cycle that dies
   before reaching this line, so a crashed cycle cannot silence the cadence —
   but do not lean on it: an explicitly released lock frees the checkout NOW,
   a reclaimed one frees it up to three hours later, and on a 30-minute
   cadence that is six skipped fires.

9c. Reclaim the build cache when it is genuinely due (order 709-in2f,
   methodology `build_cache_hygiene`) — LAST, after the lock is released, so a
   full rebuild's cost is paid in the idle gap rather than inside the cycle:

   ```bash
   scripts/check-build-cache-sweep.sh   # exit 0 = NOT due; skip the body
   ```

   **Read the exit polarity before wiring anything to it.** It exits **0 when
   the sweep is NOT due**, the same convention as `check-deslop-due.sh` and
   `check-daily-maintenance.sh`: the actionable state is the non-zero one, so a
   healthy steady state stays quiet under `set -e`. Branch on the verdict token
   (`build-cache-sweep-not-due` / `build-cache-sweep`), which a copy-paste
   cannot invert.

   Due when `target/` exceeds 40 GiB, OR the marker is older than 14 days, OR
   the marker is absent/unreadable. On `due:`, run `cargo clean` (plus
   `scripts/nix-toolbox.sh gc` where nix is present — never a bare
   `nix store gc`, which would delete the whole persistent cache rather than
   prune it), then stamp what actually ran:

   ```bash
   scripts/check-build-cache-sweep.sh stamp --host <host> \
       --action 'cargo-clean:<result>,nix-gc:<result>'
   ```

   `--action` is REQUIRED, for the same reason `check-daily-maintenance.sh`
   requires `--steps`: a stamp recording that "something happened" without
   recording what moves the unfalsifiability up a level instead of removing it.
   Record `skipped-absent` / `deferred-<reason>` honestly.

   BEST-EFFORT, NEVER A GATE: a failed sweep must not fail the cycle, and the
   sweep must not run before the work. Ephemeral forges read `skip:forge-exempt`
   and never sweep — their `target/` dies with the container.
