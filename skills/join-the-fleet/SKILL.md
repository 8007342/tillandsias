---
name: join-the-fleet
description: Idempotent onboarding for a worker agent, on bare metal or inside a forge — the requirements to join the Tillandsias fleet, the scheduled work, the work-ref and landing flow, the attestation rules, and how to join the work session. Verified by scripts/check-fleet-membership.sh, which reports what is left and never installs.
license: MIT
metadata:
  author: tillandsias
  version: "1.1"
  invokedBy: /join-the-fleet
  trace: "order:1311-ajpm, order:1317-9ugn, spec:methodology-accountability"
---

# Join the Fleet

Run this once per session on any worker, bare metal or in-forge. Every command
is ensure-shaped: a second run changes nothing and reports the same verdict.
The skill DOES; the checker only SAYS WHAT IS LEFT:

```bash
scripts/check-fleet-membership.sh     # ok:join-the-fleet:<host>:<regime>:ran=<n> skipped=<m>  → you are in
                                      # todo:join-the-fleet:<host>:<regime>:todos=<k> …        → do the todo: lines, re-run
```

Every `skip:` is named with its reason. A green that does not say what it did
not run is not a green; the verdict carries the counts for that reason.

**Authority.** This page is a view. The rules it repeats live in
`methodology.yaml` and `methodology/` (`multi_host_development` including
`work_ref_lane`, `loop_cadence`, `development_environment_lifecycle`,
`agent_identity_contract`) and in the skills it names. When a rule changes,
change methodology first and this page second; never the other way round
(CLAUDE.md, Authority).

## 0 — Classify the host, name the session

| Regime | Detected by | Session name | Checkpoints to |
|---|---|---|---|
| forge | `TILLANDSIAS_HOST_KIND=forge` or `.forge-startup-context.md` | `<host>-<project>-forge` | the branch it was seeded from |
| linux-immutable | `/run/ostree-booted` or `rpm-ostree` on PATH | `<host>-silverblue` | `linux-next` |
| linux-mutable | Linux without the marker | `<host>-<os id>` (e.g. `macuahuitl-fedora`) | `linux-next` |
| macos | `$OSTYPE` darwin | `<host>-macos` | `osx-next` |
| windows | msys / cygwin / mingw | `<host>-windows` | `windows-next` |

The checker prints `note:join-the-fleet:session-name:<name>`; use that name as
the cross-session address. Identity for ledger writes comes from
`scripts/agent-identity.sh id <backend>` (756-hn3a), never hand-composed.
Tiers (operator, 2026-09-14): esme and macneo are floor tier and take
tier-relevant work; yolanda and macbookair take platform fixes; interchangeable
Linux work goes to lenovinha first, then yoga; macuahuitl is the operator's
desktop and the coordinator, not labour.

"Checkpoints to" is where the plan-only lane and the platform-specific commits
go. Your code goes to a work ref (§3); the checker prints
`note:join-the-fleet:branch:work/<order>` when you are on one, because a work
ref is a correct place to be, not a todo.

## 1 — Requirements per regime

Bare metal (all three OSes):

1. **Platform branch checked out** (table above). `git fetch origin` first;
   record the sibling heads of `main`, `linux-next`, `windows-next`, `osx-next`.
2. **Hooks installed**: `scripts/install-hooks.sh` (idempotent). The pre-push
   hook is the local gate; a checkout without it can push what the gate would
   refuse.
3. **Builder toolbox** (Linux): `scripts/with-tillandsias-builder.sh true`
   creates or reuses `tillandsias-builder` (methodology `toolbox_first_scripts`).
   macOS and Windows hosts have no toolbox; the checker skips this by name.
4. **A runnable, current plan binary**: `scripts/cycle-preflight.sh` resolves
   or rebuilds it; `bash scripts/check-plan-binary-current.sh` must end with
   `ok:plan-binary-current` — its stamp line reads
   `stamped:plan-binary-validator-surface:<hash>`, `ok:plan-binary-write-is-opt-in`
   is a read-only pass that mints nothing, and any `stale:` or `blocked:` line
   is a stop (1287-h6qn). The `ok:validator-surface:<hash>` literal is the plan
   binary's own `validator-surface-hash --check` answer, which the checker
   consumes (it then prints `ok:validator-surface:content-verified` on stderr
   and ends `ok:plan-binary-current`); this page used to ask the worker to look
   for the subcommand's literal as the checker's verdict (1338-2sae).
   Name the script, not the `validator-surface-hash --check` subcommand alone:
   in a forge, a redirected CARGO_TARGET_DIR makes the subcommand answer
   `unknown:validator-surface`, which is not a verdict. A stale binary mints
   orders the fold never allocated.
5. **Credential channel**: `scripts/check-credential-channel.sh` (982-sguu).
   `blocked:*` means STOP AND REPORT to the coordinator; do not start
   committable work you cannot land. Never `gh auth login` or `gh auth refresh`
   (1025-a896: a re-auth on one host evicts the operator's token on every
   other host); the operator provides tokens (`tillandsias --github-login
   --with-token`, stdin), never an agent.
6. **Start-of-day maintenance**: `scripts/check-daily-maintenance.sh check`;
   on `due:*` run the Start Of Day gate in skills/meta-orchestration once.
7. **Experts answer**: `scripts/check-mcp-expert-health.sh`; if not,
   `scripts/dev-host-experts.sh`. Reads go through the experts first
   (`plan_next`, `plan_status`, `methodology_ask`); the filesystem is the named
   fallback (CLAUDE.md, Bootstrap).
8. **Recorded conflict resolutions**: `git config rerere.enabled true` (1317-9ugn).
   A work ref merges trunk more than once before it lands; rerere replays a
   resolution you already made instead of asking for it again, and the checker
   prints `todo:join-the-fleet:rerere:git config rerere.enabled true` until it
   is set. All regimes, including forges.

In a forge:

- Steps 3, 6 and the substrate are named skips (no toolbox, no podman, no
  vault; the daily gate exempts forges itself).
- `CARGO_TARGET_DIR` is exported: never resolve a binary from a hardcoded
  `target/` path (721-nyev); use `scripts/plan-binary-probe.sh`.
- The credential channel is a REPORT for verification-only work (818-cgpn)
  and a GATE for anything that commits.
- `origin` in a forge is the enclave's git MIRROR, not GitHub, and it lags:
  on 2026-09-21 it sat three commits behind for minutes while a coordinator
  cited a GitHub sha (1338-tkfh). From inside a forge, "landed upstream but
  not here yet" and "exists nowhere" both answer `couldn't find remote ref`,
  so a sha that does not resolve is UNDECIDED, not absent. Verify the
  PROPERTY a landing was meant to establish on the trunk you can reach (a
  verdict line, a file's content), or wait for the mirror to carry the sha;
  never close a row on a sha you cannot resolve, and when you cite a sha to
  someone else, say which remote it is on. The mirror's upstream-sync
  cadence is not observable from inside a forge today (1338-tkfh's closure
  makes the two answers differ).
- A broken git mirror is a HARD STOP: "upgrade tillandsias, rebuild the forge",
  never a warning retried against (1310-rec6). A forge cannot repair the host
  that runs it.

## 2 — Substrate (bare-metal Linux)

The enclave and this host's own per-project git mirror are brought up,
rebuilt and troubleshot by the standalone skill
**/initialize-bare-metal-host** (1312-i6da; `skills/initialize-bare-metal-host`).
This page never duplicates it. Its checker,
`scripts/check-bare-metal-host-initialized.sh`, is what the fleet-membership
checker calls for the substrate line. It never seeds a token: the GitHub
credential is the operator's per-host act.

macOS and Windows hosts provision through the installed tray (`--provision`,
`--reset-state` per 1286-4437); the checker skips the substrate line by name
there.

## 3 — Scheduled work

- **Cadence** (methodology/multi-host-development.yaml `loop_cadence`, operator
  ruling): fleet loops run every 2 hours, staggered by the slot table there; a
  host arms its OWN slot; floor forges and the operator's own forge have no
  slot and are driven one-off by the coordinator. The full e2e lane is rate
  limited to one full cycle per 4 hours per host
  (`scripts/forge-e2e-rate-limit.sh`).
- **A worker's slot** is two commands, in this order:
  `scripts/check-fleet-membership.sh` (the daily-maintenance and credential
  checks come out as `todo:` lines; on `due:*` run the Start Of Day gate in
  skills/meta-orchestration once), then `/advance-work-from-plan`, which
  claims, works, lands and hands off. `/meta-orchestration` in full mode is
  the COORDINATOR's loop: it composes the coordination skill (sibling merges,
  relays, the union litmus) and the release lane, and a worker running it
  does coordinator work by accident. An earlier version of this page said "a
  cycle is /meta-orchestration (full mode)"; the operator asked which of the
  two a worker runs (relayed by lenovinha, 2026-09-20) and this paragraph is
  the answer.
- **Claims are by order, through the plan lane**: `tillandsias-plan set-field
  <order> status in_progress --host <host> --reason …`, pushed, then
  `tillandsias-plan next <role> | grep -c <order>` → 0. A hand-off by message
  separates nobody; the claim on trunk does (1140-d6ni).
- **Before calling a packet unclaimed**, fold the sibling branches:
  `scripts/check-claims-across-branches.sh --batch <order>…` (1034-whsp).
- **The work-ref flow** (methodology `work_ref_lane`, 1315-4a7j; operator
  direction 2026-09-20). This is the PREFERRED workflow, in this order and no
  other:

  1. claim by order (above), pushed through the plan lane;
  2. `git switch -c work/<order> origin/linux-next` — the work ref starts from
     trunk, named by the packet's order and nothing else;
  3. commit and push to `work/<order>` as often as you like: no gate stamp, no
     trunk merge, the fast deciders run and WARN (`warn:pre-push:…`), nothing
     refuses. Bring trunk in with `git merge origin/linux-next` when you need
     it (never rebase a pushed ref; rerere replays your resolutions). The ref
     name must match `work/<order>` exactly, the packet-id grammar
     (`work/[0-9]{3,4}-[a-z0-9]{4}`): the hook does not check the name, a
     non-conforming one takes the ordinary branch path, and the stray sweep
     reaps it hours later without telling you (yoga, 2026-09-21). MERGE, THEN
     REBUILD, THEN PUSH — CONDITIONALLY, on what the merge touches. The plan
     binary's VALIDATOR SURFACE is crates/tillandsias-plan/src/*.rs (the files
     matching `_vs_surface_files` in scripts/check-plan-binary-current.sh), the
     crate's Cargo.toml, and the named Cargo.lock stanzas. A merge touching the
     surface requires merge → rebuild → push, and the surface hash MUST move.
     Shell checker scripts and test scripts are NOT members: a shell-only
     change needs no rebuild, and the hash MUST be unchanged — an assertion
     that it must move on such a landing reads a correct rebuild as a failed
     one (1338-2sae; the forge read the function instead of accepting this
     page's earlier unconditional sentence, and yolanda verified the hash
     byte-identical across a landing that carried a checker and a test). A
     binary rebuilt BEFORE a surface-touching merge reads stale AFTER it
     although its file is newer than its sources. The instrument is
     `bash scripts/check-plan-binary-current.sh` — name it, not the
     `tillandsias-plan validator-surface-hash --check` subcommand alone, which
     returns a non-verdict wherever CARGO_TARGET_DIR is redirected out of the
     checkout; compare the hash VALUE in the direction the change predicts, and
     note that `ok:plan-binary-write-is-opt-in` mints nothing — only
     `stamped:plan-binary-validator-surface` means the stamp was written
     (yolanda, 2026-09-21, measured);
  4. open the PR: `gh pr create --base linux-next --head work/<order> --draft`,
     and `gh pr ready` only once the closure evidence is on the row;
     Before `gh pr ready`, the pre-ready check: MERGE `origin/linux-next` INTO
     THE WORK REF FIRST, then `git diff --name-status origin/linux-next...work/<order>`
     must show no `D` line the body does not explain. The order matters and it
     was learned the expensive way (macneo, 2026-09-21, PR #131): a work ref
     that is behind trunk can have MORE THAN ONE merge base, git picks one and
     says so only in a warning (`multiple merge bases, using <sha>`), and the
     three-dot diff then describes a history that is not the one the PR
     proposes — it showed zero deletions where the two-dot diff showed about a
     hundred. Treat that warning as a STOP, not noise: merge trunk, re-run,
     and only when the two-dot and three-dot diffs agree does the check mean
     what it says.
     THEN, still before `gh pr ready`, run the gate's own deciders on
     the MERGED work ref: `./build.sh --preflight` (order 1305-udgs;
     every guard that can refuse a push, in seconds, no build; `--full`
     for the whole roster). A work-ref push only WARNS on a red decider,
     so nothing before this step refuses for you. MEASURED 2026-09-22:
     three of six reviewed, fixture-green PRs were dropped from one
     relay by sub-second deciders their authors never ran (an unguarded
     bash-4 `${v,,}`, a `printf | grep -q` verdict pipeline, a data
     string quoting a target/ plan-binary path), costing a relaunch
     each.
     REGIME: `--preflight` needs setsid; on macOS it refused every guard
     (`refused:preflight:ran=0 skipped=3 failed=108`, macbookair
     2026-09-22) until 1352-vmbc. Where it cannot run, a host runs the
     deciders directly on the merged ref, which is what the relay
     preflight does: check-bash-dialect,
     check-sigpipe-verdict-pipelines-added,
     check-plan-binary-probe-usage, check-litmus-pin-claims,
     check-script-exec-bits, check-added-fragments-parse,
     check-scorable-obligation-added, and `cargo fmt --check`.
     ONE COMMAND, FOUR BEHAVIOURS (measured 2026-09-22, one row:
     1353-ryhq). macOS died on an unguarded `exec setsid` until
     1352-vmbc. Windows and the MinGW locus RUN it and print `ok:` while
     about a third of the guards skip on a 5s front-door deadline they
     miss by one or two seconds (drvfs and MSYS spawn cost, not slow
     fixtures). A forge printed `refused:` for two guards that never
     executed because the checkout tmpfs was full (1349-53h6). AND LINUX
     IS NOT EXEMPT: `ok:preflight:ran=99 skipped=12 wall=107s` on yoga,
     with two skips named `deadline:6s — outlived the 5s front-door
     deadline; the gate still runs it`. So the caveat is universal and
     the regimes differ only in how much they skip. IF PREFLIGHT REPORTS
     `refused:` FOR A DECIDER, CHECK WHETHER THAT DECIDER RAN before
     concluding anything about your tree; and read the summary line,
     because `ok:` means nothing that ran refused, NOT that the tree is
     clean. Two more traps in the same step: on the MinGW locus
     `build.sh` re-execs into the WSL2 builder before flags are parsed,
     so `--preflight` never tests MinGW itself; and a bare `cargo` that
     is not on PATH answers 127, which is indistinguishable from a pass
     to anything reading only for failure.
     TWO CHANGES NO DIFF SHOWS AS AN INTERFACE CHANGE (both cost a red
     release tier on 2026-09-22). Changing what a subject PRINTS breaks
     its consumers: a verdict token is an interface, so `git grep -l
     '<verdict string>'` across `*.yaml *.sh *.rs *.md` and list every
     live consumer with the reason each is safe. Changing what a subject
     READS breaks its FAKES: a resolution change is an interface change
     for everything that builds a scratch tree, whose script lists were
     written against the old resolution without naming it — `git grep -l
     '<subject>' -- 'scripts/test-*'`. Finding three consumers is worth
     nothing without the sweep that says there is no fourth.
     A plan-lane push to linux-next is CHEAP FOR THE PUSHER AND EXPENSIVE FOR
     A GATING CANDIDATE: the queue and the relay lane compare base shas, so a
     fragment landing during a twenty-minute FULL gate requeues the candidate
     (three fragments cost two gates on 2026-09-22 — 1335-2nzf carries the
     fix, adopting on plan-only movement). When the coordinator declares a
     quiesce for a drain, hold plan-lane pushes to linux-next until it is
     lifted by name; work refs and salvage refs are unaffected.
  5. the landing queue (`scripts/land-queue.sh`, 1316-bnzt) integrates it
     ONCE, gated as one serialized landing: today every candidate pays the
     FULL tier; the light and scoped tiers (proportional to the paths a PR
     touches: plan and docs are light, one crate or one lane is scoped,
     anything wider is full) are 765-xpct's selector, approved by the operator
     on 2026-09-20 and activating when that row closes;
  6. close by order (`set-field <order> status completed …`) after the landing
     proves — after the merge is on `origin/linux-next`, not after the PR is
     opened. The evidence SHA on the closing event is the LANDED commit on
     `origin/linux-next` (the merge or relay commit), never the work ref's own
     SHA: they are different objects, and a closure that cites the gated SHA
     points at something a reader of trunk cannot resolve as the landing
     (yoga, 2026-09-21). Until then the row stays `in_progress`.

  The pre-push hook and the land tool print the same affordance on every
  refusal; this is the sentence they point at, word for word:

  <!-- affordance:begin -->
  ```text
  prefer work branches: git switch -c work/<order>; push there freely;
  open the PR with: gh pr create --base linux-next --head work/<order>
  the landing queue integrates it. See ./skills/join-the-fleet §3
  ```
  <!-- affordance:end -->

  MIGRATION, NOT ENFORCEMENT (operator, 2026-09-20): a direct gated push to
  `linux-next` still lands today; it will be refused later, once
  `scripts/check-landing-provenance.sh` measures that most landings arrive
  through the queue, and that flip is the operator's decision on a number.
  Until a host's token can open PRs (the fleet's fine-grained token lacks
  "Pull requests: write" as of 2026-09-20), push the work ref and tell the
  coordinator its SHA: the relay lane lands it exactly as the queue would.
- **Testing an UNCOMMITTED edit inside a forge** (T4 of
  cloud-only-project-lifecycle, 1350-8hmy). A forge checks out a fresh tree; it
  does not see your working copy. The sequence, and it WORKS TODAY on a host
  that pushes through its own mirror:

  1. get the dirt onto a ref — `scripts/salvage-dirty-worktree.sh <slug>` for a
     tree you cannot gate, or an ordinary `work/<order>` push for work in
     progress. Run salvage from the REPO ROOT: `scripts/salvage-dirty-worktree.sh
     <slug>`, not `./salvage-dirty-worktree.sh` from inside `scripts/`;
  2. push it THROUGH THIS HOST'S OWN LANE (skills/initialize-bare-metal-host §6).
     `receive-pack` writes `refs/heads/<ref>` into the mirror as the push
     happens — the post-receive hook only LOGS, it does not perform the update;
  3. launch the forge. A clone-only forge clones `git://git-<project>/<project>`
     — THE MIRROR — at entrypoint (crates/tillandsias-headless/src/main.rs), so
     the ref is already there, and `git checkout <ref>` inside the forge gets
     your tree.

  MEASURED, yoga 2026-09-22, on a ref pushed through the lane that night:
  the mirror held `refs/heads/salvage/yoga/20260921-lane-acceptance` at
  `281011af5472…`, byte-identical to GitHub's, with 693 refs present and the
  mirror's `linux-next` current at `aef882402`.

  **WHAT THIS DOES NOT COVER, and the failure is silent.** A ref pushed from
  SOMEWHERE ELSE — another host's work ref, or anything that reached GitHub
  without passing through YOUR mirror — is not in your mirror until it syncs,
  and today the exported heads move only at startup and on a relay. There is no
  `tillandsias --sync` yet: that command lands under T1 of
  cloud-only-project-lifecycle, and this page names it rather than describing it,
  because a documented command that does not answer is worse than a named gap.
  Until then, a mirror that has not relayed lately is SILENTLY BEHIND — lenovinha
  met this at 00:03 on 2026-09-22 with a mirror four commits behind GitHub, and
  the symptom was a push rejected for a stale old-object-id, not a message about
  staleness.
  AND DO NOT GO LOOKING FOR A sync-state REF: v56.9.22.1 shipped the
  sync-state PUBLISHER and the sweep's stranded-tag explanation, but
  nothing CALLS the publisher — the script was never copied into the
  mirror image and no call site existed — so a mirror built from this
  release produces no sync-state ref and `git ls-remote` for it returns
  nothing. The lifecycle that runs it arrives with PR #163. Stated here
  because a half-shipped feature reads exactly like a broken one from
  the outside, and the search costs more than the sentence.

  **AND TESTING ON THE HOST IS UNAFFECTED BY ANY OF THIS.** Editing in your
  checkout and running `./build.sh --check` needs no forge, no mirror and no
  ref: yoga landed five rows across nine gates that way on 2026-09-20 without a
  project mount. This sequence is for testing an uncommitted edit INSIDE a
  forge, which is a narrower question than "how do I test my edit".
- **Platform branches**: macOS and Windows commit platform-specific work to
  their own branch; the coordinator relays to `linux-next`. Before every push
  of a non-linux-next platform branch, merge `origin/linux-next` into it
  (methodology `pre_push_gate`). A work ref is exempt from that rule: it is
  integrated once, at its landing.
- **Salvage before you refuse** (872-c9nd): a dirty tree you cannot land goes
  to `scripts/salvage-dirty-worktree.sh <slug>` → `salvage/<host>/<date>-<slug>`
  on origin. Prose about a diff is not a copy of it. A work ref makes salvage
  rare: a tree you can commit goes to `work/<order>` and is on origin in one
  ungated push.
- **A thing not on origin is not a thing.** Before "filed", "closed" or
  "landed" leaves the host: `git ls-remote origin refs/heads/<branch>` against
  `git rev-parse origin/<branch>`, and `git log origin/<branch>..HEAD --oneline`
  must be empty. A pushed work ref is SAFE; it is not LANDED until its merge
  is on `origin/linux-next`. A host whose pushes are silently not arriving is
  indistinguishable from a quiet one until someone runs status on the other
  end (2026-09-20, five commits).

## 4 — Attestation

- **Full-mode marker**: `scripts/mo-full-attest.sh self` prints the verified
  `MO-FULL:` line; `record` appends it to `plan/mo-full-attestations.d/<host>.md`.
  Never type a SHA (651-2x5s). On a work ref the marker attests the work ref:
  `self` reads the current branch and requires its pushed head to converge.
- **Stage before the gate**: the gate stamp reads each path's mode from the
  index, so a new executable file staged AFTER `./build.sh --check` moves the
  digest with no content change and the push is refused (1276-mugq, macneo).
  `git add` every new file first.
- **Every handoff** (`tillandsias-plan loop-status-append --file …`) carries
  the verbatim `scripts/cycle-metrics.sh` block and a `tokens:` line
  (1119-6wn6); `subagent_tokens=0 agents=0` when nothing was spawned.
- **Timestamps come from the clock, never from memory**: the tool's writes
  read it; a hand-written fragment `ts:` more than 900 s in the future is an
  invented time (pirria, 2026-09-20).
- **A first-ever host** adds its capabilities row to `plan/index.yaml`
  directly, not as a fragment (846-idhn: a first row as a fragment is dropped
  at fold time and the pre-push hook refuses `plan-ledger-incomplete`).

## 5 — Join the work session

1. Run the checker; make every `todo:` line ok.
2. Message the coordinator with: the session name, the checker's verdict line,
   the credential verdict, and the sibling heads you recorded. Name the
   packet you are taking, claimed by order (step 3 above), or ask for one.
3. Read the Direction and the open work through the experts:
   `plan_next`, `plan_status <order>`, `methodology_ask`. Fall back to files for
   exactly three reasons and name the one that applies: unavailable,
   verification, not exposed (CLAUDE.md, Bootstrap).
4. Report by comparing trees, not by narrating: paste the artifact (the
   verdict line, the ls-remote line), never "I verified that".
5. **Arm this session's own recurring slot, then stay resident.** Joining is
   not a one-shot report: a joined host keeps working on its slot until the
   operator stops it. The operator asking this session to join the fleet IS
   the consent to arm ITS OWN session-local cron (operator ruling
   2026-09-23). It is never consent to message another host to arm one
   (a peer cannot commit operator spend).

   Read your slot from `methodology/multi-host-development.yaml` →
   `loop_cadence.stagger_slots` (`methodology_ask "loop cadence slot for
   <host>"`), then arm exactly one recurring job with the harness's
   scheduler (CronCreate, or the `/loop` skill). Its prompt is the slot
   from §3:

   ```text
   worker host (every host except the coordinator):
     cron "<slot-minute> <slot-hours> * * *"
     prompt: Run scripts/check-fleet-membership.sh and resolve every todo:
             line (on due:* run the Start Of Day gate in
             skills/meta-orchestration once), then use the
             /advance-work-from-plan skill.
   coordinator (macuahuitl) only:
     prompt: Use the /meta-orchestration skill.
   floor-tier hosts and ephemeral forges: no slot; do not arm (§3).
   ```

   - **No stacking is already handled; do not add a lock.**
     advance-work-from-plan §1b and meta-orchestration step 2b take
     `scripts/cycle-checkout-lock.sh`. On overlap they refuse without
     retrying, and the next fire tries again on its own clock.
   - **An empty queue is a quiet hold, not an exit.** Keep the cron armed;
     a cycle that finds nothing reports `refused:no-tier-work` or an empty
     batch and ends. Tell the coordinator when that happens: an idle fleet
     is a coordinator problem, not a reason for the worker to leave.
   - **A session cron fires only while this session is open, and it expires
     after 7 days.** Arming it and then ending the session arms nothing. That
     is how lenovinha's join on 2026-09-22 went quiet: it worked through its
     batch and exited with no slot armed. After arming, list the job
     (CronList) and paste the line, then end your turn with the session
     still open.

## 6 — Verify

```bash
scripts/check-fleet-membership.sh            # the verdict, with counts
scripts/test-join-the-fleet-idempotent.sh    # ok:join-the-fleet-idempotent:6/6
./build.sh --preflight                       # the front door (1305-udgs): every guard roster, ≤150 s
```

The fixture pins: two runs print the same verdict and leave `git status`
untouched; in a forge every host-only step is a named skip and `skipped=`
equals the number of skip lines; a missing pre-push hook yields
`todo:join-the-fleet:hooks:scripts/install-hooks.sh` with a non-zero exit;
rerere off yields `todo:join-the-fleet:rerere:git config rerere.enabled true`
and on yields `ok:join-the-fleet:rerere`; a checkout on `work/<order>` prints
`note:join-the-fleet:branch:work/<order>` and no branch todo; and the
affordance block in §3 is byte-identical to what the pre-push hook prints.
Bound as `litmus:join-the-fleet-idempotent` (spec methodology-accountability).
The front door runs every guard the three rosters name under a per-guard
deadline and reports the ones it could not run by name; a host that cannot
pass it has not joined.
