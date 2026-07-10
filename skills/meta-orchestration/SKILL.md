---
name: meta-orchestration
description: "Host-aware Tillandsias recurring runtime loop: sync remote state, drain claimable plan work, run eligible e2e smoke gates, coordinate integrations on mutable Linux, release when warranted, update plan, commit, and push before exit."
---

# Meta Orchestration

This is the top-level unattended loop intended for:

```bash
./repeat --prompt "Use the /meta-orchestration skill"
```

It composes the worker, coordination, e2e, and release skills without replacing
their detailed runbooks.

## Non-Negotiable Exit Contract

Local state is volatile. Before a successful exit, every meaningful result must
be committed and pushed to the correct remote branch.

- No uncommitted tracked changes.
- All temporary local artifacts are considered disposable and MUST be discarded. You must leave a completely clean work state.
- Ensure any `tillandsias` background binaries or test processes are fully terminated.
- No local-only commits.
- No completed work without a `plan/` event or finding.
- No e2e pass/fail without a dated plan report.
- No blocked state without a blocker, owner if known, and smallest next action.
- Explicitly log things that make you slower (e.g., repeated steps, invalidated caches, uncoordinated scripts) into `plan/issues/`.

If a push fails after three fetch/rebase retries, mark the active plan item
`blocked` or `failed-retryable`, include the failed push output, and stop.

## Host Classification

Detect host at the start of every cycle:

- `forge`: Inside the Tillandsias developer forge container (typically detected by checking if `TILLANDSIAS_HOST_KIND` is set to `forge`).
- `linux_immutable`: Linux with `/run/ostree-booted` present or `rpm-ostree` on PATH.
- `linux_mutable`: Linux without the immutable marker (and not inside the forge container).
- `macos`: Darwin.
- `windows`: Windows, MSYS, MINGW, or PowerShell host.

Canonical branches:

- Linux shared/integration: `linux-next`
- macOS code: `osx-next`
- Windows code: `windows-next`
- Release: `main` through PR only

All `plan/`, `methodology/`, `openspec/`, and `cheatsheets/` files consider `linux-next` their canonical home. However, agents working on platform branches (`windows-next`, `osx-next`) MUST commit and push all edits (including plan updates) directly to their active platform branch. The Linux coordinator will merge these branches back into `linux-next` during the `/multihost-orchestration` pass.

## Start Of Cycle

1. Record UTC time, host kind, current branch, worktree path, and sibling heads.
2. `git fetch origin --prune`, then run the Credential Channel Guard below
   before any committable work.
3. If the worktree is dirty at startup, classify it:
   - tracked changes: you have a one-off chance to commit a checkpoint or clean up before doing new work. Start clean.
   - untracked generated artifacts: discard them if not covered by `.gitignore` (update `.gitignore` if necessary). Ensure you start with a clean state.
   - unknown user work: do not overwrite it; record a blocker.
4. Update the active local branch from remote with fast-forward or an explicit
   merge from `origin/linux-next` into the platform branch when appropriate.

## Credential Channel Guard

Run immediately after `git fetch` and before any worker drain or committable
work. The Cowork scheduled-task runtime can inherit dangling session sockets
(`DBUS_SESSION_BUS_ADDRESS`, `SSH_AUTH_SOCK` pointing into a non-existent
`/run/user/<uid>`) so anonymous reads succeed while every `git push` silently
fails for lack of a credential. See
`plan/issues/cowork-headless-credential-isolation-2026-06-20.md`.

Run the executable guard instead of re-deriving the check in prose. 
*(On Windows: ensure you run this via Git Bash, e.g. `& "C:\Program Files\Git\bin\bash.exe" scripts/check-credential-channel.sh`. PowerShell's `bash` alias defaults to an isolated WSL session that lacks host credentials).*

```bash
scripts/check-credential-channel.sh
```

It prints exactly one line matching the falsifiable grammar
`^(ok:[a-z0-9-]+|missing:no-credential-channel)$` and exits `0` when a usable
git-push credential channel is present, non-zero when it is absent. A usable
channel is present when ANY of these holds (the script checks them in order):

- `<git-dir>/.gh-credentials` exists and is non-empty (repo-local store helper), or
- `GH_TOKEN` or `GITHUB_TOKEN` is set in the environment, or
- `gh auth status` succeeds (reachable, unlocked keyring), or
- `TILLANDSIAS_HOST_KIND=forge` is set (forge containers use a transparent git mirror service for authenticated pushes).

Pinned by `litmus:credential-channel-check-shape`. A non-zero exit (verdict
`missing:no-credential-channel`) fails the cycle on its own; do NOT proceed into
worker drain or any committable work. Instead
fail loud: file or update a blocker in `plan/issues/` recording
`blocked: no-credential-channel`, the owner (operator), and the smallest next
action (re-seed `.git/.gh-credentials` via the gh token, or inject `GH_TOKEN`
into the task environment), then stop. Accreting local-only commits that cannot
be pushed violates the Non-Negotiable Exit Contract and is the precise
velocity-killer this guard prevents.

Reads (`git fetch`/`git ls-remote`) succeeding is NOT evidence of a credential
channel — public-repo reads are anonymous. Verify write capability explicitly.

## Reduction Engine

The loop is a reduction engine, not just a worker. Its job is the project's core
principle — **Monotonic Reduction of Uncertainty Under Verifiable Constraints**
(`methodology/philosophy.yaml`). Every cycle must move the system toward a
verifiable implementation of the spec by *reducing* open uncertainty, and must
never let an observed problem evaporate.

### Capture: nothing gets lost

Any time a worker notices "welp, this isn't great" — an inefficiency, a rough
edge, a fragile assumption, an advisory-only guard, a repeated manual step, a
log warning, a deprecation notice — it MUST be filed before the cycle exits.
This is mandatory, not optional (`methodology.yaml` →
`cooperative_work_discipline`; Non-Negotiable Exit Contract → "Explicitly log
things that make you slower"). File it as a dated issue in `plan/issues/`,
classified as one of: `research/`, `exploration/`, `enhancement/`, or
`optimization/`. An unfiled finding is a lost finding and a contract violation.

### Reduce: smaller, simpler, verifiable packets

Filing is only the intake half. Each recurring cycle then *reduces* open
findings:

1. Pick the highest-value open finding that fits this host's capability.
2. Split it into the smallest packet that closes a slice of it under a
   **verifiable constraint** — a litmus test, an executable check returning a
   pass/fail exit code, or a parser/validator — never prose intent alone. A
   guard only an attentive agent honors is a suggestion, not a constraint;
   reduce it to something that fails loud on its own.
3. Promote that packet into `plan/index.yaml` as a `ready` node with a named
   verifiable closure, then drain it when a capable host can produce evidence.
4. When the verifiable check passes, the slice is retired; re-derive the
   remaining residual and repeat.

Reduction is monotonic: each step must lower residual uncertainty or preserve it
while increasing verification level (`convergence.yaml` → `drift_control`). A
"reduction" that adds ambiguity or removes a validated invariant is drift and
must be rejected. Shaping a finding into a well-formed `ready` packet *is* a
valid reduction step when the current host cannot yet implement it.

### Raising the bar is Tlatoāni-gated (do not self-escalate)

The scan bar is a fixed, declared depth. Reducing all open findings to zero **at
the current bar is a legitimate, clear convergence point** — a fixed point of
the refinement operator — not premature convergence. The loop MUST NOT raise the
bar on its own. Autonomous bar-raising would make the convergence point
undefined (the loop could never report "done"), which is exactly the failure
this rule prevents. See `methodology/convergence.yaml` → `bar_raise_governance`.

What the loop does as it approaches zero residual at the current bar:

1. Keep reducing open findings at the current bar until none remain.
2. Then *propose* bar-raise candidates — file them as `research/` or
   `exploration/` issues describing the deeper scan that could be enabled (e.g.
   treat build/test/runtime warnings, non-fatal errors, deprecation notices,
   flaky-test signals, slow steps, or stale caches as findings). A proposal is a
   candidate, not an enabled scan.
3. STOP there. Enabling any bar-raise — actually treating a deeper signal class
   as findings — is an explicit, one-off decision that **The Tlatoāni must
   approve every time.** Record the approval (who/when/scope) before the deeper
   scan becomes part of the loop's contract.

Rationale: much of the system is "build what works, then improve from there," so
each bar-raise is a deliberate scope expansion the operator owns, not an
emergent behavior. Automatable approval of *some* low-risk bar-raises may come
later; until The Tlatoāni declares such a policy, every bar-raise is manual.
Reaching zero at the current bar and filing bar-raise candidates is a complete,
successful cycle — not an excuse to escalate unprompted.

See `plan/issues/meta-orch-enhancement-opportunities-2026-06-20.md` for a worked
example of capture → reduce → promote.

## Worker Drain

When choosing the builder role, run `/advance-work-from-plan` repeatedly in a `./plan` friendly way in fresh cycles until one of these is true:

- no eligible ready work remains for this host;
- every eligible item is blocked;
- a terminal failure was filed;
- the current cycle has already produced a coherent commit and the next packet
  would exceed the recurring-loop budget.

Forge-hosted cycles (`TILLANDSIAS_HOST_KIND=forge`) are the OPPOSITE of
greedy — decided by The Tlatoāni 2026-07-10 (order 264), replacing the earlier
"drain as many as possible" exception:

- Drain **at most ONE packet per forge cycle**.
- Before implementing, estimate whether implement+verify+commit+push fits the
  launch envelope (litmus-launched forge cycles live inside
  `litmus:opencode-prompt-e2e-shape` STEP 3's 600s budget).
- If it does not fit, do NOT start implementing: **split** the packet into
  smaller ready child packets (`split_into` pattern), record the shaping
  events, commit and push. The shaping commit IS that cycle's completed work —
  a split that lowers residual ambiguity is a valid reduction step.
- Canonical statement: `methodology/distributed-work.yaml`
  `worker_agent_protocol.forge_cycle_budget`. Interim reliance on step
  timeouts is tracked by order 265 (forge heartbeat/liveness signals).

Each worker cycle must obey the non-negotiable exit contract above.

### Node-Closure Claim (avoid duplicated ledger-hygiene work)

Before re-deriving and closing or hygiene-editing a `plan/index.yaml` node,
claim it so a concurrent cycle does not independently produce the identical edit
(the idempotent-but-wasteful collision recorded in
`plan/issues/agent-concurrency-collisions-2026-06-20.md`). Run the executable
claim instead of eyeballing the ledger:

```bash
scripts/claim-ledger-node.sh claim <node-id>   # e.g. release-nix-cache-ref-scoping/choose-approach
```

It emits exactly one line matching
`^(claimed|reclaimed|in-flight|released|free):[a-z0-9._/-]+$` and exits `0` when
this cycle owns the node (`claimed:`/`reclaimed:`) or non-zero (`in-flight:`)
when a live lease is held elsewhere — in which case skip that node and pick the
next eligible one. The lease is an advisory, CRDT-friendly reservation, not a
mutex on the file: it respects the stable-ID + idempotent-merge preconditions in
`methodology/between-commits-work-discipline.yaml`, so a missed or expired lease
never corrupts state (at worst two cycles converge on the same safe edit).
Release with `scripts/claim-ledger-node.sh release <node-id>` after the closure
is committed; expired leases (default TTL 4h) are auto-reclaimed. Pinned by
`litmus:ledger-node-claim-shape`.

## E2E Gates

Run eligible e2e gates after worker drain:

| Host kind | Local-build e2e | Curl-install e2e |
|---|---:|---:|
| linux_immutable | no | yes |
| linux_mutable | yes | yes |
| macos | yes | yes |
| windows | yes | yes |

Before running any local-build e2e gate, consult the structured host-eligibility
verdict instead of re-deriving the skip reason in prose: run
`scripts/e2e-preflight.sh eligibility`, which prints exactly one line matching
`^(eligible|skip:[a-z0-9-]+)$`. Proceed with the local-build gate only on
`eligible`; on any `skip:<reason>` (e.g. `skip:no-podman-user-session` in the
Cowork sandbox, which has no `/run/user/<uid>`, or `skip:smoke-lock-held` when a
parent/local sibling smoke already owns the host lock) record the verdict once
and skip the local-build gate without re-litigating it. Pinned by
`litmus:e2e-eligibility-probe-shape`.

Rules:

- Local-build e2e uses `/build-install-and-smoke-test-e2e`.
- Published-release e2e uses `/smoke-curl-install-and-test-e2e`.
- Destructive substrate reset is expected setup on Tillandsias smoke hosts.
  `podman system reset --force` is a precondition for Linux idempotence tests,
  not a blocker. Do not pause, ask for confirmation, or skip the e2e gate for
  fear of wiping Podman when `TILLANDSIAS_DESTRUCTIVE_RESET_OK` is unset or `1`.
  Only treat reset as blocked when the environment explicitly sets
  `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`.
- If the plan records a latest tested release older than the current GitHub
  release, prioritize curl-install e2e.
- File every finding as a plan packet; write a PASS report for clean runs.

## Mutable Linux Coordinator Duties

Only `linux_mutable` performs global coordination:

1. Run `/multihost-orchestration` after worker drain or when sibling branches
   advanced.
2. Merge eligible `origin/windows-next` and `origin/osx-next` work into
   `linux-next`, with explicit conflict mediation if needed.
3. Run more frequent local-build e2e gates than other hosts.
4. Run `/merge-to-main-and-release` only when `linux-next` is green, plan
   evidence is current, and no release is already in flight.
5. After a release succeeds, ensure the plan records the new latest release so
   immutable Linux hosts know to run curl-install e2e.

## Finalization

Before exit:

1. Reduction-engine capture check: confirm every "this isn't great" observation
   from this cycle is filed in `plan/issues/` (classified `research/`,
   `exploration/`, `enhancement/`, or `optimization/`) and, where reduced,
   promoted to a `plan/index.yaml` packet. An unfiled finding blocks exit.
2. Refresh `plan/index.yaml` and `plan/loop_status.md` if this cycle
   changed active work, blockers, tested release, or host assignments.
3. Validate touched YAML with a parser. The approved validator is
   `tillandsias-policy validate-yaml <files>` where built, with
   `ruby -ryaml -e "YAML.load_file('<file>')"` as the sanctioned fallback.
   Python is not permitted for committed automation (see
   `plan/issues/meta-orch-enhancement-opportunities-2026-06-20.md` order 63).
4. Commit targeted files only.
5. Push the relevant branch.
6. Confirm `git status --short --branch` is clean and not ahead of upstream.
