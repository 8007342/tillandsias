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
2.  **Host and Identity**: Identify your platform (`linux`, `windows`, `macos`, `forge`), your agent name, and your intended capabilities (`rust`, `podman`, `docs`, `testing`, etc.).
3.  **Host Detection Table**:
    | uname/$OS / env | Platform Name | Canonical Branch |
    |-----------------|---------------|------------------|
    | Inside Forge    | `forge`       | `linux-next`     |
    | Linux           | `linux`       | `linux-next`     |
    | macOS           | `macos`       | `osx-next`       |
    | Windows         | `windows`     | `windows-next`   |
4.  **Create Agent ID**: Compose a unique ID: `<platform>-<workstation>-<backend>-<utc-timestamp>`.
5.  **Use Local MCP Servers for Instant Context**:
    - **`project-plan` (`forge-plan`)**: Call `plan_query`, `plan_ready`, `plan_status`, `plan_answer`, `methodology_path`, `methodology_ask` for fast sub-60ms cited envelopes over `plan/` and `methodology/`.
    - **`project-info`**: Call `read_file`, `search_code`, `git_status`, `project_structure` for fast sub-90ms repo navigation without heavy context load.
6.  **Read Authoritative Ledgers**: Read:
    -   `methodology.yaml`
    -   `methodology/distributed-work.yaml`
    -   `plan.yaml`
    -   `plan/index.yaml` (or via `project-plan` / `forge-plan` MCP tools)
    -   `plan/loop_status.md`
    -   **Read the `## Direction` section of `plan/loop_status.md`** (operator-owned
        thematic direction). Reduce your packet selection against that theme
        rather than inventing new direction; cite the direction in your work-queue
        ledger entry (order 381).

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

Budgets: forge = 1 packet (order 264, unchanged), everything else = 3.

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
5.  **Constraint**: ONE logical commit per cycle. If a slice estimates >2h, split it and ship the first half. (Forge-hosted sessions (`TILLANDSIAS_HOST_KIND=forge`) are stricter, not looser: **at most ONE packet per session**, and if the packet will not fit the launch envelope — litmus-launched sessions live inside a 600s step budget — **split it into smaller ready packets instead of implementing**. The shaping commit is the session's output. Decided by The Tlatoāni 2026-07-10, order 264; canonical: `methodology/distributed-work.yaml` `worker_agent_protocol.forge_cycle_budget`.)
6.  **Standing FRESHNESS audit class** (order 372, methodology `component_freshness`): each cycle, after worker drain, pick ONE component the `freshness-advisory` CI phase flagged as stale (or any unstamped component) and re-validate it against the audit question — *last properly looked at and confirmed still meaningful, useful, efficient, sound, and complete?* End in exactly one disposition: **refreshed** (re-validated, update its `# freshness:` stamp), **updated** (fixed/tuned, update stamp), or **obsoleted** (delete/tombstone with a same-commit removal of dependents). Apply the **discard-over-repair bias**: discard a stale component rather than repair it when a fresh implementation would be better. Record a `# freshness: auditor=<id> date=<ISO> verdict=<...> scope=<one-line>` stamp (grammar in methodology.yaml). `scripts/freshness-inventory.sh` emits the coverage report + the top stale components each `./build.sh --ci` run.
6.  **Delegate Parallelizable Research**: Use sub-agents for file inventories, grep searches, etc., but keep ownership of specs, verification, and commits.

---

## 3 — Claim the Lease

1.  **Mint Lease ID**: Mint a content-stable lease ID.
2.  **Emit Claim Event**: Append a `claim` event as a fragment in `plan/index.d/` using `tillandsias-plan append-event <packet-id> claim "<summary>" --ts "<ISO-8601-UTC>" --agent "<your-agent-id>" --host "<host>"` or by creating an append-only fragment in `plan/index.d/<utc>-<suffix>-<host>.yaml`.
3.  **Commit & Push**: Commit ONLY the plan fragment edits, and push them to your active platform branch:
    ```bash
    git add plan/index.d/
    git commit -m "chore(plan): claim lease for <task-id>"
    git push origin <active-branch>
    ```
4.  **Collision Recovery**: If the push is rejected because another agent claimed the lease concurrently, fetch, pull, yield your claim, and select a different packet.

---

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
    must never be estimated.
1.  **Full Verification**: Run the full validation litmus on your platform to confirm zero-drift compliance.
2.  **Emit Completed Event**: Append a `completed` event as a fragment in `plan/index.d/` using `tillandsias-plan append-event <packet-id> completed "<summary>" ...` or by writing an append-only fragment file in `plan/index.d/` setting status `done` and listing commit SHAs and validation log paths.
3.  **Commit & Push Ledger**: Commit and push the final plan fragment edits to `origin/<active-branch>`.

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
