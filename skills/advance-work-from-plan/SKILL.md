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
    git checkout linux-next
    git pull --ff-only origin linux-next
    ```
2.  **Host and Identity**: Identify your platform (`linux`, `windows`, `macos`, `forge`), your agent name, and your intended capabilities (`rust`, `podman`, `docs`, `testing`, etc.).
3.  **Host Detection Table**:
    | uname/$OS / env | Platform Name | Canonical Branch |
    |-----------------|---------------|------------------|
    | Inside Forge    | `forge`       | `linux-next`     |
    | Linux           | `linux`       | `linux-next`     |
    | macOS           | `macos`       | `osx-next`       |
    | Windows         | `windows`     | `windows-next`   |
4.  **Create Agent ID**: Compose a unique ID: `<platform>-<workstation>-<backend>-<utc-timestamp>`.
5.  **Read Authoritative Ledgers**: Read:
    -   `methodology.yaml`
    -   `methodology/distributed-work.yaml`
    -   `plan.yaml`
    -   `plan/index.yaml`
    -   `plan/loop_status.md`

---

## 2 — Discover Work & Select Shaped Packet

1.  **Walk the Graph**: Read, in order:
    -   `plan/index.yaml` — packet index + selection policy.
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
    -   **If running on `forge` host**: Prioritize forge diagnostics, toolchain improvements, and onboarding tasks (e.g. `forge-improvements/proposals/` and `smoke-finding/forge-*` packets) to unblock other builders.
    -   **Diagnostics-driven container-start verification** (USER PRIORITY, linux runtime-host today): work that strengthens the `--diagnostics` → annex → distill → litmus chain. See `scripts/forge-diagnostics-annex.sh`, `scripts/distill-forge-diagnostics.sh`, `openspec/litmus-tests/litmus-forge-diagnostics-e2e.yaml`, `methodology/forge-diagnostics.yaml` piggyback_protocol.
    -   **Spec gap fills**: `openspec/specs/<spec>/spec.md` requirements without implementation coverage. Focus on `headless-mode`, `podman-idiomatic-patterns`, `runtime-diagnostics-stream`, `logging-accountability`, `observability-metrics`.
    -   **Drift-protection litmus**: instant-phase tests pinning surfaces that recent work added (formatter literals, env-var contracts, public API names, unit-test names).
    -   **Clippy / idiomatic-podman hardening**.
4.  **Long-running packets** (`multi_cycle: true`): claims are CYCLE-SCOPED — you claim one session's slice, not the packet. A `ready` multi_cycle packet with prior progress events is claimable (that's the design, not a stale lease). Canonical rules: `methodology/distributed-work.yaml` → `long_running_packets`.
5.  **Constraint**: ONE logical commit per cycle. If a slice estimates >2h, split it and ship the first half. (Forge-hosted sessions (`TILLANDSIAS_HOST_KIND=forge`) are stricter, not looser: **at most ONE packet per session**, and if the packet will not fit the launch envelope — litmus-launched sessions live inside a 600s step budget — **split it into smaller ready packets instead of implementing**. The shaping commit is the session's output. Decided by The Tlatoāni 2026-07-10, order 264; canonical: `methodology/distributed-work.yaml` `worker_agent_protocol.forge_cycle_budget`.)
6.  **Delegate Parallelizable Research**: Use sub-agents for file inventories, grep searches, etc., but keep ownership of specs, verification, and commits.

---

## 3 — Claim the Lease

1.  **Mint Lease ID**: Mint a content-stable lease ID.
2.  **Emit Claim Event**: Update the task's YAML block to append a `claim` event under `events:`:
    ```yaml
    - type: claim
      ts: "<ISO-8601-UTC>"
      agent_id: "<your-agent-id>"
      host: "<linux|windows|macos>"
      lease_id: "<your-lease-id>"
      expires_at: "<acquired-at + 4 hours>"
    ```
    Change the task's top-level status to `claimed`.
3.  **Commit & Push**: Commit ONLY the plan file edits, and push them to your active branch:
    ```bash
    git add plan/
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

1.  **Durable Checkpointing**: At meaningful milestones (every 30–45 minutes), write an `agent_status_packet` as a `progress` or `checkpoint` event to the plan file, and commit/push it to `linux-next`.
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
for y in $(git diff --name-only origin/<active-branch>..HEAD | grep -E '\.ya?ml$'); do
  ruby -ryaml -e "YAML.load_file('$y')" || { echo "INVALID YAML: $y"; exit 1; }
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

1.  **Full Verification**: Run the full validation litmus on your platform to confirm zero-drift compliance.
2.  **Emit Completed Event**: Update the task's YAML block:
    -   Append a `completed` event to `events:` listing all commit SHAs and validation log paths.
    -   Flip the task status to `done` in the item header.
    -   Update any local dependency mirror tables in the same pass.
3.  **Commit & Push Ledger**: Commit and push the final plan edits to `origin/<active-branch>`.

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
