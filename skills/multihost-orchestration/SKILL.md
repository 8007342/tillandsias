---
name: multihost-orchestration
description: Coordinate Tillandsias Linux, Windows, and macOS implementation agents by auditing shared plan/methodology ledgers, analyzing sibling branch git history, reconciling stale work queues, mediating concurrent conflicts or thrashing, tracking convergence velocity metrics, enforcing finite-time convergence guarantees, and pushing coordination updates. Designed to run hourly to ensure continuous cooperation and unblocking.
---

# Multi-Host Orchestration

This skill is the authoritative entry point for **Orchestrator Agents** executing scheduled or on-demand multi-host coordination passes. Its purpose is to synchronize development efforts across platform-specific branches (`linux-next`, `windows-next`, `osx-next`), detect and actively mediate thrashing and deadlocks, calculate progress metrics, and strictly guarantee convergence on active specifications in finite time.

---

## 1. Start of Loop & Sibling Git History Audit

An orchestrator run must always begin by establishing deep visibility into the remote state of all platform branches. You must never assume the local workspace represents the current state of concurrent work.

1.  **Fetch Sibling Heads**: Fetch updates from origin to inspect the exact tip of all sibling branches:
    ```bash
    git fetch origin
    ```
2.  **Audit Sibling Branch Tips**: Map the current heads of the primary platform branches:
    ```bash
    git ls-remote origin refs/heads/main refs/heads/linux-next refs/heads/windows-next refs/heads/osx-next
    ```
3.  **Track Sibling Commit Histories**: Analyze the last 10 commits of each platform branch to extract concrete evidence of work, assess local-remote drift, and identify unintegrated platform changes:
    ```bash
    git log -n 10 --oneline origin/linux-next
    git log -n 10 --oneline origin/windows-next
    git log -n 10 --oneline origin/osx-next
    ```
4.  **Ancestry / Fast-Forward Check**: Validate that platform branches are cleanly descending from the shared main integration source or each other before performing merges. To check if `origin/<platform-branch>` is an ancestor of the target ref, execute:
    ```bash
    git merge-base --is-ancestor origin/<platform-branch> <target-ref>
    ```
    -   *If the check succeeds*: The branch is a pure ancestor and can be fast-forwarded or integrated without conflict.
    -   *If the check fails*: A sibling host has pushed independent, divergent work. Do not attempt a blind fast-forward or merge. Proceed immediately to **Section 4: Conflict & Divergence Mediation** to resolve the conflict.

---

## 2. Shared Plan & Queue Reconciliation

The durable source of truth for the workspace is the shared ledger in the repository, not the local runtime memory or chat history.

1.  **Pull Latest Ledger**: Ensure you are on `linux-next` and pull the latest coordinated plan edits:
    ```bash
    git checkout linux-next
    git pull --ff-only origin linux-next
    ```
2.  **Read Coordinated Files**: Load and analyze the core coordination state files:
    -   `methodology.yaml`: Core rules, path definitions, and skill registration.
    -   `methodology/distributed-work.yaml`: Rules of agent execution, leases, and protocol requirements.
    -   `plan.yaml`: High-level milestone trackers and continuation policies.
    -   `plan/index.yaml`: Complete task list, dependency mappings, and step details.
    -   `plan/loop_status.md`: Live dashboard of active coordination cycles.
3.  **Audit Active Work Queues**: Inspect per-host work queues to verify lease timestamps, progress notes, and completion logs:
    -   `plan/issues/linux-headless-spec-gaps-2026-05-27.md`
    -   `plan/issues/windows-next-work-queue-2026-05-25.md`
    -   `plan/issues/osx-next-work-queue-2026-05-25.md`
    -   `plan/issues/cross-host-blocker-roundup-*.md`
4.  **Reconcile Stale Leases**:
    -   Compare the `expires_at` timestamp of every active lease against the current UTC time.
    -   If an active lease has expired without a recorded progress or completed event, **reclaim the lease**:
        -   Append a `lease-reclaimed` event to the task logs.
        -   Reset the task status to `ready` or `failed-retryable`.
        -   Document the reclamation reason in `plan/loop_status.md` to flag the stalling host.

---

## 3. Prioritizing Tasks & Shaping the Blocking Tree

To optimize execution velocity and avoid host starvation, the orchestrator must maintain an active dependency graph of all planned work.

1.  **Construct the Blocking Tree**:
    -   Trace all active tasks back through their `depends_on` chains.
    -   Compute the *dependency depth* (number of down-stream tasks blocked) and *block duration* (time since the blocker became `ready`) for every blocking task.
    -   Identify the **Root Blockers** (nodes with the highest depth or longest stall times).
2.  **Prioritize Root Blockers**:
    -   Root blockers that unlock ready tasks on other sibling hosts must receive the highest priority.
    -   If a root blocker is unclaimed, immediately assign it to an eligible host with matching capability tags.
3.  **Implement the "No Idle Hosts" Rule**:
    -   Every active platform host must be assigned:
        1.  **One Primary Task**: The highest-priority ready work item in its queue that is currently unblocked.
        2.  **One Named Fallback Task**: A separate, completely independent ready task (e.g., unit test writing, documentation distillation, linter fixes, packaging preparation) that the host can immediately switch to if its primary path becomes blocked by another host.
4.  **Shape Stable Packets**:
    -   Ensure each assigned task represents a bounded, logical unit of work (estimable under 2 hours).
    -   Each task assignment must explicitly define:
        -   `id`: Unique stable identifier.
        -   `owner_host`: Canonical host platform (`linux`, `windows`, `macos`, or `any`).
        -   `status`: Status of the task (typically `ready`).
        -   `owned_files`: Specific file paths or modules the host is authorized to write to.
        -   `next_action`: Concrete, falsifiable implementation step.
        -   `expected_evidence`: The litmus tests or unit tests that will prove correctness.

---

## 4. Conflict, Thrashing, and Divergence Mediation

When multiple agents work concurrently, drift and collisions are inevitable. The orchestrator must actively audit histories and mediate issues across four distinct patterns:

### Pattern A: Deadlocks (Mutual Waiting)
*   **Detection**: Sibling A is waiting on Sibling B to deliver an API, socket connection, or interface, while Sibling B is waiting on Sibling A's environment setup or configuration.
*   **Mediation**:
    1.  Immediately freeze both active leases to stop futile loops.
    2.  Break the mutual wait by defining a minimal, mock-based interface contract (e.g. static JSON mocks, hardcoded socket test fixtures, or dummy CLI returns).
    3.  Repin the blocker to a simplified "Implement Interface Mock" task.
    4.  Update both queues to proceed independently, delaying full E2E integration until the mock-backed implementations are individually verified.

### Pattern B: Wrong-Direction Progress (Spec/Methodology Divergence)
*   **Detection**: Sibling C is implementing code, routes, or configurations that deviate from active specifications (e.g., bypassing proxy constraints, ignoring security flags like `--cap-drop=ALL`, using raw subprocesses instead of the `PodmanClient` layer, or violating non-blocking event loops).
*   **Mediation**:
    1.  Immediately freeze the sibling's current lease.
    2.  File a clear, descriptive issue in `plan/issues/` highlighting the exact spec requirement being violated.
    3.  Force-assign a corrective "Spec Alignment & Litmus Verification" task as the host's next primary action.
    4.  Prohibit the host from resuming feature implementation until the corrective task is completed and verified green.

### Pattern C: Thrashing (Undo-Loops & Write-Write Collisions)
*   **Detection**: Sibling A and Sibling B are repeatedly overwriting each other's changes in shared modules, fighting over identical lines in `plan.yaml`/`plan/index.yaml`, or repeatedly rebasing and force-pushing over each other's checkpoints.
*   **Mediation**:
    1.  Freeze active leases on both hosts immediately.
    2.  Perform a git history analysis on the thrashed file(s) to isolate the conflict:
        ```bash
        git log -p -n 5 <thrashed-file>
        ```
    3.  Enforce the CRDT semantic-merge policy: all plan/ledger updates are semantic upserts keyed by stable task IDs. No host may delete another host's notes or tasks; they must be tombstoned or marked `obsoleted` with an explanatory note.
    4.  If implementation code is thrashed, assign a single synchronous conflict-resolution wave to one host and place the other host on an independent fallback path until the merge is completed.

### Pattern D: Divergent Branch Paths (Branch Drift)
*   **Detection**: A sibling branch (`windows-next` or `osx-next`) is accumulating independent commits that are not integrated into the main integration branch (`linux-next`).
    -   To measure branch drift distance, the orchestrator calculates the number of commits on `origin/<sibling-branch>` since its common ancestor `merge-base` with `linux-next`:
        ```bash
        git rev-list --count origin/linux-next..origin/<sibling-branch>
        ```
    -   If the commit count exceeds **$D_{max} = 5$ commits**, a Divergence Alert is triggered.
*   **Mediation**:
    1.  **Lock Remote Pushes**: Temporarily lock or freeze the diverging sibling branch's write leases.
    2.  **Forced Integration**: Force-assign a primary "Forced Branch Rebase & Sibling Integration" task to that host, prohibiting it from executing any new features.
    3.  **Orchestrated Merge Loop**: The orchestrator triggers an immediate synchronous merge of the sibling branch into `linux-next` using a clean integration worktree, running the full litmus suite to identify code or runtime conflicts.

---

## 5. Convergence Velocity & Finite-Time Convergence Guarantee

To guarantee convergence in finite time, the orchestrator must mathematically track the rate of progress, apply velocity limits to prevent high-frequency churn, and invoke strict alignment events when progress stalls.

### 1. Compute Residual CORRECTNESS Debt ($\mathcal{R}$)
$\mathcal{R}$ is the count of all unresolved issues, open CentiColon (`// TODO:;`) obligations, and unimplemented `MUST` requirements in the active specifications:
$$\mathcal{R} = N_{CentiColons} + N_{UnimplementedSpecs} + N_{OpenIssues}$$

### 2. Calculate Convergence Velocity ($\mathcal{V}_c$)
At each coordination cycle, compute the rate of change of $\mathcal{R}$ over the last 3 loops (typically 3 hours):
$$\mathcal{V}_c = \frac{\mathcal{R}_{t-3} - \mathcal{R}_t}{\Delta t}$$

### 3. Enforce Minimum Velocity ($\mathcal{V}_{min}$)
If $\mathcal{R} > 0$ and the velocity drops below the minimum required progress rate ($\mathcal{V}_c < \mathcal{V}_{min} = 1$ correctness unit / hour), the orchestrator **MUST** trigger a **High-Velocity Alignment Event**:
*   **Action 1: Shrink Lease TTL**: Automatically reduce the lease TTL from 4 hours to **1 hour** to accelerate the feedback and handoff loop.
*   **Action 2: Freeze Feature Work**: Strictly prohibit all new exploratory feature development, non-essential refactoring, or optional P3 optimizations.
*   **Action 3: Force Blocker Defusal**: Force all active hosts to focus 100% of their compute on:
    1.  Resolving the active root blocker in the blocking tree.
    2.  Writing focused, isolated litmus tests to pin down the failing contract boundary.
    3.  Completing outstanding platform-specific verification tasks.

### 4. Enforce Maximum Velocity Cap ($C_{max}$ / Thrashing Prevention)
To prevent high-frequency write-write conflicts (thrashing) without real progress:
*   **Detection**: If a host's commit rate exceeds **$C_{max} = 2$ commits/hour** while the convergence velocity remains zero or negative ($\mathcal{V}_c \le 0$), a Thrashing Violation is declared.
*   **Action 1: Velocity Cooldown**: The orchestrator enforces a mandatory **1-hour commit cooldown** on the violating host. The host's remote pushes are blocked during this time.
*   **Action 2: Claim Freeze**: Freeze all new task claims by the host. The host is forced to pull, integrate, and verify the latest `linux-next` changes before resuming any active work.

---

## 6. Sibling Integration & Litmus Execution Loop

When a sibling platform branch (`windows-next` or `osx-next`) contains completed code that is ahead of `linux-next`, the orchestrator must integrate and validate the code.

1.  **Check Active Async Runs**: Inspect `plan/localwork/runtime-litmus/current` to verify if a validation run is already in progress. If alive, record "Validation active" in the ledger and yield.
2.  **Clean Workspace Check**: Ensure the local worktree is clean before attempting sibling integration:
    ```bash
    git status --porcelain
    ```
3.  **Merge Sibling Branch**: Create a temporary integration worktree or branch, and merge the sibling branch into the target integration tip:
    ```bash
    git merge --no-ff origin/<sibling-branch> -m "coord(integration): merge origin/<sibling-branch> into linux-next"
    ```
    -   *If the merge encounters conflicts*: Apply conflict mediation (Section 4, Pattern C), resolve manually, or abort and assign a conflict-resolution packet to the owning host.
4.  **Execute the Litmus Suite**: Validate the integrated codebase by running the full verification suite:
    -   **Full Workspace Build & Test**:
        ```bash
        ./build.sh --ci-full --install
        ```
    -   **Durable Init Verification**:
        ```bash
        tillandsias --debug --init
        ```
    -   **E2E Diagnostics Litmus**: Verify diagnostics capture, formatting, and distillation:
        ```bash
        tillandsias . --opencode --diagnostics
        ```
5.  **Commit and Push Merges**: Upon successful verification, push the integrated tip to origin:
    ```bash
    git push origin linux-next
    ```

---

## 7. Reporting & Handoff Preparation

Every coordination pass must conclude by updating the live dashboard and pushing the ledger so that the next agent can resume work with a clean, cold-start state.

1.  **Update `plan/loop_status.md`**: Rewrite the coordination dashboard (keeping it concise, under 80 lines):
    -   `LastExecutionTime`: Timestamp in UTC.
    -   `Convergence Velocity`: Current $\mathcal{V}_c$ and High-Velocity Alignment Event status.
    -   `Active Conflicts & Mediation`: Current deadlock/thrashing notes and resolutions.
    -   `Assignment Board`: Explicit primary + fallback assignments for Linux, Windows, and macOS.
    -   `Stale/Pending Pings`: List of stale leases or overdue sibling branch pulls.
2.  **Commit ledger Files**:
    ```bash
    git add plan/ methodology/
    git commit -m "chore(coord): multi-host coordination cycle <UTC-Timestamp>"
    git push origin linux-next
    ```
3.  **Continuous Heartbeat**: If running in repeat mode (`./codex --repeat <duration>`), sleep until the next scheduled iteration and repaint the progress graph.
