---
tags: [git, multi-host, agents, handoff, leases, crdt]
languages: [bash]
since: 2026-05-25
last_verified: 2026-05-25
sources:
  - methodology/distributed-work.yaml
  - plan/issues/branch-and-coordination-canon-2026-05-25.md
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Concurrent Git — Agent Handoff

@trace methodology/distributed-work.yaml

**Use when**: you're an agent picking up work from `plan/`, you need to claim something, checkpoint partial progress, or hand off to a different agent on success / failure / interruption.

## Provenance

- `methodology/distributed-work.yaml` — work-item schema + self-assignment protocol
- **Last updated:** 2026-05-25

## The 8-step self-assignment protocol

```
0. orient            → read methodology + plan/index
1. identify self     → host, agent_id, capabilities
2. fetch canonical   → git fetch + pull linux-next
3. filter eligible   → owner_host ∈ {own_host, any}, status ∈ pending|blocked-resolved|failed-retryable, no live lease overlap
4. pick one          → earliest order or unblocked blocker; tie-break lexicographic stable ID
5. claim             → write claim event to plan/, commit + push
6. execute           → switch to code branch if needed; checkpoint events to linux-next
7. terminal          → completed / released / failed event
8. push ledger       → final plan/ commit to linux-next, regardless of code branch
```

## Quick reference — the claim event

A `claim` event is a YAML block appended to the work item's `events:` list (or to a Markdown "Events" section in a plan issue). It looks like:

```yaml
events:
  - type: claim
    ts: 2026-05-25T06:30:00Z
    agent_id: linux-tlatoani-fedora-claudia-cli-2026-05-25T06
    host: linux
    lease_id: a1b2c3d4e5f6     # 12-hex random
    expires_at: 2026-05-25T10:30:00Z   # default acquired_at + 4h
```

After writing the claim, commit + push to `linux-next`. If the push reveals another host already claimed the item (their event landed first), YIELD: release your local claim and pick something else.

## Quick reference — agent_id format

```
<host>-<workstation-shortname>-<harness>-<utc-iso-stamp>
```

Examples:
- `linux-tlatoani-fedora-claudia-cli-2026-05-25T06`
- `macos-tlatoani-mbp-cowork-2026-05-25T07`
- `windows-tlatoani-thinkpad-claude-code-2026-05-25T08`

Doesn't need to be a UUID; just identifying enough that a human reader knows which terminal/host produced it.

## Common patterns

### Pattern A — pick up a fresh pending item

```bash
git fetch origin --prune
git checkout linux-next && git pull --ff-only

# Open the item file (e.g. plan/issues/foo-2026-05-25.md) and read it.
# Verify: owner_host matches you (or is "any"), capability_tags include something
# you handle, status is "pending", no active lease.

# Append a claim event to the file's events section.
# Commit + push:
git add plan/issues/foo-2026-05-25.md
git commit -m "claim(plan): claim foo-2026-05-25 from linux"
git push origin linux-next || (git fetch && git rebase origin/linux-next && git push origin linux-next)

# If push succeeded: switch to your code branch and start executing.
git checkout linux-next   # or windows-next / osx-next as appropriate
```

### Pattern B — checkpoint partial progress mid-task

After each meaningful chunk of work:

```yaml
events:
  - type: progress
    ts: 2026-05-25T07:15:00Z
    agent_id: <yours>
    host: <yours>
    lease_id: <same as claim>
    note: "extracted dispatch() function from vsock_server; tests pass"
    partial_artifact_refs:
      - commit: 7f8455f6
      - branch: linux-next
```

Commit + push the plan/ update. Code work stays on its own branch.

### Pattern C — resume an item another agent failed or released

```yaml
events:
  - type: claim
    ts: 2026-05-25T08:00:00Z
    agent_id: <new agent>
    host: linux
    lease_id: <new lease, NOT the prior one>
    expires_at: 2026-05-25T12:00:00Z
    resumed_from_lease: <prior lease_id>
    resumed_reason: "prior lease expired with last progress at 06:00Z; partial commit 7f8455f6 is reusable"
```

Read the entire events list first — do NOT rely on memory or guess what the prior agent did.

### Pattern D — complete or release

Success:

```yaml
events:
  - type: completed
    ts: 2026-05-25T09:30:00Z
    agent_id: <yours>
    host: <yours>
    lease_id: <same as claim>
    evidence_refs:
      - commit: a9adf59f
      - tests_passed: "./build.sh --test"
      - pr: "#2"
```

Then bump the item's `status:` field to `done` in the same commit.

Voluntary release (e.g. you're shutting down and the task isn't finished):

```yaml
events:
  - type: released
    ts: 2026-05-25T09:30:00Z
    agent_id: <yours>
    host: <yours>
    lease_id: <same as claim>
    reason: "session ending; ~60% complete; next agent should resume from commit X"
```

Status returns to `pending` so any other eligible agent can claim.

### Pattern E — failed (retryable)

```yaml
events:
  - type: failed
    ts: 2026-05-25T09:30:00Z
    agent_id: <yours>
    host: <yours>
    lease_id: <same as claim>
    reason: "test X fails on this host; suspect missing dep; recommend retry on a fresh agent or different host"
    retryable: true
```

Status moves to `failed`. A future agent may re-claim if it has reason to believe its environment differs.

## Common pitfalls

1. **Skipping `git fetch` before claiming** — you may file a claim against state you don't have; the push will be rejected and you'll either lose your event or have to re-do it.
2. **Re-using a lease_id across separate claim cycles** — lease_ids should be unique per claim. Re-use breaks idempotency reasoning.
3. **Editing the prior agent's events** — append-only. Add YOUR new events; never rewrite theirs.
4. **Forgetting to push the plan/ ledger update** — your code commits on `windows-next` are invisible to other hosts until your plan/ event reaches `linux-next`.
5. **Claiming work without the right capability_tag** — picking up "appkit" work from a Linux host means the work will sit unfinished. Filter by tags.
6. **Not setting an `expires_at`** — default is 4h. If you're going to take longer, renew by re-emitting the claim event with a fresh expires_at.

## See also

- `concurrent-git/branches.md` — where things get pushed
- `concurrent-git/plan-discipline.md` — what plan/ events look like in practice
- `methodology/distributed-work.yaml` — full schema + CRDT principles
