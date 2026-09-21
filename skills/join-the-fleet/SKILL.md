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
   or rebuilds it; `scripts/check-plan-binary-current.sh` must answer with the
   literal `ok:validator-surface:<hash>` lane (1287-h6qn). A stale binary mints
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
     REBUILD, THEN PUSH: merging trunk brings checker scripts that are part of
     the plan binary's validator surface, so a binary rebuilt BEFORE the merge
     reads stale AFTER it although its file is newer than its sources;
     `tillandsias-plan validator-surface-hash --check` is the discriminator, and
     `check-plan-binary-current.sh` printing `ok:plan-binary-write-is-opt-in`
     mints nothing — only `stamped:plan-binary-validator-surface` means the
     stamp was written (yolanda, 2026-09-21, measured);
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
