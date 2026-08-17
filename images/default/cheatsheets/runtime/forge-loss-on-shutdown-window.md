---
tags: [forge, durability, teardown, git-mirror, ephemeral, push, shutdown]
languages: [bash]
since: 2026-08-16
last_verified: 2026-08-16
sources:
  - images/git/pre-receive-hook.sh
  - images/git/entrypoint.sh
  - plan/issues/macos-forge-349-closing-run-2026-08-16.md
authority: high
status: current
tier: bundled
summary_generated_by: "macos meta-orchestration cycle, order 776-jcf3 criterion 2"
bundled_into_image: true
committed_for_project: true
---
# Forge loss-on-shutdown window — what survives a lane teardown, and why

<!-- provenance: 776-jcf3 criterion 2 (operator directive 2026-08-16: retire
     ~/src behind proven transparent push). Sources verified 2026-08-16 on
     macOS: images/git/pre-receive-hook.sh (header + exit contract),
     images/git/entrypoint.sh:168-174 (receive.denyDeletes/denyNonFastForwards),
     plan/issues/macos-forge-349-closing-run-2026-08-16.md (live relayed-push
     proof), 756-2jnj events (verdict machinery + linux token blocker).
     The frontmatter above is the machine-readable form of this note (added
     2026-08-16, order 782-avtk); this comment is kept because it carries the
     line-level citations the frontmatter's path list cannot. -->
<!-- freshness: auditor=macos-tlatoanis-macbook-air-fable5 date=2026-08-16 verdict=refreshed scope=776-jcf3 authoring -->

The ephemeral path (cloud ↔ ephemeral git-mirror ↔ ephemeral forge) makes one
trade explicitly: **the forge container's filesystem is disposable**. This
page states exactly where the durability line sits, from the code, so nobody
has to assume.

## The four states of in-forge work

| State | On lane teardown | Why (verified source) |
|---|---|---|
| Uncommitted worktree changes | **LOST, by design** | the ephemerality contract itself |
| Committed, NOT pushed | **LOST, by design** | commits live in the lane's clone; the clone dies with the container |
| **Pushed, upstream-configured project** | **DURABLE at the moment `git push` returns success** | pre-receive **synchronously relays the ref transaction upstream BEFORE accepting it locally** — "a client success therefore means the configured upstream has durably accepted the same atomic ref set" (pre-receive-hook.sh header; exit 1 on relay failure). Proven live on macOS: 349's closing run pushed a scratch ref and it was on github.com before the in-forge command returned. |
| Pushed, **local-only** project (no upstream) | survives only as long as the **mirror volume** | the relay step is skipped; the bare repo on the mirror volume is the only copy |

## The three consequences worth acting on

1. **Push early, push often is not hygiene — it is THE durability mechanism.**
   There is no background sync, no grace window, no queue: work is durable at
   push-success and at no earlier moment. A relay failure (upstream down,
   credential dead — the linux 403, 756-2jnj) FAILS THE PUSH loudly rather
   than queuing it; the work stays in the lane, still mortal.
2. **Local-only projects have an unbounded loss window on macOS**: the mirror
   volume lives inside the guest VM, so `--reset-guest` or any substrate wipe
   destroys the only copy. A local-only project that matters needs an upstream
   before its forge does real work.
3. **Nothing inside the enclave can destructively rewrite what was relayed**:
   the mirror enforces `receive.denyDeletes` + `receive.denyNonFastForwards`
   (+ fsckObjects) before the privileged relay, so a compromised or confused
   lane cannot delete refs or force-push over history through the mirror.
   (Scratch-ref cleanup is therefore a HOST-side act, per 349.)

## What this means for retiring ~/src (776-jcf3)

The historical `~/src/<project>` checkout was the lost-work recovery path.
With the synchronous-relay property proven on a host (macOS: proven; linux:
blocked on its token; windows: unproven), rows 1–2 above are the ONLY loss
surface that remains — and they are the same surface every ephemeral CI system
accepts. The removal decision reduces to: is every host's push relay proven,
and is row 4 (local-only) either accepted or fenced.
