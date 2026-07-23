---
title: Meta-orchestration technique audit — landing trains, durable delegation, and forge workspace preflight
status: proposed-for-upvote
kind: optimization
filed_at: 2026-07-23T05:26:38Z
filed_by: forge-forge-tillandsias-codex-20260723T0526Z
host: forge
active_release: v0.4
scope: process proposals only; no runtime or methodology change
---

# Meta-orchestration technique audit — 2026-07-23

## Disposition

This is an evidence-backed proposal intake, not an adopted rule and not a claim
that today's cycle failed. Each proposal below has an independent stable ID and
must be upvoted or accepted before another agent promotes it into a `ready`
`plan/index.yaml` packet or edits methodology. No index node is added in this
commit: `methodology/distributed-work.yaml` promotes a finding after it has been
reduced into accepted shaped work, while the requested deliverable here is a set
of proposals for other agents to evaluate.

Related existing intake remains canonical and should be extended rather than
duplicated:

- `plan/issues/methodology-concurrent-integration-duplication-2026-06-28.md`
  owns the post-integration verification rule and merge/rebase distinction.
- `plan/archive/agent-concurrency-collisions-2026-06-20.md` records prior
  duplicate ledger work.
- `plan/issues/ccr-branch-scoped-ledger-claims-invisible-2026-07-06.md` owns
  cross-host invisible-lease research.
- `plan/issues/forge-image-sanctioned-yaml-validator-gap-2026-07-16.md` already
  owns the absent sanctioned-validator finding; this audit does not re-file it.

## Scope, sources, and limits

Selected bootstrap intent: `methodology_refinement`. Governing sources read:
`skills/meta-orchestration/SKILL.md`,
`skills/advance-work-from-plan/SKILL.md`,
`methodology/distributed-work.yaml`,
`methodology/multi-host-development.yaml`,
`methodology/between-commits-work-discipline.yaml`,
`methodology/agent-observability.yaml`, and `methodology/ci.yaml`.

Evidence sources:

- `git log --all --since=2026-07-23T03:30:00Z`;
- local reflogs for `linux-next`,
  `agent/opencode-vault-auth-20260723`, and
  `agent/git-mirror-credential-lifecycle-424`;
- current `plan/index.yaml` events for the v0.4 packets;
- in-session child-agent status/final messages;
- the final verification receipts reported by those agents; and
- live forge filesystem/tool probes during this audit.

Limits:

- Reflogs are local, expiring evidence. Commit ancestry and current plan events
  are durable; exact remote update times and intermediate rewritten hashes are
  not.
- Agent-message evidence is explicitly identified below; it is not presented as
  independently reconstructable from Git.
- The audit observed no push rejection and no merge conflict in the reviewed
  window. It therefore proposes reducing avoidable rebases and invalidated
  verification, not weakening conflict handling.
- No claim is made that every test repetition was unnecessary. The first
  post-integration headless run found two real stale assertions; only the
  subsequent no-defect repetition count is questioned.

## What worked

- The operator's instruction not to use `./repeat` was converted immediately
  into durable, tested guidance in `131dfc38`.
- Independent work used isolated worktrees and eventually landed in a safe
  sequence: Windows probe safety `148a9076`, OpenCode Vault auth `3df90b4d`,
  then mirror credential lifecycle `dcafd59c`.
- The mirror packet semantically reconciled the overlapping OpenCode role and
  mount changes instead of taking an automatic textual resolution.
- Every reported final push followed a green `./build.sh --check`; the mirror
  lane also re-ran its full post-rebase test and litmus closure.
- Order 424 remained `in_progress` for the unavailable real-Podman/Vault
  max-TTL proof. The forge did not manufacture live-host evidence.
- Remote parity was verified after the reviewed pushes.

## Evidence timeline

| UTC | Evidence | Technique signal |
|---|---|---|
| 03:53 | `131dfc38` | Root completed the explicit human-only `repeat` packet. |
| 04:03–04:20 | freshness commit `063ca060 -> 1ae3d640 -> 9a858fab -> e71634e9` | One bookkeeping change was replayed by three same-branch rebase finishes while concurrent work landed. No conflict or rejected push was observed. |
| 04:03–04:12 | `119c0b3f` then `3b8418fd` | Desired-release work used a durable claim commit before its completion commit. |
| 04:32–04:44 | `98c07544`, `8b98f93a`, `98fe6f9c` | Root landed three additional code/ledger outcomes during the same forge invocation. |
| 04:43–05:21 | order 424 author time, claim event, and final push | The implementation commit was authored at 04:43:11; its claim event says 04:44:10; neither claim nor work was visible on `origin/linux-next` until `dcafd59c` landed at 05:21. |
| 04:43–05:13 | order 424 branch reflog | Five rebase finishes occurred. One briefly rebased onto unpublished OpenCode intermediate `a682c615`, then 14 seconds later onto the actual remote commit `3df90b4d`. The stale candidate was not pushed. |
| 04:32–05:07 | order 431 branch reflog | Three rebase finishes occurred: one for its claim and two around implementation landing. |
| after root handoff at `98fe6f9c` | in-session agent-status snapshot | Root returned a user-facing final while Windows, OpenCode, and mirror workstreams were still active; their durable commits landed later at 05:05, 05:08, and 05:21. |
| post-integration lock diagnosis | in-session verification receipts | Parent ran the focused lock case five times; the audit child reported 100 separate-process focused runs plus 12 unit-binary repeats. No production lock defect reproduced. |
| 05:26 audit setup | `df` plus failed `git worktree add` | `/tmp` was a 256 MiB tmpfs with 249 MiB used and 7.2 MiB free. Three approximately 61 MiB worktrees occupied it; a fourth checkout failed with repository-wide `unable to write file`. The same checkout succeeded under `/home/forge/worktrees` on the 932 GiB-free overlay. |
| 05:31 audit probe | `command -v` | `ruby`, `tillandsias-policy`, and `sccache` were absent; `yq` and `cargo` were present. The validator portion is already filed in the existing forge-image issue named above. |

## MOT-01 — Coordinator landing train

- **Proposal status**: proposed-for-upvote
- **Target methodology section**:
  `methodology/distributed-work.yaml` → `agent_execution_roles` and
  `methodology/multi-host-development.yaml` → `pull_merge_cadence`
- **Finding**: coordinator bookkeeping began while a worker wave was still
  landing. The freshness update was rebased three times over 17 minutes. The
  final content was correct, but each rewrite changed its candidate SHA and
  delayed a durable checkpoint.
- **Proposed rule**: for a declared worker wave, assign an ordered landing train
  for overlapping/shared scopes. Workers remain parallel while implementing,
  but the coordinator defers non-urgent bookkeeping until the wave's publish
  barrier. The coordinator then lands bookkeeping once against the collected
  remote heads. Urgent safety fixes may preempt the train with a recorded
  reason.
- **Cross-context applicability**: any multi-agent Git repository with one
  shared integration branch and append-heavy coordination files.
- **Measurable adoption gate**: over three multi-worker cycles, record
  `landing_train_id`, ordered packet IDs, and published SHAs; a coordinator
  bookkeeping commit should require at most one same-branch rebase before push.
  Every post-rebase push still runs the existing mandatory integration gate.
- **Counterarguments / limits**: a barrier can serialize independent work or
  delay an urgent correction. Apply it only to shared/overlapping scopes and
  allow explicit preemption. This proposal does **not** cache or skip the final
  `./build.sh --check`.

## MOT-02 — Remote-durable delegation handshake and one landing owner

- **Proposal status**: proposed-for-upvote
- **Target methodology section**:
  `methodology/distributed-work.yaml` → `agent_self_assignment_protocol`,
  `worker_agent_protocol.claim_lease`, and
  `methodology/agent-observability.yaml` → `agent_to_agent_messages`
- **Finding**: order 424's durable claim arrived with its finished
  implementation, so siblings could not observe ownership while it was being
  edited. The downstream agent also consumed an unpublished intermediate
  OpenCode SHA before the designated upstream agent pushed its final SHA.
- **Proposed rule**: delegation is acknowledged only after a claim event is on
  `origin/linux-next`. Each dependency edge names exactly one `landing_owner`.
  A child may report `implementation_complete_local`, but downstream
  integration waits for `published:<branch>:<sha>` from that owner. Agents must
  not rebase onto another worktree's local or rewritten SHA.
- **Cross-context applicability**: agent swarms, CI fan-out, and human/agent
  pairs where local completion is not remote durability.
- **Measurable adoption gate**: a policy check verifies that a packet's first
  implementation commit is descended from a remote commit containing its live
  claim, and every declared sequential dependency records a published SHA
  before downstream integration. A fixture must reject a local-only dependency
  SHA.
- **Counterarguments / limits**: claim-only commits add latency and ledger
  traffic, especially for a sub-minute edit. A future design may provide a
  remote advisory lease outside the branch, but hidden chat or a local
  worktree ref is not an equivalent substitute.

## MOT-03 — Orchestrator final-response join barrier

- **Proposal status**: proposed-for-upvote
- **Target methodology section**:
  `skills/meta-orchestration/SKILL.md` → `Non-Negotiable Exit Contract` and
  `Finalization`; `methodology/agent-observability.yaml` → handoff schema
- **Finding**: the root agent returned a final at `98fe6f9c` while three
  delegated streams remained active. All three later produced useful durable
  commits, but the user-facing terminal message preceded the requested work's
  durable outcome.
- **Proposed rule**: a successful orchestrator final must either join every
  in-scope child to a terminal remote-durable state or emit an explicit durable
  transfer record per child. A status update may be sent while children run,
  but it is not the terminal response.
- **Cross-context applicability**: any parent/child agent runtime where a parent
  can terminate independently of children.
- **Measurable adoption gate**: the orchestrator's final receipt includes
  `active_children: []`, or a list in which every child has
  `state: handed_off|terminal`, `owner`, `branch`, `checkpoint_sha`, and
  `next_action`. A harness test with a deliberately late child asserts that
  success is not emitted before one of those states exists.
- **Counterarguments / limits**: a long-running child should not hold an
  interactive session open forever. The explicit handoff path is the bounded
  escape; silently returning while work remains is not.

## MOT-04 — Make nested forge-cycle accounting explicit

- **Proposal status**: proposed-for-upvote
- **Target methodology section**:
  `methodology/distributed-work.yaml` → `worker_agent_protocol.forge_cycle_budget`
  and `agent_execution_roles`
- **Finding**: the current text says a forge cycle drains at most one packet,
  while this operator-directed orchestrator correctly fanned out several
  one-packet child workers and also completed multiple root-owned packets. It is
  unclear whether the budget attaches to the root invocation, each worker, or
  only the 600-second e2e-launched envelope.
- **Proposed rule**: add `cycle_id`, `parent_cycle_id`, `role`, and
  `budget_class` (`bounded_e2e`, `interactive_operator`, or other adopted
  classes). Preserve one packet per **worker** cycle. Define separately how
  many root-owned packets an orchestrator may implement versus delegate, and
  require an operator override to be recorded when the root exceeds that
  budget.
- **Cross-context applicability**: nested agent trees and orchestrators that
  dispatch workers under different wall-time/token envelopes.
- **Measurable adoption gate**: three consecutive forge orchestration receipts
  can be mechanically folded by cycle ID; every worker completes or shapes at
  most one packet, and every root-owned over-budget packet cites an explicit
  override.
- **Counterarguments / limits**: more cycle metadata increases ledger volume.
  The minimum viable form can live in the compact final receipt rather than
  every progress note.

## MOT-05 — Commit-scoped verification receipts and bounded repetition

- **Proposal status**: proposed-for-upvote
- **Target methodology section**:
  `methodology/ci.yaml` → `execution_contract` and
  `methodology/agent-observability.yaml` → handoff evidence
- **Finding**: focused repetition was useful to distinguish a lock defect from
  a transient fork-to-exec window, but the team reached at least five parent
  repetitions plus 100 focused and 12 full child repetitions after no defect
  reproduced. Test commands/results were exchanged as prose rather than as a
  reusable, commit-scoped receipt.
- **Proposed rule**: handoffs include a `verification_receipt` containing commit
  SHA, command, relevant environment fingerprint, result, repetition count,
  and hypothesis. Another agent may reuse a receipt only for the exact same
  tree and compatible environment. Default flake investigation has a bounded
  repetition budget; exceeding it requires a named probability/hypothesis or
  operator reason. Changed trees invalidate the receipt.
- **Cross-context applicability**: flaky-test triage and expensive integration
  suites in any concurrent repository.
- **Measurable adoption gate**: a two-agent fixture demonstrates that the
  second agent consumes an exact-SHA receipt instead of re-running; a changed
  SHA forces revalidation. The initial suggested review threshold is 20
  repetitions, to be calibrated rather than treated as a proven optimum.
- **Counterarguments / limits**: rare races may need hundreds of runs, and
  environment fingerprints can be incomplete. The threshold is an explicit
  review point, not a hard ban. The mandatory post-rebase `./build.sh --check`
  remains non-reusable across changed commits.

## MOT-06 — Forge worktree capacity preflight and placement helper

- **Proposal status**: proposed-for-upvote
- **Target methodology section**:
  `methodology/multi-host-development.yaml` → `start_of_session` and
  `methodology/distributed-work.yaml` → `in_forge_agent_self_service`
- **Finding**: concurrent agents conventionally created full Git worktrees
  under a 256 MiB `/tmp` tmpfs. Three approximately 61 MiB checkouts plus
  scratch data left too little space for the next checkout, which failed after
  creating a branch and attempting thousands of file writes.
- **Proposed rule**: provide one sanctioned helper that preflights free bytes,
  estimated tracked-checkout size, inode count, and existing worktree count,
  then chooses a capacity-qualified root. In the forge, prefer a persistent
  overlay location such as `/home/forge/worktrees`; reserve `/tmp` for small
  scratch/boundary artifacts. On partial failure, remove only the helper-owned
  worktree registration/path and report the created branch explicitly.
- **Cross-context applicability**: containers, CI runners, and hosts where
  `/tmp` is a small tmpfs.
- **Measurable adoption gate**: a fixture with a constrained tmpfs refuses or
  redirects before `git worktree add`; it leaves no registered partial
  worktree, and a checkout succeeds on a qualified fallback filesystem.
- **Counterarguments / limits**: overlay worktrees may be slower and persist
  longer. The helper should still select tmpfs when capacity is sufficient and
  should offer explicit, target-scoped cleanup after remote parity.

## MOT-07 — Direction freshness and precedence

- **Proposal status**: proposed-for-upvote
- **Target methodology section**:
  `methodology/distributed-work.yaml` → `version_aware_release_planning`,
  `skills/advance-work-from-plan/SKILL.md` → orientation/selection, and
  `plan/loop_status.md` structured status contract
- **Finding**: `## ACTIVE RELEASE` says the 2026-07-21 operator decision moved
  EXPERTS out of v0.4 and defines v0.4 as the stability bundle. The later
  `## Direction` text is still dated 2026-07-17 and says every host is giving
  forge agents local EXPERTS. The explicit user request and active-release
  section made today's stability choice clear, but a cold worker following the
  mandatory Direction read could rationally choose the stale theme.
- **Proposed rule**: make Direction structured with `updated_at`,
  `effective_release`, and `supersedes` fields, and declare precedence:
  explicit current operator prompt, then active-release operator decision,
  then matching/fresh Direction, then general queue ranking. A validator warns
  or fails when Direction points at a milestone assigned beyond the active
  release without an explicit cross-release exception.
- **Cross-context applicability**: repositories with both thematic steering and
  release-bucket selection.
- **Measurable adoption gate**: a policy fixture containing today's v0.4/EXPERTS
  mismatch returns a deterministic stale-direction verdict; after structured
  supersession it passes and two cold agents select the same release tier.
- **Counterarguments / limits**: a direction may intentionally describe a
  longer-horizon theme. The exception field should preserve that use without
  allowing it to silently override a newer active-release decision.

## Suggested voting and promotion order

Recommended first upvotes:

1. `MOT-02` remote-durable delegation and landing ownership;
2. `MOT-01` landing train;
3. `MOT-03` final-response join barrier;
4. `MOT-06` worktree capacity preflight.

`MOT-04`, `MOT-05`, and `MOT-07` should receive at least one independent
reproduction/review before promotion because their best schema and threshold
choices are not established by one session.

An upvoting agent should append a dated block naming its independent context,
which proposal IDs it supports or rejects, and any counterexample. Promotion
then splits accepted IDs into the smallest independent `plan/index.yaml` nodes;
this intake file remains the provenance record.
