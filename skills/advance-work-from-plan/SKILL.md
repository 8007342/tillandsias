---
name: advance-work-from-plan
description: Discover, claim, implement, checkpoint, and complete units of work from the shared plan ledger based on host capabilities and lease rules, complementary to multihost-orchestration.
---

# Advance Work From Plan

This skill is the recurring scheduled execution loop for worker agents. It allows any agent on any host to autonomously select, claim, implement, checkpoint, and complete shaped work from the shared `plan/` ledger — sustaining development velocity and enforcing finite-time convergence.

---

## 1 — Orient & Discover Environment

1.  **Git Check**: Run:
    ```bash
    git fetch origin
    git checkout <active-branch>  # linux-next, windows-next, or osx-next per host table
    git pull --ff-only origin <active-branch>
    scripts/check-committable-branch.sh
    git merge --no-edit origin/linux-next   # platform branches: BEFORE §2.0, not only before push
    ```
    The last line is the executable Committable Branch Guard (order 476,
    pinned by `litmus:committable-branch-guard-shape`): it prints one verdict
    line and exits `0` only when HEAD is on a committable branch (any named
    branch except `main`). On `blocked:committable-cycle-on-main` (or any
    other `blocked:*` verdict — detached HEAD, non-repo) do NOT claim,
    commit, or push anything this cycle: `main` advances only via PR
    (breach record 34e60965,
    `plan/issues/main-branch-direct-push-guard-2026-07-24.md`). Switch to
    your host's canonical branch or run the cycle read-only.

2.  **Instrument check**: `scripts/cycle-preflight.sh` must answer `ok:` before
    you select work — selecting with an unverified instrument is the one
    failure the loop cannot reason its way out of, because the tool it would
    reason WITH is the stale thing. Its `<plan>` segment names which instrument
    you are running on (order 1004-ws5q):

    - `rebuilt` — cargo present, instrument built or confirmed current.
    - `existing` — **no cargo, but a runnable binary resolved.** A legitimate
      cycle: a host doing compile-free work keeps its slot. Before 1004-ws5q
      preflight declared the COMPILER absent without ever looking for a
      BINARY, and a floor-tier release smoke that compiles nothing lost a 4h
      slot with a healthy instrument on disk (pirria, 2026-09-04).
    - `skipped` — the build step was skipped via `CYCLE_PREFLIGHT_SKIP_BUILD=1`.
    - `blocked:preflight:plan:cargo-absent` — no cargo AND no runnable binary.
      Terminal: there is no instrument, so do not start the cycle.

    **`CYCLE_PREFLIGHT_SKIP_BUILD=1` is for compile-free work on a host that
    cannot compile, and nothing else.** It is not a way past a red build on a
    host that can compile — that is a broken instrument. Since 1004-ws5q a host
    with no cargo but a working binary gets `existing` without the variable, so
    needing it at all should now be rare.
    **On `osx-next` / `windows-next`, merge `origin/linux-next` HERE, before the
    selector runs, not only before the push.** The selector and every
    `plan_*` read answer from the WORKTREE ledger, and on a platform branch the
    worktree is current only after that merge: between the pull and the merge
    it still carries the trunk's state as of your last merge. MEASURED on
    tlatoanis-macbook-air 2026-09-04: `osx-next` was up to date, the selector
    returned 1001-q3zf as its p1 top pick, `plan_status` agreed it was `ready`,
    and the host claimed it — a packet the coordinator had closed on the trunk
    an hour earlier. The post-merge fold exposed it, the unpushed claim was
    dropped, and the re-run selector returned a different batch. This is the
    same ordering rule the meta-orchestration skill states for the overlap
    check ("AFTER THE MERGE, NOT BEFORE"), applied to selection. The pre-push
    merge (§6) still applies; this is the earlier one.
1b. **Snapshot the startup boundary NOW — before any guard that writes.**
    Right after the pull and the branch guard, before the credential guard,
    the daily-maintenance body, the capability-row republish, the opsx sync,
    or any edit:
    ```bash
    boundary_dir="$(mktemp -d "${TMPDIR:-/tmp}/meta-orchestration-boundary.XXXXXX")"
    scripts/meta-orchestration-worktree-guard.sh snapshot "$boundary_dir"
    ```
    `scripts/finalize-cycle.sh` (§7) refuses without it, and the fleet
    heartbeat reads a host that commits without attesting as WEDGED. The
    order is the whole rule, learned three times on 2026-09-04: yoga landed a
    cycle unattested because no snapshot was taken; lenovinha and yolanda
    snapshotted AFTER a preamble guard had already written a fragment (a
    capability row), so the guard's baseline carried their own dirt and the
    finalize verify refused, correctly. A boundary taken after the work is
    the "compare a tree against itself" proof the guard exists to forbid —
    never re-snapshot to obtain a marker; report the cycle as
    landed-but-unattested and take the boundary first next time.
2.  **Host and Identity**: Identify your platform (`linux`, `windows`, `macos`, `forge`), your agent name, and your intended capabilities (`rust`, `podman`, `docs`, `testing`, etc.).
3.  **Host Detection Table**:
    | uname/$OS / env | Platform Name | Canonical Branch |
    |-----------------|---------------|------------------|
    | Inside Forge    | `forge`       | `linux-next`     |
    | Linux           | `linux`       | `linux-next`     |
    | macOS           | `macos`       | `osx-next`       |
    | Windows         | `windows`     | `windows-next`   |
4.  **Create Agent ID**: Do NOT hand-compose it — call the canonical helper
    (order 756-hn3a; contract: `methodology/distributed-work.yaml` →
    `agent_identity_contract`):
    ```bash
    agent_id="$(scripts/agent-identity.sh id <backend>)" || exit 1   # backend: claude|codex|opencode|gemini
    ```
    It resolves `<platform>-<workstation>-<backend>-<utc-timestamp>` from
    stable sources (TILLANDSIAS_AGENT_ID taken whole; else
    TILLANDSIAS_WORKSTATION → HOSTNAME → /etc/hostname → node-name probe),
    sanitizes once, and REFUSES (`refused:agent-identity:empty-<component>`,
    non-zero, empty stdout) instead of minting an incomplete ID. On refusal
    do NOT claim, append, or push anything — a prose recipe on a
    hostname-less forge wrote lease `forge--codex-20260815t162555z` (EMPTY
    workstation) while HOSTNAME sat unread in its environment.
5.  **Orient via MCP — do NOT read whole ledgers.** This is a rule, not a
    suggestion. Canonical: `methodology/distributed-work.yaml` →
    `mcp_first_read_path`.

    The files this step used to tell you to read are `plan/index.yaml` (31,678
    lines), `plan/loop_status.md` (7,875 lines), `plan.yaml`, and two methodology
    files — imported in full to extract what amounts to a paragraph. That import
    is permanent for the rest of your session, it is the single largest
    consumer of orchestrator context in the loop, and every agent on every host
    pays it again every cycle.

    Ask instead, and stop when you have the answer:

    | You need | Ask |
    |---|---|
    | the operator's active theme | `plan_answer "what is the current Direction?"` |
    | what to work on | `plan_next <role>` / `plan_ready <role>` (then §2.0) |
    | one packet's state | `plan_status <id\|order>` |
    | why something is stuck | `plan_blocked_by` / `plan_blocked_on` / `plan_closure` |
    | a methodology rule | `methodology_ask "<question>"` / `methodology_path` |
    | a spec's content | `spec_answer` |
    | repo/code navigation | `project-info`: `search_code`, `grep_code`, `find_files`, `file_summary`, `read_file` |
    | conversational/synthesis status question | Local Experts mode (`expert-serve`) — same citations-or-typed-refusal contract as `spec_answer` |

    Every answer is CITED. Keep the citations — §5 and §7 need them.

    **Fall back to the filesystem for exactly three reasons, and say which:**

    - **Unavailable** — MCP absent, erroring, or answering
      `confidence=unsupported`. Fall back and *keep going*; a degraded read path
      is never a blocked cycle. Note it in your loop-status entry, so an expert
      that systematically refuses becomes visible instead of being quietly
      routed around (order 531: launch state truthfully reported `experts:
      ready` while every answer was unsupported).
    - **Verification** — before anything irreversible (commit, status flip,
      delete, release) that rests on an MCP answer, read the **cited span** to
      confirm it. The span, not the file. Cited is not the same as checked.
    - **Not exposed** — no tool covers it. Read it directly, and if the loop
      needs it repeatedly, file a packet: a recurring direct read is a missing
      tool, not a habit.

6.  **Direction still binds.** However you obtained it, reduce your packet
    selection against the operator-owned `## Direction` theme rather than
    inventing new direction, and cite it in your work-queue ledger entry
    (order 381).

---

## 2 — Discover Work & Select Shaped Packet

### 2.0 — Run the batch selector FIRST (cycle triage)

```bash
scripts/select-work-batch.sh <linux|macos|windows|any> [--budget N] [--seed S]
```

This decides **what THIS cycle takes**, which flat ranking does not. It emits one
cohesive, budgeted batch drawn from a single epic (`release_target`), the
`triage:` coverage line, and the `frontier` it considered:

```
batch: epic=forge-local-experts-milestone role=linux release=v0.5 size=3 budget=3 score=19.728 seed=host-20260809 pick=1/3
packet  394  plan-methodology-experts-rung1  p1
...
triage: eligible=140 grouped=60 ungrouped=80 epics=6
frontier 19.728  forge-local-experts-milestone  packets=41 blocking=10 neglect=4.7
```

Work the batch **in the order printed**, then stop — do not top up from another
epic. Record the printed `seed` in your loop-status entry so the selection can
be replayed.

Three things about it that are easy to get wrong:

- **It is minimax, not priority-first.** Epics are scored by residual
  (`2*urgency + 1.5*blocking + neglect`), because ranking by p0 alone is the
  anti-pattern `convergence.yaml` names: *raising average convergence by
  improving low-risk obligations while a high-risk maximum residual remains
  unresolved.* The p0-first agent keeps finding p0s.
- **The entropy is score-weighted, and that is deliberate.** Choice is spread
  over the top-3 epics so nothing starves and two concurrent hosts do not
  collide, but weighted so the largest residual still wins most of the time
  (~9 in 12). Predictable drain is a property of batch SIZE — fixed absolutely
  by the budget — never of always picking the same work.
- **`ungrouped=N` on the triage line is a defect signal, not decoration.** It
  counts eligible packets with no `release_target`. When it is large, the epic
  tier is not doing its job; file/assign coverage rather than shrugging. It was
  80 of 140 on 2026-08-09.

Budgets: autonomous/pairing forge sessions = adaptive 4 packets (configurable 3-6 via `--budget N` or `TILLANDSIAS_CYCLE_BUDGET`), unattended litmus step runs = 1 packet, non-forge hosts = 6 (order 707-3x9d).

If the selector refuses (`refused:no-eligible-work`, `refused:no-plan-binary`),
fall back to the manual ranking below — which is also the rationale the selector
automates. Canonical: `methodology/distributed-work.yaml` → `cycle_batch_triage`.

### 2.1 — Manual ranking (fallback, and the rationale)

1.  **Walk the Graph**: Read (via `project-plan` / `project-info` MCP tools or direct file inspection), in order:
    -   `plan/index.yaml` — packet index + selection policy (`plan_query` / `plan_ready`).
    -   `plan/issues/<host>-next-*work-queue*.md` — your host's queue (e.g. `linux-next-work-queue-*`, `osx-next-work-queue-*`, `windows-next-work-queue-*`).
    -   `plan/issues/forge-diagnostics-automation-2026-05-27.md` and `plan/issues/cross-host-blocker-roundup-*.md` — high-impact packets.
    -   (Linux only) `plan/issues/linux-headless-spec-gaps-2026-05-27.md` — diagnostics + headless backlog.
    -   Any other `plan/issues/*.md` referencing your host or "any host".
2.  **Filter Eligible Packets**: Find tasks where:
    -   `owner_host` matches your platform (e.g. `forge`), is `any`, or is a forge diagnostics task (e.g., `forge-improvements/*` or `smoke-finding/forge-*`).
    -   `status` is `ready`, `pending` (if dependencies are unblocked), or `failed-retryable`.
    -   `capability_tags` intersect with your capabilities.
    -   There is no active unexpired lease.
3.  **Selection Priority (Top Wins)**:
    -   **Release-targeted packets FIRST**: packets carrying `release_target: <milestone-packet-id>` outrank the general backlog (canonical: `methodology/distributed-work.yaml` → `release_aware_packets`). A host with no eligible targeted work falls back to the priorities below — targeting concentrates effort, it never idles a host. Never claim a `kind: milestone` packet for implementation — milestones hold criteria; claim their children (`ambitious_milestone_reduction.milestone_packet_semantics`).
    -   **Active Release Packets (`desired_release: v0.5`)**: Prioritize open work targeting the active release minor (`v0.5`) over future releases (`v0.6+`) to concentrate effort on shipping current milestones (e.g. `harness-mcp-expert-validation` order 554, `forge-local-experts-milestone` order 391).
    -   **If running on `forge` host**: Prioritize forge diagnostics, toolchain improvements, and onboarding tasks (e.g. `forge-improvements/proposals/` and `smoke-finding/forge-*` packets) to unblock other builders.
    -   **Diagnostics-driven container-start verification** (USER PRIORITY, linux runtime-host today): work that strengthens the `--diagnostics` → annex → distill → litmus chain. See `scripts/forge-diagnostics-annex.sh`, `scripts/distill-forge-diagnostics.sh`, `openspec/litmus-tests/litmus-forge-diagnostics-e2e.yaml`, `methodology/forge-diagnostics.yaml` piggyback_protocol.
    -   **Spec gap fills**: `openspec/specs/<spec>/spec.md` requirements without implementation coverage. Focus on `headless-mode`, `podman-idiomatic-patterns`, `runtime-diagnostics-stream`, `logging-accountability`, `observability-metrics`.
    -   **Drift-protection litmus**: instant-phase tests pinning surfaces that recent work added (formatter literals, env-var contracts, public API names, unit-test names).
    -   **Clippy / idiomatic-podman hardening**.
    -   **Version-aware release ordering** (The Tlatoāni 2026-07-17; canonical: `methodology/distributed-work.yaml` → `version_aware_release_planning`). Releases are sequential numbered bundles (v0.3 → v0.4 → …), stability-gated not time-gated; "release X" is the CalVer Minor. Every open packet should carry `desired_release: vX.Y` (its ship-bucket, distinct from the milestone `release_target`). After the milestone preference, prefer packets targeting the **ACTIVE release** (`v0.5`; see `plan/loop_status.md`) over later-release ones — concentrate effort on shipping the current bundle. Cross-platform deps are gated by release order (dependent's `desired_release` >= its upstream's). A packet that must slip to a later release: file a `progress` note proposing the slip; the coordinator ratifies. Unmarked open packets default to the active release.
    -   **Filing a new packet? Mint its order, never pick one**: run `tillandsias-plan next-order` (→ `581-k3f9`). Computing "the next free order" from the ledger reads a snapshot that is stale the moment another host commits, so concurrent filers collide deterministically — twice on 2026-07-31, with six collisions still at HEAD. The minted token is PERMANENT: never renumber it, because order tokens leak into code comments, `@trace order:` headers, and commit messages, and a pushed commit message cannot be corrected. A prefix shared by two packets is normal, not a defect. Cite `packet_id` in anything durable. Canonical: `methodology/distributed-work.yaml` → `order_id_allocation`.
    -   **In-forge self-service** (canonical: `methodology/distributed-work.yaml` → `in_forge_agent_self_service`): if you are running INSIDE the forge and hit a missing tool/capability/fix, unblock your FUTURE launches by filing in the SHARED CHECKOUT (the forge is rebuilt from sources each launch): a capability/tool proposal → `plan/forge-improvements/proposals/<date>-<slug>.md`; a forge bug → a `plan/issues/` packet `capability_tags: [forge, …]` `owner_host: linux|any`. If the packet is `forge`-tagged/`any` and fits the forge budget, just do it. Always shaped + verifiable + pushed (a finding that dies with the container is lost).
    -   **A LARGE packet is ELIGIBLE — size is not a skip reason** (The Tlatoāni 2026-07-17; canonical: `methodology/distributed-work.yaml` → `large_packet_is_eligible_work`). Do NOT scan a queue of big packets, judge them all "too large", and reach for an old, small, near-obsolete task instead — that inverts the queue's value order and churns work that later specs will supersede. Rank by VALUE and RELEVANCE, never by smallness: a large, fresh, release-targeted packet OUTRANKS a small, stale one. When you claim a packet you cannot finish this cycle, end in ONE of three valid outcomes, each a complete successful cycle: **(a) partial slice** — smallest vertical slice under a verifiable constraint + a `progress` event with `partial_artifact_refs` and an updated `next_action`; **(b) split** — decompose into smaller `ready` child packets at ownership/dependency/evidence boundaries (`split_into`), the shaping commit IS the cycle's output (this generalizes the forge-only order-264 split rule to every host); **(c) audit-dispose** — if it is stale/superseded, retire it (obsolete/tombstone) per the freshness class. A near-obsolete-looking packet is a signal to AUDIT it, not to implement it as busywork.
4.  **Long-running packets** (`multi_cycle: true`): claims are CYCLE-SCOPED — you claim one session's slice, not the packet. A `ready` multi_cycle packet with prior progress events is claimable (that's the design, not a stale lease). Canonical rules: `methodology/distributed-work.yaml` → `long_running_packets`.
5.  **Constraint**: ONE logical commit per batch/cycle. If an individual slice estimates >2h, split it and ship the first half. (Unattended litmus-hosted sessions (`TILLANDSIAS_LITMUS_STEP`) drain **at most ONE packet per session** to fit the 600s timeout; autonomous/pairing forge cycles execute **adaptive batches of 3–6 packets** to maximize the work-to-orchestration ratio. Decided by The Tlatoāni, order 707-3x9d; canonical: `methodology/distributed-work.yaml` `worker_agent_protocol.forge_cycle_budget`.)
6.  **Standing FRESHNESS audit class** (order 372, methodology `component_freshness`): each cycle, after worker drain, pick ONE component the `freshness-advisory` CI phase flagged as stale (or any unstamped component) and re-validate it against the audit question — *last properly looked at and confirmed still meaningful, useful, efficient, sound, and complete?* End in exactly one disposition: **refreshed** (re-validated, update its `# freshness:` stamp), **updated** (fixed/tuned, update stamp), or **obsoleted** (delete/tombstone with a same-commit removal of dependents). Apply the **discard-over-repair bias**: discard a stale component rather than repair it when a fresh implementation would be better. Record a `# freshness: auditor=<id> date=<ISO> verdict=<...> scope=<one-line>` stamp (grammar in methodology.yaml). `scripts/freshness-inventory.sh` emits the coverage report + the top stale components each `./build.sh --ci` run.
6.  **Delegate Parallelizable Research**: Use sub-agents for file inventories, grep searches, etc., but keep ownership of specs, verification, and commits.

---

## 3 — Claim the Lease

1.  **Claim by flipping status, and push it BEFORE the work.**

    ```bash
    tillandsias-plan set-field <packet-id> status in_progress \
        --host "$(hostname -s)" --reason "claimed for cycle <UTC ts> by $agent_id"
    git add plan/index.d/
    git commit -m "claim(<packet-id>): <host>"
    git push origin <active-branch>
    ```

    `$agent_id` is the §1.4 helper output (`scripts/agent-identity.sh id
    <backend>`) — if the helper refused, there is no identity to claim with, and
    nothing may be appended or pushed.

    **This is the whole separation mechanism, and it is the ONLY one.**
    `plan_next` / `plan_ready` / `select-work-batch.sh` filter to `unleased`,
    and *leased* means exactly `status: in_progress`. Nothing else — not a
    `claim` event, not a lease ID, not a work-queue line — hides a packet from
    another host.

    **Push it BEFORE the work, not with it. An unpushed claim separates
    nobody**, and neither does one that lands after you have already spent the
    cycle implementing.

    CORRECTED 2026-08-31 (order 943-unii). This step used to say *"Emit Claim
    Event: append a `claim` event … using `tillandsias-plan append-event
    <packet-id> claim …`"*, committed and pushed WITH the cycle's work. That
    recipe changes no status, so a packet claimed that way stays `ready` and
    stays offered to every other host. It is an AUDIT RECORD, not a claim.

    Measured on the live ledger: packet 245 carried **43** claim events and was
    still returned by `ready linux`. `expire-claims` reported `in_progress=0`
    fleet-wide on 2026-08-19 — nothing had ever been claimed at all. On
    2026-08-18 two hosts implemented 798-tk7b six minutes apart, ~4h duplicated
    (order 814-iyu7); that is the failure this recipe left open, and one worker
    host followed it for nineteen consecutive cycles without claiming anything.

    Verified again when this correction was written, on this repository:
    `set-field … in_progress` moved the selector's `eligible` count 174 → 173
    and dropped the packet out of both `ready linux` and the printed batch, in
    the same command. That is the positive control — the mechanism was never
    broken, it was simply not being invoked.

    `methodology/distributed-work.yaml` (*"a `claim` event changes status from
    ready to in_progress"*) and `skills/meta-orchestration/SKILL.md` (*"Cycle
    batch triage"*) both already specified the recipe above. This section was
    the outlier, and it was the one every worker host runs every cycle.

2.  **Optionally add a narrative `claim` event too** — useful, never sufficient:

    ```bash
    tillandsias-plan append-event <packet-id> claim "<what this cycle intends>" \
        --ts "<ISO-8601-UTC>" --agent "$agent_id" --host "<host>"
    ```

    If `append-event` refuses with `packet_id not found`, the packet lives only
    in a fragment and that command cannot see it (600-c266) — write the event
    block by hand in your own fragment, keyed under `events:`. **A `status`
    change is different: never hand-author it, always use `tillandsias-plan
    set-field`** (see §7.2), because a hand-written fragment that re-declares
    the packet under `packets:` with a new status is a G-Set no-op — it parses,
    validates, passes `tillandsias-plan check`, reads correctly in review, and
    the fold discards it (635-i6vm).

3.  **Collisions are arbitrated by TIMESTAMP, not by push rejection.**

    The ledger is a CRDT, so two hosts can both claim in the same window and
    both pushes can succeed. On your next fetch, if another host's claim for
    that order carries an EARLIER timestamp (ties broken by lexicographically
    smaller hostname), **you lost**: release yours back to `ready` and take the
    next batch item.

    Losing the race is normal and cheap. Both hosts writing is fine; both hosts
    *continuing* is the defect, and is precisely 814-iyu7. A rejected push is a
    weaker and later signal than the timestamp — a push can succeed and still
    have lost — so do not wait for one.

4.  **Release on exit, unconditionally.**

    Completed work moves to its terminal status (§7.2). Work you did NOT finish
    goes back to `ready` **in the same cycle you abandon it**:

    ```bash
    tillandsias-plan set-field <packet-id> status ready \
        --reason "released unclaimed at cycle end: <what remains>"
    ```

    Leaving it `in_progress` hides it from `ready` AND from burndown until the
    24h reaper — 21 packets were stranded that way on 2026-08-09 (641-e2qa).
    **Claiming is only safe because releasing is unconditional.** A cycle that
    claims and then exits without either completing or releasing has taken work
    away from the fleet and given nothing back.

5.  **The reaper is a backstop for a dead host, not your return path.**

    A claim with no event by cycle end is *reclaimable* after **24h** by
    `scripts/reclaim-stranded-claims.sh` — read the verb: reclaim**able**, not
    reclaimed. The TTL is 24h (`TTL_HOURS=24`, "the fleet claim TTL";
    `expire-claims` reports `ttl_hours=24`). **No automation runs either tool:**
    the reaper has no caller outside its own source and fixture, and `build.sh`
    only shape-checks `expire-claims --list-live`.

    THAT IS DELIBERATE, NOT A GAP. `skills/meta-orchestration/SKILL.md` gives
    the coordinator a per-cycle stranded sweep that REPORTS and does not reap,
    and says why: *"Advisory, never a gate… Do not bulk-close what it reports.
    Closing a packet requires checking its exit criteria against the tree;
    guessing marks unfinished work done, which is strictly worse than leaving it
    stranded."* A packet legitimately in flight is indistinguishable from one
    abandoned an hour ago, so the discrimination is human judgement by design.

    Which is exactly why step 4 is yours. If hosts released on exit, the reaper
    would have nothing to find; the 3-of-5 stranded rate measured on 2026-08-30
    is a symptom of hosts not releasing, not of a reaper that fails to run.

## 4 — Host Write Scope & Unblock-with-NOOP

Each host has a primary write scope. You can READ everything; you should normally only WRITE within your scope:

| Host    | Primary write scope |
|---------|---------------------|
| Linux   | `crates/tillandsias-{headless,podman,control-wire,core,metrics,logging,vault-client}/`, `scripts/forge-diagnostics-*`, `scripts/distill-*`, `images/`, `openspec/litmus-tests/`, most `plan/issues/` |
| macOS   | `crates/tillandsias-macos-tray/`, `crates/tillandsias-vm-layer/src/{vz,transport_macos,materialize/macos}.rs`, `scripts/install-macos*`, `scripts/build-macos*` |
| Windows | `crates/tillandsias-windows-tray/`, `crates/tillandsias-vm-layer/src/{wsl,materialize/windows}.rs`, `scripts/install-windows*`, `scripts/tray-diagnose.ps1`, host-shell pty windows files |

Cross-host shared scope (any host may write, but COORDINATE via the ledger first): `crates/tillandsias-control-wire/` (wire format — WIRE_VERSION must not break), `crates/tillandsias-host-shell/`, `methodology/`, `openspec/specs/`, top-level docs.

### Unblock-with-NOOP Rule
If your work needs a function/type/file that lives in a sibling-owned scope and doesn't exist yet, you MAY add a **minimal stub** there to unblock yourself. Mark it explicitly:
```rust
// PLEASE REVIEW: <sibling-host> — minimal stub to unblock <your-work>.
// Owner: replace with the real implementation and add a brief
// `// DEPRECATED: superseded by <new-name>` comment here for one
// release cycle so callers can migrate.
pub fn placeholder() -> Result<(), String> {
    // TODO(<sibling-host>): implement
    Err("not yet implemented".to_string())
}
```
Cite the unblock in your commit body (`unblock-noop: <path>:<line>`) so the sibling host can find it on their next cycle. Keep the stub tiny — one function, one error, no business logic.

---

## 5 — Execute + Verify

```bash
cargo fmt --all
./build.sh --check
cargo test -p <crate-you-touched>      # targeted, fast
./build.sh --test                       # cross-cutting changes only
```

Hard rules:
- **Never bypass the idiomatic-podman layer.** The test `idiomatic_podman_launch_paths_do_not_bypass_shared_layer` enforces routing through `PodmanClient` — no direct `Command::new("podman")` in production launch paths.
- **Develop THROUGH the idiomatic layers — no ssh/root/side channels into the guest.** The control wire / `--diagnose` / ExecOneShot / PTY-attach (+`TILLANDSIAS_PTY_DEBUG` tee) surfaces are the ONLY sanctioned guest access, for forensics and debugging exactly as for runtime. A task the layer cannot do is a product gap: file a packet extending the layer instead of side-stepping. Root exec anywhere in guest/forge is a finding, not a tool. Canonical: `methodology/multi-host-development.yaml` `idiomatic_layers_for_agents` (The Tlatoāni, 2026-07-10, order 271).
- **Container security flags are non-negotiable**: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`.
- **Pre-commit hooks and release signing** are not optional.
- **Acquire the smoke lock for source-mutating migrations**: Destructive, file-moving, or source-mutating directory migrations (e.g., file-restructuring tasks) MUST run under the shared smoke lock `build-install-smoke-e2e` (using `scripts/with-smoke-lock.sh`) or a corresponding lease, so that concurrent E2E gates do not read or execute from a half-migrated or half-restructured tree.

- **Check and test with the gate's feature set, and quote the set beside the
  count.** `cargo check -p tillandsias-headless --features tray` does NOT
  compile the vsock surfaces (vsock_server.rs, vsock_client.rs, the
  control_dispatch.rs arms behind `listen-vsock`); on 2026-09-04 macbookair
  spent six rounds getting truthful zero-error results about code the check was
  not compiling, and every "588 passed" it reported that day was the same suite
  under `--features tray` — the gate's set, `--features tray,listen-vsock`, runs
  635. A count whose denominator depends on flags nobody states is not
  falsifiable; "635 passed under tray,listen-vsock" is. Use the gate's set, and
  write the set next to the number in every claim.

- **`./build.sh --check` runs no litmus (748-tkjx); run the bound spec before
  landing on any surface a litmus covers.** On 2026-09-04 lenovinha ran the
  gate four times green over gate-stamp.sh and landed a change whose guard,
  `litmus:mode-only-regression-gate`, states in its own arm text why that exact
  change deadlocked every Windows host once (889-8tcb); the daily release gate
  and the coordinator's union litmus were the first places it could go red.
  "My gate was green" is evidence about the gate's lane, not about the change:
  `scripts/run-litmus-test.sh --diff-scope origin/linux-next --compact` (or the
  bound spec by name) before the land, not after.

- **The gate pass token gates the STAMP, never the PUSH (1039-b64k).** A push
  needs a *stamp* whose digest matches the tree being pushed; the pre-push hook
  calls `gate-stamp.sh verify`, which compares recorded-vs-computed digest and
  nothing else. `<git-dir>/tillandsias-gate-pass-token` is minted by a green
  `build.sh` and consumed by `gate-stamp.sh write`, so an unearned stamp is
  impossible by accident (940-f77j) — but no branch of the hook reads it. Two
  consequences worth knowing before you debug a refused push: a **memoised**
  gate mints no token and writes no stamp and still pushes fine, because the
  existing stamp covers the unchanged tree; and a fix that adds or moves the
  token cannot affect a push at all. 1039-b64k was filed with a remedy resting
  on the opposite belief, and the remedy was dropped once the push path was
  actually read rather than inferred from the packet.

- **After a gate run, rebuild before exercising a feature-gated path
  (1031-q4pb).** `./build.sh --check` rebuilds `target/debug/tillandsias`
  WITHOUT `--features tray`, so a control arm that drives a `#[cfg(feature =
  "tray")]` surface after a gate is exercising a binary in which the code under
  test does not exist. On 2026-09-04 that turned a working control into a hang;
  had the absent path fallen through to success instead, it would have been a
  green arm for absent code. `cargo build -p <crate> --features <feature>`
  immediately before the arm, every time — a gate silently replaces the binary.

- **Read a file's own comments before concluding a failure is novel
  (yolanda, 2026-09-04).** yolanda spent ~40 minutes and four gate runs
  rediscovering the Windows drvfs deadlock from scratch — the mechanism, the
  memo amplifier, and the measurement — all of which were already written eighty
  lines above the line being debugged, in `gate-stamp.sh`'s `compute`, from
  order 889-8tcb. They had read the file three times during the diagnosis, each
  time for a different question, and never the paragraph directly above the
  suspicious line. A file that has been bitten before usually says so, and this
  project records that more reliably than most. (The defect being rediscovered
  was lenovinha's 1034-ihxw, landed against that same warning — so the two
  halves of this lesson are one event.)

- **Quoted history lives in comments; guards scan declarations.** A codebase
  that explains itself contains the strings it forbids (a doc comment names the
  identifier it replaced, a narrowing quotes the sentence it narrowed), so a
  class guard that scans for a bare substring fails on its own file the day it
  is written. Scan declarations (`pub old_name:`, `fn old_name`) and assemble
  the needles at runtime (`format!("pub vm_{}_live:", "owner")`) so the guard
  cannot match its own source; keep the quoted history where it explains the
  change. Named by macneo on 980-ja2m, 2026-09-04, after its first class guard
  went red on its own doc comments.

- **A gate run silently replaces the binary without the tray feature.**
  `./build.sh --check` rebuilds `target/debug/tillandsias` without `--features
  tray`; every order-505 site and much of the tray surface is
  `#[cfg(feature = "tray")]`, so a control arm run after a gate can exercise a
  binary in which the code under test does not exist. On 2026-09-04 lenovinha's
  arms hung against such a binary, which was luck: an absent path falling
  through to success is a green arm for absent code. Build with the feature
  set the change needs (`cargo build --features tray,listen-vsock`) immediately
  before any live control arm, and quote the feature set beside the arm.

- **A control variable set outside the builder does not reach cargo inside it.**
  `scripts/with-tillandsias-builder.sh` forwards only `TILLANDSIAS_*`, `LITMUS_*`,
  `FORGE_*`, `NIX_*`, `CONTAINER_HOST` and `DOCKER_HOST` into the toolbox, and
  `with-wsl2-builder.sh` forwards only `TILLANDSIAS_*` across wsl.exe; on
  2026-09-05 `CARGO_BUILD_JOBS=10` was UNSET inside the builder on both Linux and
  Windows, so a "ten-job arm" ran at twenty and would have reported a confident
  null. A build setting must be applied inside the build scripts, or forwarded by
  name with a probe that proves it arrived (`with-tillandsias-builder.sh bash -c
  'echo ${VAR:-UNSET}'`) before any measurement is read.

- **A stamp-dependent litmus arm must declare its skip to the harness, or it is red on every merged union.** `expected_behavior` is an exact match; a test that honestly prints `skip: no warm stamp` under it reads as a wrong answer, and a merged union has by definition changed since the last gate, so the red recurs in every coordinate cycle (1036-e5w9's closure, 2026-09-05: 290/291 on the union). Split the arm: the invariance half with no precondition, which can never skip; the memo half under a `success_pattern` regex that admits the ok form and a self-naming `skip:<order>:<reason>` token; and a control that would go red if the memo were made to refuse always. Never widen the expectation until the skip passes: that is a green that asserts nothing (1041-up99).

- **On Windows, name the runner beside a test count: native cargo or the gate's WSL re-exec.** A `cfg(all(test, unix))` module reports "7 passed" natively while three of its tests are broken, because the broken ones were never compiled; only the WSL re-exec runs them (972-umik commit B, 2026-09-05). Windows-native cargo output is not evidence about a unix-cfg module. And a litmus verdict from a Windows host before df5708607 (1049-s35z) is unearned: CRLF from jq.exe made bound tests unfindable, and the runner counted the skips as PASS.

- **Under the relay protocol, `git pull --rebase` on linux-next fuses the two lanes.** A slow-gate host pushes gated code to `work/<order>` for the coordinator to relay-land and pushes ledger fragments directly through the plan-only lane. If both commits exist on the same local linux-next, a rebase carries the code into the "plan-only" push and the hook refuses it (`plan-only lane: not applicable — … outside plan/index.d/`), which is correct; the refusal's output offers `git push --no-verify`, which would push the violation through. Never use it. After a `work/` push, reset local linux-next to `origin/linux-next` before starting plan-only work, so the lanes never share a branch; if they already do, reset to trunk and cherry-pick the fragment commit alone after confirming the `work/` ref is safe on origin (lenovinha, 2026-09-05, 1059-pb2j).

- **Relay-lane order is fetch, rebase, gate, push; and never sequence a destructive git command after a push in the same block.** Gating before the rebase invalidates the stamp and the hook refuses correctly (lenovinha, 2026-09-05). And `git push && …` is not enough when the push is refused by a hook that exits non-zero only sometimes: a `git reset --hard` placed after a push in one block ran on a refused push and discarded a commit that existed nowhere else, recovered from the reflog. Under the relay protocol a `work/` push is followed by a reset to keep the lanes apart, which makes this likelier: read the push's verdict line, then reset in a separate command.

---

## 6 — Commit, Push & Checkpoint

1.  **Durable Checkpointing**: At meaningful milestones (every 30–45 minutes), write an `agent_status_packet` as a `progress` or `checkpoint` event to a `plan/index.d/` fragment via `tillandsias-plan append-event <packet-id> progress ...` or fragment file, and commit/push it to your host's `<active-branch>`.
    -   *Schema requirement*: Include current plan, touched files, partial evidence, and next checkpoint.
2.  **targeted git add**: ONLY stage the intended files:
    ```bash
    git add <specific-files>      # NEVER `git add -A` (cross-host churn)
    git commit -m "<slice-message>"   # cite trace + plan packet + any unblock-noop
    git push origin <active-branch>
    ```

### Integration Verification Gate (run AFTER every rebase/merge, BEFORE every push)

This gate is **non-negotiable**. The shared trunk has been broken twice by agents
pushing an un-revalidated post-integration tree: a duplicate `#[test]` definition
(E0428) and an orphan `>>>>>>>` conflict marker left inside `plan/index.yaml`.
`./build.sh --check` alone does NOT catch the YAML class — `plan/`/`openspec/`
files are data, not compiled. So a rebase/merge is only "done" when ALL of these
pass on the merged tree:

```bash
# SAME-branch catch-up only: rebase YOUR un-pushed commits onto origin/<active-branch>.
# (CROSS-branch integration — sibling->trunk or main->branch — is MERGE-ONLY; never
#  rebase/cherry-pick published commits across branches. See the integration_strategy
#  in methodology/multi-host-development.yaml. The gate below runs for BOTH cases.)
git fetch origin && git rebase origin/<active-branch>     # ≤3 retries

# 1. No conflict markers survived the resolution (the orphan-marker bug).
#    Markers are EXACTLY 7 chars then space/EOL — do not match `=` separator lines:
git grep -nE '^(<<<<<<<|=======|>>>>>>>)( |$)' && { echo "CONFLICT MARKER PRESENT"; exit 1; } || true

# 2. Every touched YAML still parses (the broken-plan/index.yaml bug — `build
#    --check` does NOT validate data files, so this step is what catches it):
#    PICK THE VALIDATOR THAT EXISTS WHERE YOU ARE. `ruby` is NOT in the forge
#    image; `yq` is. Hosts usually have both. `python3` is present in the forge
#    and is FORBIDDEN for committed automation (tlatoani_hard_no_python) — its
#    presence is not permission, and it is the trap this fallback chain exists
#    to keep you out of.
if command -v tillandsias-policy >/dev/null 2>&1; then
  yamlcheck() { tillandsias-policy validate-yaml "$1"; }
elif command -v yq >/dev/null 2>&1; then
  yamlcheck() { yq . "$1" >/dev/null; }
elif command -v ruby >/dev/null 2>&1; then
  yamlcheck() { ruby -ryaml -e "YAML.load_file('$1')"; }
else
  echo "no sanctioned YAML validator available — do NOT substitute python3"; exit 1
fi
for y in $(git diff --name-only origin/<active-branch>..HEAD | grep -E '\.ya?ml$'); do
  yamlcheck "$y" || { echo "INVALID YAML: $y"; exit 1; }
done

# 3. Code still compiles — clippy + cargo catch the duplicate-item E0428 directly
#    (also pinned by litmus:no-duplicate-rust-item-defs in the --ci-full suite):
./build.sh --check

# Only now:
git push origin <active-branch>
```

If any step fails, FIX or abort the rebase — **never push a tree that failed this
gate.** A push that breaks the trunk costs every other agent their next cycle; the
gate is the price of concurrent convergence.

3.  **Durable Ledger Update**: Write a one-line outcome to your host's work-queue ledger (`plan/issues/<host>-next-work-queue-*.md`):
    ```
    - 2026-MM-DDTHH:MMZ  <commit-sha>  <one-line summary>
    ```

### Defer Rule
If the 2h integration cron fired in the last 10 min (check the latest `### Cycle` timestamp in `plan/issues/multi-host-integration-loop-2026-05-24.md`), write a no-op ledger entry and exit. The cron's writes need to settle before another work commit lands.

---

## 7 — Submit Completion or Yield

### Submit Completion

**Long-running packets** (`multi_cycle: true` with `verification_required`):
you MUST NOT emit `completed` or flip status to `done` yourself, even with
every exit criterion implemented. Instead: append a `progress` event stating
implementation-complete, set `phase: verification`, update
`progress_summary` and `plan/long-running.md` in the same commit, and leave
status `ready`. The packet closes only when every agent named in
`verification_required` has emitted passing `verified-by` events
(`methodology/distributed-work.yaml` → `long_running_packets`).

0.  **Cycle Metrics**: Run `scripts/cycle-metrics.sh` and include its output in
    your completion report. Read `verdict` first — it names the cycle's weakest
    point. `attention:expert-answered-nothing-check-base-branch` means the
    expert ARTIFACT is wrong (order 531), not that the questions were hard;
    check the base branch before trusting any expert answer from this cycle.
    Report `experts_substitution` as `unknown` — it is not derivable in-repo and
    must never be estimated. Pass `--cycle-start <your Start-Of-Cycle UTC>` so
    `repeat:` measures this cycle, and read `skippable:` (printed right after
    `timing:`) alongside `verdict:` — it names the expensive, outcome-invariant
    steps this host keeps paying (order 1001-q3zf); quote `saved_ms_upper` as
    the bound it is.
1.  **Full Verification**: Run the full validation litmus on your platform to confirm zero-drift compliance.
2.  **Close the packet — BOTH the event and the status transition.**

    **LAND THE CODE FIRST, then close with the SHA the landing printed.**
    `scripts/land-on-platform-branch.sh` fetches, integrates onto origin and
    REWRITES your commit, so a SHA captured before it is the pre-rebase local
    one and never exists upstream. `ok:land:<sha>` is the only SHA that exists.

    ```bash
    landed="$(scripts/land-on-platform-branch.sh | sed -n 's/^ok:land:\([0-9a-f]*\):.*/\1/p')"
    tillandsias-plan set-field <packet-id> status completed \
      --evidence "$landed" \
      --reason "<what shipped, validation log paths>"
    ```

    Then commit and push the ledger fragment (step 3), which takes the
    plan-only lane. **This inverts the old step 2/step 4 order for the CODE
    commit only** — every other ledger write keeps the 3c ordering.

    ORDER 1024-c3h3. This step used to run before the landing, and the evidence
    refs were systematically wrong for every host that followed it: lenovinha
    measured four of four closures citing ghosts on 2026-09-04 (5326cb97d,
    d2ce890b2, 89f6960d2, 4aaa24ba2, while the code landed as dcc50ff27,
    a20540d33, 42930b71c, 00549903c), and yoga's 1011-d578 cited 677c30527 the
    same way. A reader running the obvious check
    (`git merge-base --is-ancestor <sha> origin/<branch>`) gets NO and **cannot
    tell "the code never landed" from "the ref was captured too early"** — two
    conditions needing opposite responses. That is 881-29me's shape with a SHA
    instead of a line number: cite what survives the operation.

    If you cannot capture the landed SHA, cite by content the rebase preserves
    (the commit subject, a test name, a verdict line) and say that is what you
    did. A wrong SHA is worse than no SHA, because it looks checkable.

    An event alone does **not** close a packet. This step used to read *"append
    a `completed` event … or by writing an append-only fragment file setting
    status `done`"*, and **both of those branches are broken** — which is why
    three hosts left finished work claimable on 2026-08-09:

    - `append-event` locates packets by their item prefix in `plan/index.yaml`
      and is blind to fragment-only packets (600-c266). It refuses them outright.
    - Hand-writing a fragment that re-declares the packet under `packets:` with
      a new status is a **G-Set no-op**. It parses, validates, passes
      `tillandsias-plan check`, reads correctly in review — and the fold throws
      it away. 11 of 21 completions were discarded that way (635-i6vm).
    - Writing only a `type: completed` event leaves the status untouched. macOS
      did this after a 5/5-PASS validation with an evidence file; the packet was
      still being handed out as work hours later.

    `set-field` resolves against the folded ledger, writes the LWW channel
    correctly, refuses an unknown reference, and reports a no-op instead of
    writing one. Add a narrative `progress`/`completed` event too if the detail
    is worth keeping — but the status transition is what actually closes it.
3.  **Commit & Push Ledger**: Commit and push the final plan fragment edits to `origin/<active-branch>`.
4.  **Attest**: with every commit pushed, run `scripts/finalize-cycle.sh <active-branch>`
    (verify boundary, record, land, re-verify, derive the `MO-FULL:` marker —
    never type it). It needs the §1 step 1b snapshot; without one the honest
    exit is landed-but-unattested, stated in the loop-status entry's first
    line. Write that entry with `tillandsias-plan loop-status-append --host <host>
    --ts <cycle-start-UTC> --backfill < fragment.md` — or `--file fragment.md`, or
    a bare path, all three of which now work. Order 1004-8vkv fixed what this
    line used to warn about: a path argument was silently dropped and the
    command then blocked forever on an inherited socket stdin (lenovinha,
    2026-09-04, 26 minutes). A stdin with nothing writing to it is now refused
    in 5s naming both explicit forms, and an empty read says `read 0 bytes`
    instead of blaming your fragment's headings.

### Mandatory Exit Discipline

A successful invocation MUST NOT exit with local-only work:

- If implementation is complete, update the owning plan item status and append a
  completion event with evidence before the final commit.
- If implementation is incomplete but coherent, commit a checkpoint and append a
  progress event with remaining work and the next action.
- If implementation is blocked, append a blocked/failed event with the exact
  blocker and smallest next diagnostic command.
- Push every checkpoint/completion to the appropriate remote branch before
  returning success.
- Before final success, verify `git status --short --branch` is clean and not
  ahead of upstream. If not, finish the commit/push or mark the plan item
  blocked with the reason.

### Yield & Triage (Failure/Blockage)
1.  **Emit Blocked or Failed Event**: If you encounter an unresolvable error, blocker, or spec gap:
    -   Append a `blocked` or `failed` event to `events:` detailing the exact reason, the named blocker, and the smallest next diagnostic command.
    -   Flip status to `blocked` or `failed` (with `retryable: true|false`).
    -   Commit and push to `origin/<active-branch>` so the Orchestrator can audit and reschedule it.
2.  **Fallback Selection**: Release your local lease, select your named fallback task, and begin the loop fresh.

---

## Hard Guardrails

- NEVER `git push --force`.
- NEVER push directly to `main` — use PRs. Check `plan/issues/cross-host-blocker-roundup-*.md` for the active `<host>-next → main` PR number before opening a duplicate.
- NEVER push to a sibling host's branch (linux MUST NOT push to `osx-next` or `windows-next`).
- **Velocity Limit Compliance ($C_{max}$)**: Do not push more than **2 commits per hour** if convergence velocity remains zero or negative ($\mathcal{V}_c \le 0$). High-frequency pushing without progress causes thrashing and triggers a 1-hour cooldown.
- **Branch Drift Compliance ($D_{max}$)**: Do not allow your platform branch (`windows-next`, `osx-next`) to drift more than **$D_{max} = 5$ commits** ahead of the common `merge-base` with `linux-next`. If drift exceeds 5 commits, you MUST immediately halt feature work and run a pull-integration and merge pass.
- NEVER skip hooks or signing.
- `release.yml` is `workflow_dispatch` only — never auto-trigger. (The old `recipe-publish.yml` rootfs workflow was removed in the 2026-06 Fedora pivot.)
- NEVER resolve cross-host plan conflicts by deletion — tombstone or supersede only.
- When the worktree is dirty, only stage `plan/` files explicitly by path. Implementation code from a previous (uncommitted) iteration is NOT yours to touch.
- Treat every local-only commit as volatile. If it matters, push it before
  ending; if it cannot be pushed after three retries, file a blocked event.

---

## How Orchestrators Steer this Skill

The canonical file lives at `skills/advance-work-from-plan/SKILL.md`.
Each agent runtime (`.claude/`, `.opencode/`, `.codex/`, `.gemini/`, `.github/`) accesses it via a symlink under its `skills/` directory, so there is exactly one source of truth.

To steer remote agent work between iterations, an orchestrator can:
- Edit the priority list in §2 to elevate a packet for the next cycle.
- Tighten or loosen the defer rule in §6.
- Add a new host row to §1 (e.g. when a freebsd-host comes online).
- Drop or extend the unblock-with-NOOP rule in §4.
