# Git branching methodology — research record & decision (2026-07-28)

- **Class**: research/ (decision record; spawns methodology rung 1 + implementation packets, orders 497-504)
- **Provenance**: operator directive, The Tlatoani, 2026-07-28; researched, designed, adversarially reviewed, and synthesized 2026-07-28 against origin/linux-next 05fff9d6. Red-team verdict: **adopt-with-repairs** (10 mandatory repairs, all applied below).
- **Status**: ADOPTED. Rung 1 codified in `methodology/multi-host-development.yaml` (`branch_namespaces`); rungs 2-4 packet-gated.

## 1. Operator directive (context)

linux-next/windows-next/osx-next are Tillandsias-specific integration branches where final code must end up; `main` is now branch-protected (PR-only, enforce_admins, applied 2026-07-28, order 476). In-forge agents should experiment and commit freely on a neutral working-branch layer, then push SELECTIVE merges into the real integration branches. Git-mirror checkouts may get a per-lane branch to avoid collisions. Formalize the salvage case: an agent blocked by the main guard pushes a temporary branch; the merge is dealt with later. The branch methodology must be TRANSPARENT to end users. Constraints: Rust/POSIX sh only; ephemerality+idempotency; enclave isolation and credential quarantine inviolable; the mirror is the only in-forge push channel.

## 2. Load-bearing verified facts

- The relay is refname-agnostic: `images/git/relay-refs.sh:41-50` builds refspecs from raw receive-pack stdin and pushes `--atomic` (`:168`); any ref relays verbatim. Namespace routing = a `case "$REFNAME"` in two POSIX-sh scripts.
- Validation is refname-blind: the ledger-YAML gate (`images/git/pre-receive-hook.sh:151-203`, `is_ledger_yaml` `:88-98`) applies to every ref. A salvage push of a half-edited tree is rejected today.
- Every accepted push is synchronously public on GitHub (`pre-receive-hook.sh:218-221`); pre-receive rejects ALL refs when the relay fails, so mirror+GitHub dual-ref pushes through one receive-pack are genuinely atomic.
- Mirror HEAD is global and sticky (entrypoint sets it only volume-fresh; `ensure-mirror-head.sh:36-38` exits 0 when HEAD resolves) — a persisted volume can check out branch Y after the launch gate passed on branch X.
- `find_diff_base` falls back to `refs/remotes/origin/HEAD` then hard-coded `origin/linux-next` (`pre-receive-hook.sh:117-133`) — the order-462 convention-leak class to not repeat.
- Empirics: ~33 commits/day on linux-next, 21 forge pushes/night, 0 unmerged platform branches (verified this session: osx-next 89cade75 and windows-next 91ab1f8f both ancestors of linux-next). Side branches rot to provenance-only in <24h (`agent/result-channel-repair-20260723`, plan/index.yaml:19807-19819). Order-number collisions cluster where ledger landing was delayed (462→464 ff0bb5f6; 477→479 8cedfce8; 478/479→486/487 index.yaml:21927-21936). plan/index.yaml is a 23k-line single-file merge surface with prior corruption (0f904715) and a wholesale-reserialization breach (34e60965). CCR branch-scoped ledger claims were invisible (plan/issues/ccr-branch-scoped-ledger-claims-invisible-2026-07-06.md).

## 3. Models considered (compact)

| Model | Verdict | One-line reason |
|---|---|---|
| Trunk-based dev | KEEP as spine | It IS the proven status quo (velocity, 0-unmerged equilibrium); lacks only an isolation tier |
| Kernel topic/next | Adopt graduation semantics only | Selective merge is native, but human-maintainer latency ⇒ institutionalized stranding at 33 commits/day |
| bors/merge-queue | Adopt landing-rule only | "Merge only what's green on the merged tree" + sweep-as-serialization-point; full queue adds latency |
| Gerrit | Adopt ref-routing trick only | Server-side namespace routing fits the sh relay; product (Java, amend-based) violates stack + never-rebase rules |
| GitHub flow (per-change PRs) | REJECT (keep only for →main) | PR hop per change reintroduces CCR-class ledger invisibility at 21 pushes/night |
| git-flow | REJECT | Long-lived develop doubles index.yaml 3-way exposure; release ceremony vs daily releases; nvie's own retraction |
| Stacked diffs | REJECT | Restacking = rebasing published commits (cb9def48→6dbca259 scar); ephemeral lanes can't hold stacks |

## 4. Recommendation

**Do not move routine work onto working branches — trunk-based checkpoints are the asset to protect.** Every recorded coordination failure (CCR invisibility, order-collisions, salvage rot) was caused by work sitting on unmerged side branches. Add an **exception tier**: auto-seeded per-lane branches for forge work and a salvage namespace for stranded work, with a self-merge-when-green exit and a coordinator sweep guaranteeing nothing strands. `main` promotion stays PR-only, untouched.

## 5. The scheme

### 5.1 Namespaces and grammar

Reserved (unchanged): `main`, `linux-next`, `windows-next`, `osx-next`, `gh-pages`, `release/*`. Tolerated external: `claude/*` (CCR), `revert-*` (GitHub UI). New:

- **Lane branches** (auto-seeded, agent-transparent): `agent/<host>/<base>/<yyyymmdd>-<slug>`; `<base>` = integration branch the lane was seeded from — the sweep derives the merge target mechanically from the refname. **Slug is MANDATORY and launcher-synthesized: `<mode>-<instance>-<launch-epoch>`, never reused** (red-team B1: `TILLANDSIAS_FORGE_INSTANCE` is empty by default and stable per worker, main.rs:4237-4253; same-day relaunch of a blocked worker would collide nightly without the epoch). Launcher lowercases host names (W7).
- **Salvage branches**: `salvage/<host>/<yyyymmdd>-<slug>`. No `<base>` — the target is a triage decision (matches the `agent/result-channel-repair-20260723` precedent).

Falsifiable creation-policy regex:

```
^refs/heads/(main|gh-pages|(linux|windows|osx)-next|release/[A-Za-z0-9._/-]+|revert-[A-Za-z0-9-]+|claude/[A-Za-z0-9._-]+|agent/[a-z0-9][a-z0-9-]{0,31}/[a-z0-9][a-z0-9._-]{0,47}/20[0-9]{6}-[a-z0-9][a-z0-9-]{0,47}|salvage/[a-z0-9][a-z0-9-]{0,31}/20[0-9]{6}-[a-z0-9][a-z0-9-]{0,47})$
```

`<base>` is a generic pattern, never an enum of Tillandsias names — hook CODE stays convention-neutral; patterns reach it via config (do not repeat pre-receive-hook.sh:127). Bases containing `/` (`release/*`) substitute `-` and record the true base in the ledger claim (W7). Grammar applies to zero-oldsha creations only; the ~11 legacy refs are grandfathered pending the rung-1 census. Enforcement: warn rung 2, reject rung 4.

### 5.2 Lane-branch seeding (transparent)

- **Launcher (Rust)**: inject `TILLANDSIAS_FORGE_SEED_BRANCH` (host checkout branch, already computed by `read_host_project_current_branch` main.rs:2695-2734 — today passed only to the MIRROR as `TILLANDSIAS_PROJECT_DEFAULT_BRANCH`, main.rs:2886) and `TILLANDSIAS_FORGE_LANE_BRANCH` into the forge env (main.rs:4869-4924); add `push.default = current` to `write_forge_gitconfig` (main.rs:7553-7614) so bare `git push` targets the lane with zero agent awareness.
- **Guest (`clone_project_from_mirror`, lib-common.sh)**: seed+lane logic lives in the COMMON TAIL so network (:606), Windows/WSL filesystem (:522), and macOS staged transports all get it (B6 — the network-branch-only patch left Windows with sticky-HEAD and no lanes). Seed with a fallback chain: clone default → `git fetch origin <seed>` → switch if present → warn + use HEAD (B6: hard `-b` fails for never-pushed branches and inside the 120s reconcile window, entrypoint.sh:226). Then `git switch -c "$TILLANDSIAS_FORGE_LANE_BRANCH"`. Caveat documented: reused (not recreated) containers carry creation-time env — stale seeds are possible until recreate.
- The lane ref materializes on mirror+GitHub only at the first real checkpoint (post-462 pre-receive validates the diff vs merge-base; relay creates the branch atomically). Zero-commit lanes never pollute the remote. The seed-branch clone fix alone kills the sticky-HEAD hazard and ships standalone (order 501).

### 5.3 Integration cadence + no-stranded-work guarantee

**Green exit = self-merge, one atomic dual-ref push, via one sanctioned command `scripts/lane-exit.sh`** (W1 — the ONLY green-exit path): fetch base; merge base into lane (merge-only); verify; `git merge --no-ff <lane>` on base; `git push origin <lane> <base>` (relay `--atomic` ⇒ lane tip + integration merge land as one transaction); delete lane (`git push origin :<lane>`, under the bulk-delete guard relay-refs.sh:57-60). No approval hop, no queue: latency vs today ≈ one merge commit — this protects the 33/day, 21/night velocity and the exit contract's anti-velocity-killer clause. Self-merge "green" = conflict-free merge + fast tier (`./build.sh --check`); the full tier is owned by coordinator/CI on the base (W6 — a full `--test` re-run does not fit the 600s forge envelope). When `<base> != linux-next`, lane-exit and ledger-checkpoint merge `origin/linux-next` first (B5, preserves pre_push_gate intent); `pre_push_gate.applies_to` is amended to exclude `agent/*`/`salvage/*` (B5 inverse — a mid-cycle lane checkpoint must not require a trunk merge).

**Blocked/timeout exit** = lane PUSHED (durable on GitHub — satisfies "no local-only commits") + a blocker ledger entry on the base ref recording lane name + tip SHA. Degradation documented (W8): if base pushes themselves are the blocker, visibility degrades to sweep enumeration.

**Coordinator backstop**: bound to the coordinate-multihost-work ROLE, any host may run it (W2 — merge-only landings are idempotent/hash-preserving, so a second lander converges; `race_exception` multi-host-development.yaml:166-173 holds). Enumerate `agent/*` + `salvage/*`: fully merged into named base → delete; unmerged idle >24h → sweep-merge if trivially green else file/refresh a salvage packet; >72h → operator escalation; >14d → archive tag `archive/<branch>-<tipsha>` then delete. **Loop_status prints the unmerged-lane count EVERY run** (W1), and minimal lane enumeration ships with rung 3, not rung 4 (W5). Guarantee: every commit either lands on base at green exit, or survives as a pushed durable branch with a ledger pointer, and the sweep drains/archives on deadlines — GC never deletes without an archive tag.

### 5.4 Selective-merge rules

Default `git merge --no-ff` lane→base by the owning agent. Lanes are published on first relay ⇒ never rebase/force-push a lane (relay pushes without `--force`; GitHub rejects anyway). Selective adoption (lane has junk + one good fix): branch a topic off `merge-base(lane, base)`, extract via `git checkout <lane> -- <paths>` or `git cherry-pick -x <shas>`, merge topic→base, and **retire the lane in the same operation** (archive-tag + delete). Cherry-pick is allowed ONLY with `-x` AND simultaneous lane retirement — the duplication hazard bites only when both copies live on mergeable branches. Conflict ownership: owning agent for its self-merge; coordinator for sweeps, salvage, cross-host.

### 5.5 plan/ ledger call — ledger stays on integration branches (the hard call)

**Lanes are code-only for shared ledger state: `plan/index.yaml`, `plan.yaml`, `plan/loop_status.md`, `methodology/**` ride integration branches directly. Lanes MAY add new append-only files under `plan/issues/`.** Argument (red-team concurred, "the collision evidence is on the scheme's side"): (a) order minting is a read-modify-write global counter, not a CRDT — 4 collisions in one week even with prompt landing; delaying landing widens the window (478/479 double-mint via unintegrated windows-next is that failure, already observed); (b) deferred claims break MOT-02 and generalize the CCR invisibility class; (c) the 23k-line index has corrupted under merge interleave (0f904715) — multiplying concurrent forks of it is what the 34e60965 forensics warns against; (d) loop_status.md is last-writer-wins, unmergeable. Mechanization: `scripts/ledger-checkpoint.sh` (POSIX sh) — tmpfs `git worktree add` on `origin/<base>`, apply ledger edit, commit, push with 3-retry fetch/reapply; claim events record lane name + tip SHA for code↔claim provenance. Mechanical enforcement (rung 4): for `agent/*` refs, pre-receive rejects diffs touching the ledger path list — **computed against `merge-base(NEWSHA, refs/heads/<base-from-refname>)` (three-dot semantics), never `OLDSHA..NEWSHA` and never the default-branch heuristic** (B2 — the naive diff rejects every cycle-end push once trunk moved, and lane creation off an unmerged platform branch would police foreign ledger commits). **Policy source: launcher-injected env or the base ref's committed tree, never the pushed tip** (W4 — else a lane commit lifts its own ban). Path lists via config, not hard-coded (project neutrality). Long-term relief flagged, out of scope here: `refs/tillandsias/leases/*` non-branch lease refs (relay handles arbitrary refnames already) + order-474 push-pipeline FSM as the atomic order-mint attachment point.

### 5.6 GC and mirror hygiene

TTL sweep as in 5.3. **Sibling-mirror prune (B7)**: the 120s reconcile imports all upstream heads with no `--prune` (reconcile-exported-heads.sh:37), so swept lanes would accumulate on every host's mirror forever, leak into every fresh forge clone, and break zero-oldsha grandfathering. Repair: reconcile prunes, scoped to the configured lane/salvage patterns only — safe by construction (with a remote configured, pre-receive never accepts a head that wasn't relayed, so a namespace head absent upstream can only be swept). The sweep additionally REPORTS (never deletes) out-of-grammar strays (W7 — host-created strays never traverse the mirror, so the grammar cannot fix that class; visibility can). Archive tags use the `archive/` prefix; tags don't pollute mirrors (reconcile fetches heads only, `--no-tags` entrypoint.sh:148-149); annual archive-prune rung noted.

### 5.7 Salvage intake (incl. the pending macOS case)

- **Who names**: the pushing (blocked) agent, `salvage/<host>/<yyyymmdd>-<slug>`; coordinator may rename on adoption.
- **Main-guard case (B3 respecified — the operator's named case)**: NEVER pre-reject `refs/heads/main` in the hook — the hook ships to EVERY end-user mirror (entrypoint.sh:156-162) and an unconditional fast-fail would brick ordinary end-user pushes to unprotected `main` (a transparency catastrophe). Instead, detect GitHub's protection rejection in the relay's captured error output (relay-refs.sh:174-175) and print the advice on THAT path: "protected branch — push `HEAD:refs/heads/salvage/<host>/<date>-<slug>` instead". Fully neutral, zero-config.
- **Gate-skip (B4)**: `salvage/*` skips `is_ledger_yaml` via a config-supplied exempt pattern — salvage must accept half-edited invalid trees (the 462-class precedent, index.yaml:22157-22169) or the blocked agent is back to host-side podman/format-patch, the workflow this scheme retires. Validation re-runs at graduation/merge. The YAML-gate litmus (litmus-git-mirror-yaml-gate-shape) must pin the routing case or the next hook refactor silently re-gates salvage.
- **Lifecycle**: merged → delete; idle >24h → salvage packet (owner coordinator); >72h → operator; >14d → archive-tag + delete.
- **Pending macOS case**: the operator's v0.5-validation OpenCode forge on a macOS host (plan/issues/forge-agent-branch-selection-clarification-2026-07-28.md) inherits the host checkout's branch; if that is `main` it fail-closes twice (order-476 guard + server protection). Any temporary branch it pushes is intaken under this procedure — adopt/rename to `salvage/<host>/…`, coordinator triages, selective merge-only landing into osx-next or linux-next, archive-tag + delete. Until rung 2 ships the relay advice, the manual command is `git push origin HEAD:refs/heads/salvage/<host>/<date>-<slug>` through the mirror.

## 6. Red-team repairs applied (all 10 mandatory + P3s)

| ID | Break | Disposition | Rung |
|---|---|---|---|
| B1 | Lane-name collision on same-day relaunch | Mandatory launcher-synthesized slug `<mode>-<instance>-<launch-epoch>`, never reused | 3 |
| B2 | Ledger path-policy diff wrong two ways | Three-dot merge-base vs base-from-refname; never OLDSHA..NEWSHA / default-branch heuristic | 4 |
| B3 | main pre-reject bricks end-user repos | Advice on relay-failure path only; never pre-reject | 2 |
| B4 | Salvage still YAML-gated | Config-supplied gate-exempt pattern for `salvage/*`; re-validate at graduation | 2 |
| B5 | pre_push_gate conflict both directions | applies_to excludes lanes; lane-exit/ledger-checkpoint merge linux-next first when base differs | 1 |
| B6 | `-b` clone hard-fails; one-of-three transports | Fallback chain; seed+lane in common tail; stale-env caveat | 3 |
| B7 | Sibling mirrors accumulate dead lanes | Namespace-scoped prune in reconcile | 4 |
| W1 | Two-phase green exit weakens loud-failure | Single `lane-exit.sh`; unmerged-lane count in loop_status every run | 3 |
| W2 | Sweep SPOF on linux_mutable | Sweep bound to coordinator ROLE, any host | 1 |
| W3 | Default-on leaks lanes into end-user repos | Default-on keyed to project opt-in, never global | 4 |
| W4 | Policy self-bypass via pushed tip | Policy from env / base-ref tree | 4 |
| W5 | Rung-3 lanes without backstop | Minimal enumeration ships with rung 3 | 3 |
| W6 | Cycle-end verify blows 600s envelope | Green = conflict-free merge + `--check` fast tier | 3 |
| W7 | Grammar nits | release/* base fallback; lowercase host; stray reporting | 1/4 |
| W8 | Blocker entry rides blocked channel | Documented degradation to sweep enumeration | 1 |

Recorded designer-vs-research conflict: research proposed a `wip/` namespace with wholesale gate-skip; design narrowed to `agent/` (gated) + `salvage/` and initially dropped the skip; red-team proved the skip is load-bearing for salvage. Final: design's grammar (base-encoding enables the mechanical sweep) + B4's skip restored for `salvage/*` only; `agent/*` stays YAML-gated. Research's lease-refs idea survives as flagged follow-up, not in these rungs.

## 7. Migration rungs (smallest first; rung 1 changes zero behavior)

1. **Doc-only** (order 499): `branch_namespaces` in methodology (shipped with this record); salvage intake incl. macOS case; pre_push_gate applies_to amendment (B5); sweep-role text (W2); dead-ref census + operator-approved archive-tag-then-prune of ~11 legacy refs.
2. **Hook, warn-only** (order 500): grammar warning on zero-oldsha creations; relay-failure protected-branch advice (B3); `salvage/*` YAML-gate exemption via config (B4); YAML-gate litmus extended to pin routing.
3. **Opt-in lane seeding** (orders 501-502): seed-branch clone fix standalone (sticky-HEAD, all transports, B6); launcher env + slug (B1); `push.default current`; `git switch -c`; `lane-exit.sh` (W1); `ledger-checkpoint.sh`; exit-contract text; minimal enumeration (W5).
4. **Default-on + enforce** (orders 503-504): keyed to project opt-in (W3); `agent/*` ledger path policy (B2, W4); reject-on-create grammar; coordinator sweep/GC + reconcile prune (B7) + stray reporting (W7).
5. **(optional, operator call)** extend lanes to host-side sessions; platform branches keep direct-commit discipline regardless.

## 8. Protection / rulesets

- `main`: unchanged (enforce_admins, PR-only; guard `scripts/check-committable-branch.sh` @ dc35960b).
- `linux-next|windows-next|osx-next`: ONE GitHub ruleset — restrict deletions + block force pushes, nothing else (status checks / PR requirements would attack the pre_push_gate cadence and the 0-unmerged equilibrium).
- `agent/**`, `salvage/**`: no GitHub rules (force-push already impossible via relay; deletion under the bulk-delete guard). GC authority = the sweep.
- NO GitHub creation-restriction ruleset for names — it would brick `claude/*` and `revert-*` emergency flows. Name policy lives in the mirror pre-receive where the message can teach.

## 9. Residual risks

1. Atomic order-number reservation is unsolved by ANY branch scheme — needs the out-of-band allocator (provisional_id + eventually lease refs / order-474 FSM).
2. Dual-ref atomicity holds only through one receive-pack — host-side direct-to-GitHub pushes are non-atomic; lane-first ordering bounds the damage to an unmerged-but-durable lane.
3. Landing-time ledger writes mitigate but do not shrink the 23k-line index merge surface; if lane volume grows, sharding the ledger becomes forced.
4. Archive-tag census growth — bounded by `archive/` prefix + annual prune.

## 10. OPEN QUESTIONS for the operator

1. Approve the one-time archive-tag-then-prune of the legacy dead remote refs (audit, methodology-refinements, local-backup-20260620, wsl-on-windows, claude/*, stale release/*, revert-antigravity-main-push, agent/result-channel-repair-20260723)?
2. Confirm sweep deadlines (24h merge-or-packet / 72h escalate / 14d archive+delete) or adjust?
3. Approve the `*-next` GitHub ruleset API call (no-delete + no-force-push only)?
4. Rung-4 default-on scope: Tillandsias auto-opt-in confirmed; foreign projects opt-in only (W3) — agree?
5. Rung 5 (host-side session lanes, e.g. CCR): wanted at all?
6. Order-number minting follow-up (lease refs / landing-train allocator): schedule now or defer?