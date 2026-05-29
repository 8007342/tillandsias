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
    git pull --ff-only
    ```
2.  **Host and Identity**: Identify your platform (`linux`, `windows`, `macos`), your agent name, and your intended capabilities (`rust`, `podman`, `docs`, `testing`, etc.).
3.  **Host Detection Table**:
    | uname/$OS | Platform Name | Canonical Branch |
    |-----------|---------------|------------------|
    | Linux     | `linux`       | `linux-next`     |
    | macOS     | `macos`       | `osx-next`       |
    | Windows   | `windows`     | `windows-next`   |
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
    -   `owner_host` matches your platform or is `any`.
    -   `status` is `ready`, `pending` (if dependencies are unblocked), or `failed-retryable`.
    -   `capability_tags` intersect with your capabilities.
    -   There is no active unexpired lease.
3.  **Selection Priority (Top Wins)**:
    -   **Diagnostics-driven container-start verification** (USER PRIORITY, linux runtime-host today): work that strengthens the `--diagnostics` → annex → distill → litmus chain. See `scripts/forge-diagnostics-annex.sh`, `scripts/distill-forge-diagnostics.sh`, `openspec/litmus-tests/litmus-forge-diagnostics-e2e.yaml`, `methodology/forge-diagnostics.yaml` piggyback_protocol.
    -   **Spec gap fills**: `openspec/specs/<spec>/spec.md` requirements without implementation coverage. Focus on `headless-mode`, `podman-idiomatic-patterns`, `runtime-diagnostics-stream`, `logging-accountability`, `observability-metrics`.
    -   **Drift-protection litmus**: instant-phase tests pinning surfaces that recent work added (formatter literals, env-var contracts, public API names, unit-test names).
    -   **Clippy / idiomatic-podman hardening**.
4.  **Constraint**: ONE logical commit per cycle. If a slice estimates >2h, split it and ship the first half.
5.  **Delegate Parallelizable Research**: Use sub-agents for file inventories, grep searches, etc., but keep ownership of specs, verification, and commits.

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
3.  **Commit & Push**: Commit ONLY the plan file edits to `origin/linux-next`:
    ```bash
    git add plan/
    git commit -m "chore(plan): claim lease for <task-id>"
    git push origin linux-next
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
- **Container security flags are non-negotiable**: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`.
- **Pre-commit hooks and release signing** are not optional.

---

## 6 — Commit, Push & Checkpoint

1.  **Durable Checkpointing**: At meaningful milestones (every 30–45 minutes), write an `agent_status_packet` as a `progress` or `checkpoint` event to the plan file, and commit/push it to `linux-next`.
    -   *Schema requirement*: Include current plan, touched files, partial evidence, and next checkpoint.
2.  **targeted git add**: ONLY stage the intended files:
    ```bash
    git add <specific-files>      # NEVER `git add -A` (cross-host churn)
    git commit -m "<slice-message>"   # cite trace + plan packet + any unblock-noop
    git push origin <active-branch>
    # on non-ff: git fetch && git rebase origin/<active-branch> && push, ≤3x
    ```
3.  **Durable Ledger Update**: Write a one-line outcome to your host's work-queue ledger (`plan/issues/<host>-next-work-queue-*.md`):
    ```
    - 2026-MM-DDTHH:MMZ  <commit-sha>  <one-line summary>
    ```

### Defer Rule
If the 2h integration cron fired in the last 10 min (check the latest `### Cycle` timestamp in `plan/issues/multi-host-integration-loop-2026-05-24.md`), write a no-op ledger entry and exit. The cron's writes need to settle before another work commit lands.

---

## 7 — Submit Completion or Yield

### Submit Completion
1.  **Full Verification**: Run the full validation litmus on your platform to confirm zero-drift compliance.
2.  **Emit Completed Event**: Update the task's YAML block:
    -   Append a `completed` event to `events:` listing all commit SHAs and validation log paths.
    -   Flip the task status to `done` in the item header.
    -   Update any local dependency mirror tables in the same pass.
3.  **Commit & Push Ledger**: Commit and push the final plan edits to `origin/linux-next`.

### Yield & Triage (Failure/Blockage)
1.  **Emit Blocked or Failed Event**: If you encounter an unresolvable error, blocker, or spec gap:
    -   Append a `blocked` or `failed` event to `events:` detailing the exact reason, the named blocker, and the smallest next diagnostic command.
    -   Flip status to `blocked` or `failed` (with `retryable: true|false`).
    -   Commit and push to `origin/linux-next` so the Orchestrator can audit and reschedule it.
2.  **Fallback Selection**: Release your local lease, select your named fallback task, and begin the loop fresh.

---

## Hard Guardrails

- NEVER `git push --force`.
- NEVER push directly to `main` — use PRs. Check `plan/issues/cross-host-blocker-roundup-*.md` for the active `<host>-next → main` PR number before opening a duplicate.
- NEVER push to a sibling host's branch (linux MUST NOT push to `osx-next` or `windows-next`).
- **Velocity Limit Compliance ($C_{max}$)**: Do not push more than **2 commits per hour** if convergence velocity remains zero or negative ($\mathcal{V}_c \le 0$). High-frequency pushing without progress causes thrashing and triggers a 1-hour cooldown.
- **Branch Drift Compliance ($D_{max}$)**: Do not allow your platform branch (`windows-next`, `osx-next`) to drift more than **$D_{max} = 5$ commits** ahead of the common `merge-base` with `linux-next`. If drift exceeds 5 commits, you MUST immediately halt feature work and run a pull-integration and rebase pass.
- NEVER skip hooks or signing.
- `release.yml` / `recipe-publish.yml` workflows are `workflow_dispatch` only — never auto-trigger.
- NEVER resolve cross-host plan conflicts by deletion — tombstone or supersede only.
- When the worktree is dirty, only stage `plan/` files explicitly by path. Implementation code from a previous (uncommitted) iteration is NOT yours to touch.

---

## How Orchestrators Steer this Skill

The canonical file lives at `skills/advance-work-from-plan/SKILL.md`.
Each agent runtime (`.claude/`, `.opencode/`, `.codex/`, `.gemini/`, `.github/`) accesses it via a symlink under its `skills/` directory, so there is exactly one source of truth.

To steer remote agent work between iterations, an orchestrator can:
- Edit the priority list in §2 to elevate a packet for the next cycle.
- Tighten or loosen the defer rule in §6.
- Add a new host row to §1 (e.g. when a freebsd-host comes online).
- Drop or extend the unblock-with-NOOP rule in §4.
