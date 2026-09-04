---
name: coordinate-multihost-work
description: Coordinate Tillandsias Linux, Windows, and macOS implementation agents by auditing shared plan/methodology ledgers, analyzing sibling branch git history, reconciling stale work queues, mediating concurrent conflicts or thrashing, tracking convergence velocity metrics, enforcing finite-time convergence guarantees, and pushing coordination updates. Designed to run hourly to ensure continuous cooperation and unblocking.
---

# Coordinate Multi-Host Work

Run a short, durable coordination pass for the Tillandsias Linux, Windows, and macOS implementation agents. The goal is to keep agents unblocked, ensure their sibling `./plan` states cooperate, and strictly guarantee convergence on the specs in finite time.

## Core Rule

Do coordination, spec, plan, methodology, and cheatsheet work. Do not change implementation code unless the blocker is clearly a small coordination-side fix required to unblock agents. Respect dirty worktree changes you did not make.

This skill is also the active runtime orchestrator. If a sibling branch has eligible code ahead of `linux-next`, pull/merge what can be merged, then start or monitor the full runtime litmus run.

Before a successful exit, push every coordination update to `origin/linux-next`.
The local worktree must be clean and not ahead of upstream. If a push cannot be
completed after three fetch/rebase retries, record the failed push as a blocker
via `tillandsias-plan loop-status-append` and stop.

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
   - `plan/index.yaml` (or via `tillandsias-plan query` / `project-plan` MCP tools)
    - `plan/loop_status.md` (or via `tillandsias-plan loop-status` folded view)
    -   **Read the `## Direction` section of `plan/loop_status.md`** (operator-owned
        thematic direction) and reduce cross-host coordination priorities against
        it; cite the direction in coordination ledger entries (order 381).
    - active `plan/issues/*work-queue*`
   - active `plan/issues/*blocker*`
   - active `plan/issues/multi-host-integration-loop-*.md`

---

## Active Coordination & Mediation Audit

In every hourly pass, the orchestrator MUST actively analyze concurrent work and evidence to detect and mediate four critical multi-host alignment problems:

### 1. Deadlocks (Mutual Waiting)
*   **Detection**: Sibling A is blocked on Sibling B's interface/API, while Sibling B is blocked on Sibling A's implementation, configuration, or environment.
*   **Mediation**:
    -   Immediately break the deadlock by defining a minimal, mock-based interface contract or declaring one host as the primary driver.
    -   Repin the blocker to a simplified mock task and update both queues to proceed independently.

### 2. Wrong-Direction Progress (Spec/Methodology Divergence)
*   **Detection**: A sibling is implementing code or plans that deviate from active specs, bypass reverse-proxy constraints, or violate the nonblocking/yield-returning policy.
*   **Mediation**:
    -   Freeze the sibling's current lease.
    -   Document the spec gap or divergence via `tillandsias-plan loop-status-append` and the host's queue file.
    -   Force-assign a corrective "Spec Alignment & Litmus Verification" packet as the next primary task.

### 3. Thrashing (Undo-Loops / Write-Write Collisions)
*   **Detection**: Sibling A and Sibling B are repeatedly overwriting each other's changes, reverting each other's plan notes, or fighting over shared files.
*   **Mediation**:
    -   Freeze both active leases.
    -   Perform a git history analysis (`git log -p -n 5 <shared-file>`) to pinpoint the root conflict.
    -   Enforce the CRDT semantic-merge policy: plan updates are semantic upserts keyed by stable IDs. If code is thrashed, assign a single synchronous conflict-resolution wave to one host and keep the other host on a separate, independent fallback path.

### 4. Divergent Branch Paths (Branch Drift)
*   **Detection**: Sibling branch (`windows-next` or `osx-next`) is accumulating independent commits that are not integrated into `linux-next`.
    -   Measure branch drift count: `git rev-list --count origin/linux-next..origin/<sibling-branch>`.
    -   Trigger Alert if commit count > **$D_{max} = 5$ commits**.
*   **Mediation**:
    -   Freeze the diverging sibling branch's write leases.
    -   Force-assign a primary "Sibling Integration" task to that host: it
        **merges** `origin/linux-next` (and `origin/main`) **into** its own branch
        and resolves there — never rebases/cherry-picks published commits across
        branches (that remints hashes and re-creates duplication; see
        `methodology/multi-host-development.yaml` `integration_strategy`).
    -   Trigger the synchronous orchestrator **merge** of the converged sibling
        branch into `linux-next` and run the litmus suite + Integration
        Verification Gate before push.

---

## Velocity & Finite-Time Convergence Guarantee

To guarantee convergence in finite time, the orchestrator MUST track and enforce the strictly positive lower bound of convergence velocity and upper bounds on commit rates:

1.  **Compute Residual CORRECTNESS Debt ($\mathcal{R}$)**:
    -   $\mathcal{R}$ is measured by the total count of residual named CentiColon obligations plus the number of unimplemented MUST requirements across active specs:
        $$\mathcal{R} = N_{CentiColons} + N_{UnimplementedSpecs} + N_{OpenIssues}$$
2.  **Calculate Convergence Velocity ($\mathcal{V}_c$)**:
    -   Compare the current $\mathcal{R}$ with the $\mathcal{R}$ from the previous 3 coordination cycles:
        $$\mathcal{V}_c = \frac{\mathcal{R}_{t-3} - \mathcal{R}_t}{\Delta t}$$
3.  **Enforce Minimum Velocity ($\mathcal{V}_{min}$)**:
    -   If $\mathcal{R} > 0$ and $\mathcal{V}_c$ falls below $\mathcal{V}_{min} = 1$ correctness unit / hour, trigger a **High-Velocity Alignment Event**:
        -   **Reduce TTL**: Automatically shrink the lease TTL from 4 hours to **1 hour** to force faster heartbeats and rapid handoffs.
        -   **Freeze Feature Work**: Prohibit all new exploratory feature work or optional P3 optimizations.
        -   **Force Blocker Defusal**: Force all active hosts to focus strictly on:
            1. Resolving the root blocker in the blocking tree.
            2. Writing focused litmus tests to prove the boundary of the failing contract.
            3. Completing outstanding verification tasks.
4.  **Enforce Maximum Velocity Cap ($C_{max}$ / Thrashing Prevention)**:
    -   **Detection**: If a host's commit rate exceeds **$C_{max} = 2$ commits/hour** while convergence velocity remains zero or negative ($\mathcal{V}_c \le 0$), a Thrashing Violation is declared.
    -   **Actions**: Enforce a mandatory **1-hour commit cooldown** (blocking remote pushes) and a **Claim Freeze** forcing the host to integrate `linux-next` and verify first.

---

## Shape & Assign Actionable Work

-   **Construct the Blocking Tree**: For every blocked item, trace its chain to find "root blockers" (items with the longest downstream chains or longest block durations). Prioritize root blockers above all else.
-   **Unblocking Prioritization**:
    1.  Root blockers that unlock another host's ready items.
    2.  Active deadlocks/thrashing mediation tasks.
    3.  Failed-retryable work with narrow diagnostic chains.
    4.  Ready leaf work in the owning host queue.
-   **No Idle Hosts**: Every active host MUST have at least one claimed or ready unblocked primary packet, plus one named independent fallback packet (e.g. in packaging, docs-distillation, or CI testing) so that a host never sits idle when its primary path is gated.
-   A host waiting for remote integration MUST be assigned an independent
    fallback unless all eligible work is blocked.
-   **Assign Stable Work Items**: Each assignment must specify: `id`, `owner_host`, `status`, dependencies, owned files, next concrete action, expected evidence, and `agent_status_packet` expectations.
-   **Cross-host recurrence audit** (order 1001-q3zf). The meta-orchestration
    handoff REQUIRES pasting the cycle-metrics output verbatim, which is how
    the `recur:` and `skippable:` lines are meant to reach
    `plan/loop_status.d/`. That is a rule, not an observed behaviour: on
    2026-09-04 only 17 of 353 loop_status entries carried a `timing:` line,
    none carried `recur:`, and the newest entry of every host had none. So
    the audit has two outcomes and BOTH are findings. Once per pass, read the
    NEWEST entry per host — the host set is derived from the file names, not
    a roster that goes stale, and the grep is token-anchored because entries
    arrive bare, as `- recur:` bullets, and inline inside backticked prose
    joined by ` · ` or ` | `, so a `^recur:` grep undercounts. The stem is
    everything after the `<timestamp>z-[<8hex>-]` prefix, NOT the text after
    the last dash: session stems carry dashes of their own
    (`lenovinha-tillandsias-forge`, `macuahuitl-tillandsias-forge`, and a
    bare `forge`), and a last-dash split collapsed all three into one `forge`
    row that read only lenovinha's newest entry while macuahuitl's five
    entries got no row at all (adversarial review, 2026-09-04) — a dropped
    host under-counts the two-or-more-hosts trigger below. Files that do not
    carry the prefix (the README) are not hosts and are skipped:

    ```bash
    for h in $(ls plan/loop_status.d/*.md \
               | grep -E '/[0-9]{8}t[0-9]{6}z-([0-9a-f]{8}-)?[^/]+\.md$' \
               | sed -E 's#.*/[0-9]{8}t[0-9]{6}z-([0-9a-f]{8}-)?##; s/\.md$//' | sort -u); do
      f=$(ls -t plan/loop_status.d/*.md | grep -E "z-([0-9a-f]{8}-)?$h\.md$" | head -1)
      [ -n "$f" ] || continue
      l=$(grep -ho 'skippable: [^`|·]*' "$f" | tail -1)
      echo "$h ${l:-NOT-PASTING ($f)}"
    done
    ```

    Re-run the loop after editing it and confirm every multi-dash stem gets
    its own row; the row count must equal the distinct-stem count.

    An empty result for a host means THAT HOST IS NOT PASTING its
    cycle-metrics — route it as a plain ask to that host ("paste the
    cycle-metrics output verbatim in your handoff"); never read silence as
    "no candidates". Parse a present entry FROM THE RIGHT — step names
    contain colons; the step is everything before the first `:runs=`. When
    the SAME step tops `skippable:` on two or more hosts, file ONE packet to
    memoise or skip it, citing each host's `runs=`, `avg_ms=`, `fail_pct=`
    and `saved_ms_upper=` (a bound, and say so: the log carries no input
    identity, so nobody can claim a run would have hit a cache). Never act
    on one host's reading alone — attach the regime; a step that is
    invariant on a fat host may be the one that fails on a floor host. If
    `recur:` shows a step's cumulative total rising cycle over cycle on every
    host while `skippable:` never names it, that is the outcome-varying
    repeat the tree-digest rung (named in the 1001-q3zf packet's
    next_action) exists to measure; do not guess at it.
-   **Every dispatch MUST carry the credential preflight** (order 982-sguu). A
    dispatched task is an entry path into committable work that does NOT pass
    through the meta-orchestration loop, so it skips that loop's Start-of-Cycle
    credential check. Name this in the message and require it before the host
    starts:

    ```bash
    scripts/check-credential-channel.sh    # blocked:* -> stop and report, do not work
    ```

    WHY THIS IS HERE AND NOT LEFT TO THE HOST. On 2026-09-03 I dispatched a
    floor host a diagnosis ask and told it to skip the loop as a one-off. It
    spent about ninety minutes producing measurements and discovered by a FAILED
    PUSH, after all the work was done, that its upstream refuses writes. Every
    layer of 756-2jnj behaved correctly; the host simply never went through the
    door the guard is nailed to. That is the 2026-08-15 "detection too late"
    shape the guard was built to eliminate, reproduced through a different entry
    path, and the coordinator caused it.

    The guard has ONE production caller in the whole tree
    (`scripts/forge-validate.sh`) and is otherwise a manual step named only in
    the meta-orchestration skill. `scripts/cycle-preflight.sh` does NOT run it —
    it only mentions it in a comment explaining why it does not duplicate the
    message. So a host that never enters the loop never runs it at all.

    A `blocked:*` verdict means STOP AND REPORT, not work-then-discover. The
    cost of skipping this is one host-cycle of finished work that cannot be
    landed, and the coordinator then has to relay it by hand.

---

## Integration And Runtime Executor

Run this before ending the loop whenever `origin/windows-next` or `origin/osx-next` is not an ancestor of `origin/linux-next`, or whenever the latest integrated code has not yet been exercised by the full runtime litmus.

1.  **Check Active Async Run**: Read `plan/localwork/runtime-litmus/current`. If alive, record "validation still running" as a `## Cycle` entry in `plan/loop_status.d/` (via `tillandsias-plan loop-status-append`) and wait.
2.  **Merge Sibling Branches**: If clean, attempt a real merge of sibling platform branches in a fresh worktree.
3.  **Litmus On The MERGED UNION, before anything heavy** (order 754-kptj):

    ```bash
    scripts/run-litmus-test.sh --phase pre-build --size instant --compact
    # or, scoped to what the merge actually changed:
    scripts/run-litmus-test.sh --diff-scope origin/linux-next --compact
    ```

    Record the `PASS:`/`FAIL:` counts and the pass rate as a line in the cycle
    handoff, the same way the guard verdicts are recorded.

    **Why this step exists, and why it is here rather than later.** Litmus
    never ran on the merged union until the release path needed it. On
    2026-08-15 the coordinator merged both sibling branches, each green on its
    own `--check` gate (which runs no litmus at all, 748-tkjx), and the UNION
    failed 9 litmus steps — discovered inside `merge-to-main-and-release`
    STEP 3 while the operator was waiting on a promotion. Each branch was
    honestly green; nobody had run the thing they became together.

    Two caveats that must travel with this step, or it will mislead:

    -   `--diff-scope` **fails CLOSED**. An unannotated test, an unresolvable
        base, a clean tree, or a full-run anchor older than 24h each escalate
        to a FULL run rather than skipping. That is the safe direction, but it
        means the scoped form is not reliably the cheap form.
    -   A run that actually SKIPPED something blocks `build.sh` from writing a
        gate stamp. So this pass informs the coordinator; it does **not**
        substitute for the release gate below.

4.  **Heavy Runtime Litmus**: Run the full runtime check on the merged code:
    -   `./build.sh --ci-full --install`
    -   `tillandsias --debug --init`
    -   `tillandsias . --opencode --diagnostics --prompt "$LITMUS_PROMPT"`
5.  **Resolve & Push**: Commit and push successful merges to `origin/linux-next`. On push rejection, fetch, rebase coordination files, and retry up to 3 times.

---

## Loop Status Cache & Reporting

Maintain the loop-status quick-start cache (under 80 lines per entry) as
`## Cycle` entries: write each entry as a NEW fragment with
`tillandsias-plan loop-status-append --host <host> --ts <ISO>`, and read the
folded view with `tillandsias-plan loop-status` — NEVER edit the shared
`plan/loop_status.md` directly, or a concurrent host's status write conflicts
for the same reason the old monolithic ledger did (packet 582-nqw5):
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
