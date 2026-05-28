---
name: coordinate-multihost-work
description: Coordinate Tillandsias Linux, Windows, and macOS implementation agents by auditing shared plan/methodology ledgers, analyzing sibling branch git history, reconciling stale work queues, mediating concurrent conflicts or thrashing, tracking convergence velocity metrics, enforcing finite-time convergence guarantees, and pushing coordination updates. Designed to run hourly to ensure continuous cooperation and unblocking.
---

# Coordinate Multi-Host Work

Run a short, durable coordination pass for the Tillandsias Linux, Windows, and macOS implementation agents. The goal is to keep agents unblocked, ensure their sibling `./plan` states cooperate, and strictly guarantee convergence on the specs in finite time.

## Core Rule

Do coordination, spec, plan, methodology, and cheatsheet work. Do not change implementation code unless the blocker is clearly a small coordination-side fix required to unblock agents. Respect dirty worktree changes you did not make.

This skill is also the active runtime orchestrator. If a sibling branch has eligible code ahead of `linux-next`, pull/merge what can be merged, then start or monitor the full runtime litmus run.

---

## Start Of Loop & Sibling Git History Audit

1. **Fetch & Inspect**: Run `git fetch origin`.
2. **Track Sibling Branch Progress**: Fetch and inspect the heads and git commit history of the platform branches:
   - Compare `origin/linux-next`, `origin/windows-next`, and `origin/osx-next` against `origin/main`.
   - Read the git commit log of the last 10 commits on sibling branches to detect concurrent plan or code modifications that might not yet be integrated.
3. **Clean Checkouts**: Prefer `linux-next` for shared coordination files. If already on another branch, do not discard local changes; switch only when clean or safe.
4. **Fetch & Reconcile Ledgers**: Fast-forward/pull the latest `origin/linux-next` before editing. If the remote advanced, fresh-read the changed files:
   - `methodology.yaml`
   - `methodology/distributed-work.yaml`
   - `methodology/convergence.yaml`
   - `plan.yaml`
   - `plan/index.yaml`
   - `plan/loop_status.md`
   - active `plan/issues/*work-queue*`
   - active `plan/issues/*blocker*`
   - active `plan/issues/multi-host-integration-loop-*.md`

---

## Active Coordination & Mediation Audit

In every hourly pass, the orchestrator MUST actively analyze concurrent work and evidence to detect and mediate three critical multi-host alignment problems:

### 1. Deadlocks (Mutual Waiting)
*   **Detection**: Sibling A is blocked on Sibling B's interface/API, while Sibling B is blocked on Sibling A's implementation, configuration, or environment.
*   **Mediation**:
    -   Immediately break the deadlock by defining a minimal, mock-based interface contract or declaring one host as the primary driver.
    -   Repin the blocker to a simplified mock task and update both queues to proceed independently.

### 2. Wrong-Direction Progress (Spec/Methodology Divergence)
*   **Detection**: A sibling is implementing code or plans that deviate from active specs, bypass Caddy/reverse-proxy constraints, or violate the nonblocking/yield-returning policy.
*   **Mediation**:
    -   Freeze the sibling's current lease.
    -   Document the spec gap or divergence in `plan/loop_status.md` and the host's queue file.
    -   Force-assign a corrective "Spec Alignment & Litmus Verification" packet as the next primary task.

### 3. Thrashing (Undo-Loops / Write-Write Collisions)
*   **Detection**: Sibling A and Sibling B are repeatedly overwriting each other's changes, reverting each other's plan notes, or fighting over shared files.
*   **Mediation**:
    -   Freeze both active leases.
    -   Perform a git history analysis (`git log -p -n 5 <shared-file>`) to pinpoint the root conflict.
    -   Enforce the CRDT semantic-merge policy: plan updates are semantic upserts keyed by stable IDs. If code is thrashed, assign a single synchronous conflict-resolution wave to one host and keep the other host on a separate, independent fallback path.

---

## Velocity & Finite-Time Convergence Guarantee

To guarantee convergence in finite time, the orchestrator MUST track and enforce the strictly positive lower bound of convergence velocity ($\mathcal{V}_c \ge \mathcal{V}_{min} > 0$):

1.  **Compute Residual CORRECTNESS Debt ($\mathcal{R}$)**:
    -   $\mathcal{R}$ is measured by the total count of residual named CentiColon obligations plus the number of unimplemented MUST requirements across active specs.
2.  **Calculate Convergence Velocity ($\mathcal{V}_c$)**:
    -   Compare the current $\mathcal{R}$ with the $\mathcal{R}$ from the previous 3 coordination cycles:
        $$\mathcal{V}_c = \frac{\mathcal{R}_{t-3} - \mathcal{R}_t}{\Delta t}$$
3.  **Enforce Minimum Velocity ($\mathcal{V}_{min}$)**:
    -   If $\mathcal{R} > 0$ and $\mathcal{V}_c$ falls below $\mathcal{V}_{min}$ (meaning progress is stalled, slow, or thrashed), trigger a **High-Velocity Alignment Event**:
        -   **Reduce TTL**: Automatically shrink the lease TTL from 4 hours to **1 hour** to force faster heartbeats and rapid handoffs.
        -   **Freeze Feature Work**: Prohibit all new exploratory feature work or optional P3 optimizations.
        -   **Force Blocker Defusal**: Force all active hosts to focus strictly on:
            1. Resolving the root blocker in the blocking tree.
            2. Writing focused litmus tests to prove the boundary of the failing contract.
            3. Completing outstanding verification tasks.

---

## Shape & Assign Actionable Work

-   **Construct the Blocking Tree**: For every blocked item, trace its chain to find "root blockers" (items with the longest downstream chains or longest block durations). Prioritize root blockers above all else.
-   **Unblocking Prioritization**:
    1.  Root blockers that unlock another host's ready items.
    2.  Active deadlocks/thrashing mediation tasks.
    3.  Failed-retryable work with narrow diagnostic chains.
    4.  Ready leaf work in the owning host queue.
-   **No Idle Hosts**: Every active host MUST have at least one claimed or ready unblocked primary packet, plus one named independent fallback packet (e.g. in packaging, docs-distillation, or CI testing) so that a host never sits idle when its primary path is gated.
-   **Assign Stable Work Items**: Each assignment must specify: `id`, `owner_host`, `status`, dependencies, owned files, next concrete action, expected evidence, and `agent_status_packet` expectations.

---

## Integration And Runtime Executor

Run this before ending the loop whenever `origin/windows-next` or `origin/osx-next` is not an ancestor of `origin/linux-next`, or whenever the latest integrated code has not yet been exercised by the full runtime litmus.

1.  **Check Active Async Run**: Read `plan/localwork/runtime-litmus/current`. If alive, record "validation still running" in `plan/loop_status.md` and wait.
2.  **Merge Sibling Branches**: If clean, attempt a real merge of sibling platform branches in a fresh worktree.
3.  **Litmus Execution**: Run the full litmus check on the merged code:
    -   `./build.sh --ci-full --install`
    -   `tillandsias --debug --init`
    -   `tillandsias . --opencode --diagnostics --prompt "$LITMUS_PROMPT"`
4.  **Resolve & Push**: Commit and push successful merges to `origin/linux-next`. On push rejection, fetch, rebase coordination files, and retry up to 3 times.

---

## Loop Status Cache & Reporting

Maintain `plan/loop_status.md` as a short (under 80 lines) quick-start cache:
-   `LastExecutionTime` in UTC
-   Brief summary of this loop (including current Convergence Velocity $\mathcal{V}_c$ and active conflict resolution)
-   High-Velocity Alignment Event status (Active/Inactive)
-   Expected outcomes for the next loop
-   Active Assignment Board (Linux, Windows, macOS primary + fallback)
-   Stale or pending pings

---

## Validation And Commit

-   Validate touched YAML files (`plan.yaml`, `plan/index.yaml`, `methodology/**`) with a focused parser check.
-   Commit and push all coordination updates to `origin/linux-next` immediately before ending the loop.
