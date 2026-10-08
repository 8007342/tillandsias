# Gate collisions under scoped stamps (investigation, 2026-10-01)

Produced by a Fable investigation the operator requested after the overnight push collisions; filed verbatim by the coordinator (macuahuitl). Rows: 1524-w8ys (hook refusal), 1524-7gn7 (land-tool push classification), 1524-jnby (scoped-stamp adoption). The report reads code at origin/linux-next c40fef6bd; nothing in it was committed or pushed by the investigator.

---

# Push/land gating on linux-next: root cause of tonight's collisions and a gate-by-gate review

Prepared 2026-10-01 from a read of `origin/linux-next` at 2b299347d (detached worktree), the coordinator's checkout logs (`.git/tillandsias-land-gate-attempt-1.log`, `.cache/metrics/tillandsias-timing.jsonl`), tonight's ledger fragments, and a hermetic four-arm experiment driving the REAL `gate-stamp.sh`, the REAL `pre-push-local-gate.sh` and the REAL `land-on-platform-branch.sh` against a scratch bare origin and a second "host" clone. Nothing in the checkout was modified; no commits, pushes or network calls were made.

---

## 0. Root cause in one paragraph

The 765-xpct change-class selector now writes **scoped** gate stamps (`scope build-scripts,specs` instead of `scope full`) whenever it skipped any guard. Every mechanism that lets a land survive trunk moving underneath it was written for `scope full` and treats a scoped stamp as second-class: `land-on-platform-branch.sh`'s stamp adoption (1174-u5wp) requires `gate-stamp.sh scope == full`; `gate-stamp.sh memo-check` answers `stale:scoped-stamp-cannot-memoize-full-gate`; and `enforce_stamp_scope` in the hook, which only runs for a scoped stamp, contains a `git cat-file -e "$remote_sha"` check that fires exactly when the remote moved since the last fetch and reports it as a classification failure ("no usable local base", remedy `./build.sh --check`) rather than as the lost race it is. The land tool's lost-race regex (`non-fast-forward|fetch first|stale info|cannot lock ref`) does not match that text, so it printed `refused:land:push-failed — retrying THIS PUSH cannot help (not a lost race)` and exited 6. On relaunch the plan-only move could not be adopted (scope != full), so a 1183 s gate was repaid in full and then went red on an unrelated aged fixture. **The gate was protecting its own bookkeeping, not trunk**: the hermetic control arm with a `full` stamp lands the identical scenario on attempt 2 with zero extra gate, and fetch+merge alone (no gate) is accepted by the hook under the scoped stamp.

Measured savings of the scoped tier tonight: land120's scoped gate ran **1183 s** against full gates of 1124–1270 s (land115–119). The scoped tier saved roughly nothing and cost one full re-gate plus a misclassified refusal.

---

## 1. Question 1 — the full push path and why a plan-only trunk move costs a refusal or a re-gate

### 1.1 The path, by symbol

`scripts/land-on-platform-branch.sh` (BRANCH=linux-next, so BRANCH==TRUNK and the 1064-r8fv mandated-merge block is skipped):

1. attempt loop: `git fetch -q origin "$BRANCH"`; `_unpushed_merges=$(git rev-list --merges --count origin/$BRANCH..HEAD)`; a relay branch carries merges, so it MERGES `origin/linux-next` (else rebase, falling back to merge).
2. `allocate-gate-step-prefix.sh --commit` (1162-qbrx), `check-native-lint-attested.sh` (1235-rfub).
3. union-debt check `$_um` (1056-5344).
4. **adoption** (1174-u5wp): `gate-stamp.sh verify == ok:gate-fresh` AND `gate-stamp.sh scope == full` → `_adopted` set, gate skipped. Otherwise `./build.sh --check > $_gate_log`.
5. `build.sh --check` → `memo-check check` (`stale:scoped-stamp-cannot-memoize-full-gate` for any scoped stamp) → … → `_write_gate_stamp` → `_stamp_scope=full` unless `_CLASS_SKIPPED>0`, in which case `_stamp_scope="$_CLASS_SET_MEMO"` (the class set of the diff vs merge-base with origin/linux-next, 765-xpct) → `gate-stamp.sh write --scope ...`.
6. advisory `check-unrunnable-platform-arms.sh`, advisory litmus notice (1201-9it2: `--check` runs NO litmus).
7. `timeout 300 git push origin HEAD:refs/heads/$BRANCH > $_plog` (1131-iax2, 1366-d5v2).
8. on rc!=0: auth regex → exit 5; **lost-race regex** `non-fast-forward|fetch first|stale info|cannot lock ref` → if NO match: `refused:land:push-failed — retrying THIS PUSH cannot help (not a lost race)` exit 6; if match: fetch, `merge-base --is-ancestor HEAD origin/$BRANCH` proof, else ancestry classification (`push-failed-origin-unmoved` exit 6 vs "origin moved — retrying").

The composed `.git/hooks/pre-push` (tillandsias-pre-push-v8) captures stdin once and runs, fail-fast: `pre-push-no-stale-base-revert.sh` → `pre-push-main-branch-affordance.sh` → `pre-push-linux-next-merged.sh` (osx-next/windows-next only) → `pre-push-version-guard.sh` → `pre-push-local-gate.sh`.

`pre-push-local-gate.sh` section 2 (`gate-stamp.sh verify`):

```
ok:gate-fresh                      -> enforce_stamp_scope
stale:legacy-stamp-format          -> attempt_plan_only_lane || refuse
stale:never-run|tree-changed       -> attempt_plan_only_lane || refuse (names movers, 970-7fqk)
anything else                      -> warn, do not block
```

`enforce_stamp_scope`:

```
scope == full                      -> return 0            (no diff work at all)
scope unreadable                   -> refuse
for each ref: remote_sha all-zero OR ! git cat-file -e remote_sha
                                   -> refuse "no usable local base to diff against"   <-- (b)
diff remote_sha..local_sha, classify; missing classes
                                   -> attempt_plan_only_lane || refuse "also changes: <classes>"  (post-1521-y72e)
```

### 1.2 What `git` hands the hook, measured

git's pre-push stdin carries `<remote ref> <remote sha>` **from the remote's ref advertisement during the push**, not from `refs/remotes/origin/*`. Measured in the hermetic ARM 1:

```
HEAD eaefd705… refs/heads/main 35229309…
remote sha 35229309… is NOT in A's object store (origin advertised it; A never fetched)
origin/main as A last fetched it: 11a5d687…
origin's real tip:                35229309…
```

So after a gate during which trunk moved, `git cat-file -e "$remote_sha"` fails by construction. That check is therefore **a "did the remote move since my last fetch" detector**, and its only possible positive is a non-fast-forward push that the remote would have refused anyway (a local object store that lacks the remote tip cannot contain it). It is reached only for scoped stamps because `full` short-circuits first.

### 1.3 (b) reproduced end to end (ARM 1: scoped stamp, trunk moves by ONE plan-only commit from another host during the gate)

```
land: attempt 1 — push
refused:land:push-failed — retrying THIS PUSH cannot help (not a lost race); merge trunk and re-gate:
  why: origin refused the push for a reason a retry cannot change: it was not a lost race
  remedy: merge the ref the refusal below names (for a mandated merge that is origin/main), re-gate, then re-run
✗ pre-push refused: the gate stamp is scoped to 'build-scripts' but refs/heads/main has no usable local base to diff against
rc=6
RELAUNCH: ok:land:…:attempt-1   gate-count: 2   (a full re-gate was paid for a plan-only move)
```

Tonight's timeline from the timing log agrees: land120 attempt-1 gate ended 05:01:58Z after 1183 s; 2b299347d (two new `plan/index.d` fragments, nothing else) landed 04:57:53Z, four minutes before the gate ended; the relaunch's gate ran 69.5 s and exited 1 (fleet-activity ARM 2).

### 1.4 The control (ARM 2: identical scenario, `scope full`)

```
land: push did not land (rc=1); origin moved 11a5d687f -> 352293097 — retrying
land: attempt 2 — fetch + integrate
ok:land-adopts-valid-stamp:… — this tree already holds a green full-scope gate stamp; skipping the gate (1174-u5wp)
ok:land:…:attempt-2            gate-count: 1
```

Under a full stamp the hook never consults the remote base, the remote refuses non-fast-forward, the land tool classifies it as a race, merges the plan-only move (which `compute()` cannot see — 930-i6x4 excludes `plan/index.d/*.yaml`, `plan/loop_status.d/*.md`, `plan/mo-full-attestations.d/*.md`, top-level `plan/issues/*.md`) and adopts the stamp. This is the "every relay land tonight that hit a moved trunk landed on attempt 2 in seconds" behaviour that 1335-2nzf's own text cites as the land tool's advantage over the queue. **765-xpct took it away for every scoped land without saying so.**

### 1.5 The variant where the gate fetched (ARM 4)

If anything during the gate updates `refs/remotes/origin/linux-next` (build.sh itself does not fetch — `grep 'git fetch' build.sh` is empty — but a decider or the operator may), git declines the non-fast-forward before running the hook (empty ref list, 877-mynm), the land tool correctly says "origin moved — retrying", and attempt 2 **still re-gates in full** because the scoped stamp is not adoptable (`gate-count: 2`). So the scoped stamp costs a full re-gate on every trunk move in both variants; only the un-fetched variant additionally misclassifies the race.

### 1.6 Fetch+merge is the whole remedy (ARM 3)

Under the scoped stamp, after the hook's refusal: `git fetch origin && git merge origin/main` (no gate) → `gate-stamp.sh verify` = `ok:gate-fresh`, `scope` = `build-scripts` → `git push` → `✓ local gate: scoped stamp 'build-scripts' covers every outgoing change class` → landed, `gate-count: 1`. The hook's printed remedy for the same state was `Re-run the full gate: ./build.sh --check` (20 min). The remedy is wrong by a factor of ~1000 in time and sends the reader to the step that cannot fix the cause.

### 1.7 (c): the "launch-time ancestry check"

No script in the land path refuses on ancestry at launch for `linux-next`. `land-on-platform-branch.sh` fetches and merges `origin/$BRANCH` at the start of every attempt; `relay-preflight.sh` cuts `relay/<utc>` from `origin/linux-next` and never pushes. The only ancestry preconditions in text are CLAUDE.md ("Before fast-forwarding a platform branch, verify the remote platform head is an ancestor of the source ref") and the land tool's own post-push proof. I could not find the check that failed on land115 in code; it is consistent with a hand-run `git merge-base --is-ancestor origin/linux-next HEAD` between relay-preflight and land. Two relay-preflights are recorded tonight around land120 (247.8 s at 04:42:04Z, 352.4 s at 05:15:04Z), consistent with a re-cut. **Judgement:** a plan-only claim landing between preflight and land does not invalidate anything relay-preflight proved (its deciders are either independent of `plan/` or re-run by the gate), and the land tool would have merged it for free before gating. The check, if it is a hand step, refuses what the tool integrates; drop it or make it advisory.

### 1.8 Where 1335-2nzf's "adopt plan-only movement" lives, and why it did not apply

Implemented **only in `scripts/land-queue.sh`** (status `completed` 2026-09-23, yoga): after the gate it re-reads `$REMOTE/$TRUNK`, and if it moved, classifies `git diff --name-only $base_sha $base_now | gate-stamp.sh classify`; if every class is `plan-ledger` it re-merges onto the moved target and pushes without a second gate (`adopt:land-queue:…:plan-only-move`), else `requeue:…:target-moved`. Fixture `test-land-queue.sh` ARM 10a pins it.

It did not apply tonight because the coordinator lands through the relay lane (`land-on-platform-branch.sh`), not the queue (the fleet token cannot open PRs, join-the-fleet §3). The land tool has no delta classifier at all; its "adoption" is the stamp digest's blindness to plan paths plus the `scope == full` condition. The two tools therefore disagree: the queue adopts a plan-only move by **classifying the trunk delta**; the land tool adopts by **the stamp still verifying**, and only for `full`. 1335-2nzf's own verifiable_closure asked for "the same rule the land tool applies … read from one place" — that was never done; the queue has its own copy.

### 1.9 Is "no usable local base" the right question after a merge of plan-only movement?

No. After fetch+merge the base exists and the question `enforce_stamp_scope` actually wants answered — "does the outgoing diff against the remote's CURRENT tip reach outside the stamp's scope" — is answered correctly (ARM 3). Before the fetch, the right verdict is "the remote moved since you fetched; this push cannot fast-forward; fetch and retry — if the movement is plan-only the stamp survives". The hook can even decide that locally: a remote tip absent from the object store is sufficient proof of non-fast-forward.

---

## 2. Question 2 — every condition under which a plan-only push is refused TODAY (post-land119, 2b299347d)

"Plan-only" = outgoing diff touches only `plan/`. Order is the composed hook's. **I** = intended, **D** = defect / unjustified for plan-only.

| # | Condition | Code path | Verdict |
|---|---|---|---|
| 1 | No runnable `tillandsias-plan` on the host | `pre-push-main-branch-affordance.sh` → `blocked:main-branch-affordance:no-plan-binary` (fail-closed stub, 1443-sb9b). Runs before the local gate for every push. | I (branch-discipline needs the seed), but it blocks plan-only pushes on a host that has never built — a floor-host hazard. |
| 2 | Stale base: `remote_sha` is local, HEAD lacks it, and the diff deletes files no outgoing commit touched (e.g. another host's new fragments) | `pre-push-no-stale-base-revert.sh` → `blocked:stale-base-revert` | I; remedy (`git fetch && git merge`) is right. Only reachable after a fetch without integrate. |
| 3 | Push to osx-next/windows-next not containing `origin/linux-next` and code tree not identical to a trunk first-parent commit | `pre-push-linux-next-merged.sh` → `blocked:linux-next-not-merged` (subset exception 1259-kn83 ignores `plan/`) | I for platform branches; plan-only is already exempt via the subset test. |
| 4 | Release preflight red | section 1, `release-preflight.sh` | I (ledger integrity is its job), but 1523-rxt6: it stalls 2 min on a locked keyring. |
| 5 | Derived cheatsheet tree out of sync | section 1b | I but not plan-related; fires on a plan-only push if the worktree is desynced by a merge. |
| 6 | **Scoped fresh stamp AND remote moved since last fetch** | `enforce_stamp_scope` "no usable local base" (refused BEFORE the lane is offered) | **D** — tonight's (b). |
| 7 | Scoped fresh stamp, base local, diff has `plan-ledger` and the lane declines (any D/T/M on a fragment, nested path, `plan/index.yaml`, README/TEMPLATE, non-listed `plan/` dir e.g. `plan/steps/`, `plan/issues/<other-subdir>/`) | `enforce_stamp_scope` → `attempt_plan_only_lane` → refuse "also changes: plan-ledger" | Mostly I (immutability, shared-record erasure); **D** for `plan/index.yaml` compaction and for `plan/` directories never added to the lane (every new ledger directory has had to be added one order at a time: 889-twhe, 1141-f5nk, 1507-e693). |
| 8 | Stale/never-run stamp and the lane declines for any reason in #7 | section 2 stale arms | same as #7 |
| 9 | Lane: remote base not present locally / ref new on remote / deletion | `attempt_plan_only_lane` first loop | I for new/deleted refs; the "not present locally" arm is **D** for the same reason as #6 (it is a race, remedy is fetch). |
| 10 | Lane: resolved plan binary is STALE by validator-surface hash / mtime | 1129-4su6 / 1152-y3bv / 1287-h6qn block | I (a stale validator can accept a shape current rules refuse), but the remedy is a cargo build, which the lane exists to avoid; the embedded-hash probe (1287-h6qn) makes it rare. |
| 11 | Lane: fragments present and neither yq nor a runnable plan binary | 889-twhe / 1124-7f3u fail-closed | I |
| 12 | Lane: YAML parse / `!!map` / `check --strict-fragments` rc 1 or 3 / status-loss / future ts (1313-w78k) / added-fragments-parse / scorable obligation (977-448j) / mo-full grammar / base64 ban / append-vs-origin fold (1261-bn7v, rc 3 = could-not-run refuses) | per-file and fold validators | I (these ARE the gate for plan content). Note the fold comparison's deadline refusal (rc 3) refuses a sound push on a slow host. |
| 13 | A new packet with no scorable obligation, even under a FULL fresh stamp | post-lane unconditional `check-scorable-obligation-added.sh` (1069-5sp4 second half) | I |
| 14 | Target branch FROZEN | `enforce_release_freeze` — `plan/*` exempt | plan-only never refused: I |
| 15 | Empty ref list (already up to date, or git already declined a non-ff against a current tracking ref) | exit 0 with "fetch and rebase" | I — this is the ARM 4 path and reads correctly. |
| 16 | `added-test-is-referenced` / `windows-tray-clippy` | self-scoping; no-ops for plan-only | — |

Summary for the operator's question ("we already allow plan-only without gates; how come even those fail now?"): a plan-only push from a checkout that holds a **scoped fresh stamp** goes through `enforce_stamp_scope`, not the stale arms, and `enforce_stamp_scope` has two refusals that precede the lane: the remote-moved check (#6) and, before land119, the missing-class refusal (land117, fixed by 1521-y72e). Scoped stamps did not exist until the selector activated, which is why these started failing "now".

---

## 3. Question 3 — each gate: reason, validity, and whether it can be narrower

Legend: **T** = protects trunk; **B** = protects the gate's own bookkeeping.

| Gate / refusal | Reason (order) | Still valid? | Narrower / more granular? | T/B |
|---|---|---|---|---|
| Hook §0 salvage exemption + deletion protection | 872-c9nd, 874-w2gc, 1176-9vqn markers | yes | fine | — |
| Hook 1427-r2d2 deletion-only exemption | a deletion uploads no tree | yes | fine | — |
| Hook 877-mynm empty-ref exit | measured byte counts | yes | fine | — |
| Hook §1 release-preflight | 599-4wzr (ledger integrity, version monotonicity) | yes | scope by class: a plan-only push needs only the ledger half; 1523-rxt6's 2-min stall shows it also does network work (gh) a hook should not | T |
| Hook §1b cheatsheet sync | 2026-08-16 incident | yes | run only when the diff touches `cheatsheets/` or `images/default/cheatsheets/` (today runs on every push) | T |
| `gate-stamp.sh verify` (digest of tree minus plan fast-lane paths) | 599-4wzr, 930-i6x4, 1142-85zx | yes | the exclusion list is a hand-maintained enumeration that must agree in three places (`compute`, `movers`, `gate_stamp_plan_digest`); make it one function | T |
| `enforce_stamp_scope` subset test | 765-dt8h (silent-green pivot for scoped gates) | yes — a scoped stamp must not vouch for classes it skipped | the taxonomy is coarse (`build-scripts` = 845 files including deciders, hooks, fixtures); but finer classes are only useful if the selector skips something expensive, and tonight's measurement says it does not | T |
| `enforce_stamp_scope` "no usable local base" | 765-dt8h fail-closed on "unscopeable" | **no**: it conflates "cannot classify" with "remote moved"; the remote would refuse the push anyway | replace with: refuse as a LOST RACE naming `git fetch origin` (or exit 0 and let the remote decline when `--force` is provably absent) | B |
| `enforce_stamp_scope` `[[ -z $REFS ]]` arm | 765-dt8h | unreachable (877-mynm exits earlier on empty refs) | delete | B |
| Stale-stamp arms + movers naming | 599-4wzr, 864-q7dm, 970-7fqk, 1307-kic6 | yes | fine; the live-writer hint is good | T |
| Plan-only lane qualification (per-directory, A/M/D rules) | 668-2xeh, 767-iukh, 889-twhe, 1060-7mmm, 1013-xm63, 1141-f5nk, 1507-e693, 1056-5344, 1152-y3bv | yes for immutability and shared-record append-only | the allow-list of directories is the recurring tax: every new `plan/` subdir costs an order; generalise to "under `plan/`, A anywhere; M only append-only; D never; `plan/index.yaml` only via compaction attested by `tillandsias-plan compact`" | T |
| Plan-only lane validator currency (1129-4su6/1152-y3bv/1287-h6qn) | stale validator accepts shapes current rules refuse | yes | already narrowed to the validator surface; keep | T |
| 1069-5sp4 unconditional scorable-obligation | the stamp cannot see fragments | yes | fine (self-scoping) | T |
| `enforce_release_freeze` | 1176-9vqn | yes | fine; fails open on network, plan exempt | T |
| `pre-push-no-stale-base-revert` | 1000-rqmx | yes | fine; remedy correct | T |
| `pre-push-linux-next-merged` + subset exception | 851-gpb5, 1259-kn83 | yes | the subset test already ignores `plan/`; fine | T |
| `pre-push-version-guard` | spec:versioning | yes | n/a | T |
| `pre-push-main-branch-affordance` (fail-closed on no plan binary) | 1443-sb9b | the refusal itself yes; failing closed on a MISSING BINARY for every push is a floor-host trap | when no binary, fall back to "refuse only if a ref targets refs/heads/main" | B |
| Land tool adoption `scope == full` | 1174-u5wp ("a narrower stamp could satisfy the hook for a narrow push while saying nothing about the gate this tool owes") | **partly**: the stated worry is a stamp narrower than the PUSH; the correct test is "stamp fresh AND stamp scope covers the outgoing classes", which is exactly what the hook enforces seconds later | adopt a scoped stamp whose scope ⊇ classify(diff origin/$BRANCH..HEAD) | B |
| `memo-check` `scoped-stamp-cannot-memoize-full-gate` | 765-dt8h ("the memo they need is per-class and belongs with 765-xpct") | the full gate must not be memoised by a scoped stamp, correct; but the selector now skips the SAME guards again on the next run, so the memo question for a scoped run is "same class set, same digest, same toolchain" | per-class memo as 765-dt8h anticipated; or simpler: do not write scoped stamps until adoption/memo understand them | B |
| Land tool lost-race regex | 1064-r8fv narrowing + 2026-09-06 fourth phrasing | incomplete by construction (enumerates remote phrasings, not hook phrasings) | classify by ANCESTRY the way the post-push block already does (1366-d5v2): after a failed push, fetch; if `origin/$BRANCH` is not an ancestor of HEAD it was a race, whatever the text | B |
| Land tool "not a lost race" remedy text | 1064-r8fv, macbookair 2026-09-15 | the sentence is wrong for a race the hook detected | see §4 | B |
| Land tool union-debt mandatory gate | 1056-5344 | yes | fine | T |
| 1162-qbrx step-prefix allocation | measured collisions | yes | fine | T |
| 1235-rfub native lint attestation | yes | yes | fine | T |
| Mandated merge (`pull_merge_cadence.pre_push_gate`) in the land tool | 1064-r8fv | yes for platform branches; not applicable on linux-next | the tool's exit-6 remedy still names it on linux-next (§4) | T |
| `build.sh --check` runs no litmus (748-tkjx) | hook speed vs bypass | a stated trade; tonight's (e) is its known cost | the relay lane already runs the covering litmus in `relay-preflight.sh` phase 7; the land tool could require a relay-preflight verdict for the relay branch instead of warning | T |
| Land-queue 1335-2nzf adopt | measured | yes | it is the right rule; move it to one place both tools call | T |
| Selector scoped stamps (765-xpct) | operator-approved tiers | the approval is for scope REDUCTION; tonight it reduced nothing (1183 s vs 1124–1270 s) and made the stamp unusable for adoption/memo | gate the stamp downgrade on measured saving: write `scope full` whenever every skipped guard was sub-second, or stop downgrading until adoption/memo honour scoped stamps | B |

Two 765-xpct comments deserve quoting against the measurement. `change-class.sh`: "SCOPED runs the fixtures; it drops cargo." The scoped land120 log shows clippy, `cargo test --workspace` (76 s) and the tray tests (57 s) all ran. `land-queue.sh`: "When 765-xpct lands WITH the operator's recorded decision, this script asks it for the tier." It never did; the queue still pays FULL. So the selector's only live effect on the landing path tonight was the stamp downgrade.

---

## 4. Question 4 — messages and affordances

The canonical block (SKILL.md §3 `<!-- affordance:begin -->`): *prefer work branches: git switch -c work/<order>; push there freely; open the PR with: gh pr create --base linux-next --head work/<order>; the landing queue integrates it. See ./skills/join-the-fleet §3.* The hook prints it verbatim (`work_lane_affordance`) and the land tool prints it verbatim on attempts-exhausted. Both match the skill word for word.

Refusals whose WHY or REMEDY is wrong or misleading:

1. **Hook `enforce_stamp_scope` "no usable local base to diff against"** — why: "A scoped stamp can only be honoured when the push can be classified" (true but not the cause: the remote moved since the last fetch); remedy: `./build.sh --check` (wrong; ARM 3 shows `git fetch origin && git merge origin/<branch>` lands with no gate). Should also say the stamp survives a plan-only move.
2. **Land tool `refused:land:push-failed — retrying THIS PUSH cannot help (not a lost race)`** — fires for every hook refusal, including one that IS a lost race (ARM 1, tonight). The why ("origin refused the push … it was not a lost race") is false: origin was never reached; the local hook refused. The remedy ("merge the ref the refusal below names (for a mandated merge that is origin/linux-next), re-gate, then re-run") names the mandated-merge guard on a linux-next land where it does not apply, and says "re-gate" where a fetch suffices under a full stamp (and would suffice under a scoped stamp once adoption honours it). The long paragraph that follows measures `origin/$BRANCH`'s commit rate and recommends a work ref — reasonable advice for a platform host, noise for the coordinator landing on trunk.
3. **Land tool "origin moved 9ad7cf8cb -> 9ad7cf8cb — retrying"** (ARM 4) — when the gate's own fetch already updated the tracking ref, the before/after SHAs print identical while the sentence says "moved". The decision is right (ancestry), the printed evidence contradicts it. Print the gated-on SHA instead of the pre-push read.
4. **Hook `plan-only lane: not applicable — remote base … is not present locally (full gate required)`** — same cause as 1, same wrong remedy.
5. **Land tool attempts-exhausted affordance** on a linux-next land: "push the work to work/<order> and let the landing queue integrate it" — the coordinator IS the queue; for that caller the remedy is "wait for a quiet trunk or quiesce the plan lane (SKILL.md §3 item 4)".
6. **`pre-push-main-branch-affordance.sh` `blocked:main-branch-affordance:no-plan-binary`** — why is correct, remedy is `cargo build --release -p tillandsias-plan`; a plan-only push from a floor host with no toolchain cannot follow it and the message does not name the salvage lane that the local-gate refusal names.
7. **Land tool exit-6 block's `_afford` remedy references "the ref the refusal below names"**, but when the refusal below is a hook refusal (not the mandated-merge guard) no ref is named; the reader is sent to a sentence that does not exist.

Messages that are correct: the stale-stamp arm (names content movers and the live-writer hint separately, 970-7fqk); `no-stale-base-revert` (names files, right remedy, honest about `--no-verify`); the 1521-y72e post-fix path (case 8/9 of `test-gate-stamp-scope.sh`, 10/10 measured in the worktree); `push-emitted-nothing` (names the bound); 877-mynm empty-ref exit.

---

## 5. Question 5 — proposal, smallest first

Each item: change · exit criterion as an OUTPUT a fixture can check and that FAILS on today's code · risk · Lua candidacy. All fix forward. 1443-u66u (land tool rewritten as `scripts/lua/land-on-platform-branch.lua`, verdict tokens byte-identical) is already filed; items 2 and 4 should land in the `.sh` now and carry over as behaviour the port must keep.

**1. Hook: the remote-moved refusal says what it measured.** `enforce_stamp_scope` and the lane's "remote base … not present locally" arm: when `! git cat-file -e "$remote_sha"`, refuse with a new token line `refused:pre-push:remote-moved-since-fetch:<remote_ref>:<remote_sha>` (stderr why: "origin advertised a tip this checkout has never fetched, so the push cannot fast-forward; the stamp was not consulted"; remedy: `git fetch origin && git merge origin/<branch>`, "a plan-only move keeps a fresh stamp fresh"). Keep the refusal (do not exit 0: the hook cannot see `--force`). · Fixture: scratch origin + second clone pushes a fragment after the stamp is written; `git push` output contains `refused:pre-push:remote-moved-since-fetch:` and does NOT contain `Re-run the full gate` — pre-fix prints "no usable local base … ./build.sh --check" (FAILS, measured ARM 3). · Risk: nil; the push was refused either way. · Lua: no — four lines in a bash hook; porting the hook is 1443-sb9b-class work.

**2. Land tool: classify a failed push by ancestry, not by text.** In the `rc -ne 0` block, before the lost-race regex, add the hook token from (1) to the race set; better, replace the regex gate with the ancestry test the post-push block already uses: `git fetch`; if `! git merge-base --is-ancestor origin/$BRANCH HEAD` → it was a race, retry. Also fix the exit-6 why/remedy so the mandated-merge sentence is printed only when `BRANCH != TRUNK`. · Fixture: extend `test-land-push-classification.sh` with ARM 6: scoped stamp, origin moves mid-gate, no fetch; assert the tool prints `origin moved … — retrying` and lands on attempt 2 — pre-fix exits 6 with "not a lost race" (FAILS, measured ARM 1). · Risk: a genuine non-retryable refusal on a moved trunk is retried once more (bounded by attempts). · Lua: the classifier (`rc`, push text, `origin-before`, `origin-after`, ancestry) is a pure decision and a good first module for 1443-u66u's port (`verdict.classify` already exists in `script_run.rs`); do the bash fix now, port the decision table with the tool.

**3. Land tool: adopt a scoped stamp when its scope covers the push.** In the 1174-u5wp block: `_ss = full` → `_ss = full || scope_covers(_ss, classify(git diff --name-only origin/$BRANCH..HEAD))`, reusing `gate-stamp.sh classify` (one taxonomy, as `change-class.sh` and `land-queue.sh` insist). Print `ok:land-adopts-valid-stamp:<stamped>:scope=<scope>`. · Fixture: `test-land-adopts-valid-stamp.sh` NC arm 3 currently asserts a narrower-scope stamp is NOT adopted; split it: scope `build-scripts` with an outgoing diff of `scripts/x.sh` → ADOPTED; scope `build-scripts` with a diff touching `crates/` → not adopted. First arm FAILS pre-fix (`ADOPTED=[]`, measured by the existing NC arm). Plus the integration arm from (2): gate-count stays 1 after a plan-only move under a scoped stamp (pre-fix 2, measured ARM 1/ARM 4). · Risk: the hook re-verifies the same stamp and scope seconds later, so adoption can grant nothing the hook would refuse; the union-debt veto stays. · Lua: yes, with (2) — the same classify call.

**4. One trunk-delta classifier for both landers.** Extract `land-queue.sh`'s 1335-2nzf block into `scripts/trunk-delta-classify.sh <gated-on> <now>` printing `ok:trunk-delta:plan-only` / `refused:trunk-delta:classes=<csv>` / `could-not-run:trunk-delta:unreadable`; the queue and the land tool both call it; the land tool uses it to say in the retry line WHY it adopts ("trunk moved by plan-ledger only"). · Fixture: both tools' fixtures assert the token appears in their output; `test-land-queue.sh` ARM 10a keeps passing; pre-fix the land tool prints no such token (FAILS). · Risk: low; pure refactor plus one line of output. · **Lua: the best candidate in this list** — a `scripts/lua/trunk-delta-classify.lua` with `proc.run{argv={"git","diff","--name-only",a,b}}` and a `gate-stamp.sh classify` call (keep the taxonomy in one place until gate-stamp itself is ported), header-declared env, typed verdict; it is exactly the "small decider with one output line" shape 1384-ddua ported.

**5. Selector: do not downgrade the stamp for a saving that was not measured.** In `build.sh` `_write_gate_stamp`: write `scope full` unless the skipped guards' recorded durations (the per-step timing records already exist, 758-jw6v) sum above a floor (say 60 s), and print `skip:class-selector:…` lines as today. Alternatively gate the downgrade on `TILLANDSIAS_SCOPED_STAMPS=1` until (3) lands. · Fixture: `test-change-class.sh` arm: a SCOPED run whose skipped guards were all sub-second writes `scope full`; pre-fix writes `scope build-scripts,…` (FAILS). · Risk: the stamp claims `full` for a run that skipped sub-second guards — those guards are by construction the ones the selector judged irrelevant to the diff, and the memo path then re-runs them on the next ledger move anyway; still, this is a bar decision and should be recorded as a ruling. · Lua: no.

**6. Generalise the plan-only lane's directory list.** Replace the per-directory arms with one rule over `plan/`: A anywhere under `plan/` except `plan/index.yaml`; M only when append-only (the existing `git diff … | grep '^-'` test) and the file is not `plan/index.yaml`; D/T never; `plan/index.yaml` changes only when the push also deletes the fragments it folded and `tillandsias-plan check --strict-fragments` passes (compaction). Keep every validator as is. · Fixture: a new `plan/<new-dir>/<file>.md` added pushes through the lane; pre-fix refuses "outside plan/index.d/, …" (FAILS). · Risk: a new `plan/` directory with build-affecting content would ride the lane; the stamp digest already excludes only the four known sets, so such a file STILL stales the stamp — the lane admits it only when the stamp is otherwise fresh or absent; acceptable, but record it. · Lua: the qualification decision (status, path, append-only) is a clean port candidate later; the validators stay as they are.

**7. Drop or demote the hand-run launch-time ancestry check (c).** If the coordinator's procedure checks `is-ancestor origin/linux-next HEAD` before `land`, delete it from the procedure: the tool merges at attempt start. · Exit criterion: a land launched with trunk one plan-only commit ahead of the relay branch lands on attempt 1 with one gate (it does today — this is a procedure change, not a code change, so no fixture fails; the evidence is the timing log showing no second relay-preflight per land). · Risk: nil.

**8. (Optional, bigger) relay-preflight verdict as the land's litmus evidence.** The 1201-9it2 advisory could become "refuse unless a `relay-preflight` timing record exists for this exact HEAD within N minutes", closing (e) for relay lands only. · Fixture: a land of a relay HEAD without a preflight record prints `refused:land:no-relay-preflight-for-head`; pre-fix it prints only the NOTICE (FAILS). · Risk: makes the relay lane mandatory for every linux-next land; the operator's "migration not enforcement" ruling applies; needs a ruling.

Ordering rationale: (1)+(2) fix tonight's misclassification and cost nothing; (3)+(4) remove the full re-gate for plan-only moves under scoped stamps and unify the two landers; (5) stops minting the stamps that caused this until they are useful; (6)–(8) are the structural follow-ups.

---

## 6. What I could NOT verify

- **Which check failed at land115's launch (c).** No script refuses on launch-time ancestry for linux-next; I infer a hand-run step from CLAUDE.md's coordination notes and the two relay-preflights in the timing log. The coordinator's transcript would settle it.
- **The exact stamp on the checkout at land120.** `.git/tillandsias-gate-stamp` no longer exists in the checkout (only the manifest), so the scope `build-scripts,specs` is taken from the refusal text in the facts, and the mechanism (`_CLASS_SKIPPED>0` → `_stamp_scope=$_CLASS_SET_MEMO`) from `build.sh`. The hermetic ARM 1 reproduces the refusal byte-for-byte with scope `build-scripts`.
- **Whether anything fetched `origin/linux-next` during land120's gate.** `build.sh` contains no `git fetch`; the measured refusal text ("no usable local base") is consistent with no fetch. ARM 4 shows the other branch lands in a re-gate rather than exit 6.
- **The five ~1 s `build-check … exit 1` records tonight** (22:03:02, 23:53:40, 02:26:16, 03:02:26, 03:36:36Z), each ~2 min after a 0.5 s memoised run and ~25 min before a green 1200 s gate. The per-attempt logs were overwritten; I did not determine what refused in one second. If it is `check-no-competing-gate` refusing because relay-preflight's litmus phase was still running, that is a second collision class worth a look.
- **Whether `proc.run` is registered under `tillandsias-plan script run`** (as opposed to `tillandsias-plan lua`): `script_run.rs` builds its environment via `lua_predicate::build_environment(class)`, which defines `proc.run` (1384-aixy slice 1); availability may depend on the script's declared class. Proposal 4's Lua form assumes it is.
- **1335-2nzf's "same rule read from one place" closure claim.** The row is `completed`; the queue has its own classifier and the land tool none. I did not find the shared source the closure text promised.
- The `test-land-queue.sh` fixture was not run (it drives `gh` through a seam; I stayed inside the no-gh limit). `test-gate-stamp-scope.sh` 10/10, `test-land-adopts-valid-stamp.sh` 7/7, `test-land-push-classification.sh` 9/9 were run in the detached worktree.

## 7. Method notes

- Worktree: `/home/tlatoani/claudia/wt-fable` (detached at 2b299347d), removed after use. Scratch repos under `/home/tlatoani/claudia/wt-fable-scratch`, removed after use. Experiment driver `exp-b.sh` (arms 1–3) and `exp-b4.sh`/`exp-b4b.sh` (arm 4): scratch bare origin; clone A with the real `gate-stamp.sh`, `plan-binary-probe.sh`, `land-on-platform-branch.sh`, `hooks/pre-push-local-gate.sh`; clone B as the other host; a stub `build.sh` that, on its first run, pushes one `plan/index.d` fragment from B and then mints the pass token and writes the stamp with the arm's scope exactly as `_write_gate_stamp` does.
- Timing figures are from `.cache/metrics/tillandsias-timing.jsonl` (`build-check` and `relay-preflight` steps, 2026-09-30/10-01).
