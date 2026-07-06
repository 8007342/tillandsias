---
date: 2026-07-05
kind: research
status: completed
owner_host: any
---

# Audit: Clarify `advance-work-from-plan` cross-branch write instructions

## Incident / Confusion
The user noticed that the plan execution loop was causing errors or confusion surrounding cross-branch pushes. A recent simplification in the methodology stated that "All `plan/` writes go to `linux-next`," which broke the flow for agents working on `windows-next` or `osx-next`. These agents were incorrectly running `git push origin linux-next` while checked out on a different branch, leading to non-fast-forward rejections or pushing stale local `linux-next` branches to the remote.

## Root Cause
- `skills/meta-orchestration/SKILL.md` instructed that all plan updates go to `linux-next`. While `linux-next` is the canonical home, telling an agent to "go to linux-next" was taken literally.
- `skills/advance-work-from-plan/SKILL.md` explicitly commanded agents to `git push origin linux-next` after claiming leases or completing packets, regardless of their current branch. This directly conflicts with the rule "NEVER push to a sibling host's branch".

## Fixes Implemented
1. **`skills/advance-work-from-plan/SKILL.md` updated**:
   - The "Commit & Push" instructions now specify `git push origin <active-branch>` instead of hardcoding `linux-next`.
   - The exit discipline sections ("Commit & Push Ledger", "Yield & Triage") were similarly updated to point to `origin/<active-branch>`.
2. **`skills/meta-orchestration/SKILL.md` updated**:
   - Clarified that while `linux-next` is the canonical home, agents on platform branches (`windows-next`, `osx-next`) MUST commit and push all edits (including plan updates) to their *active* platform branch.
   - Reaffirmed that the `linux_mutable` coordinator merges these branches back into `linux-next` during the `/multihost-orchestration` pass.

## Outcome
Agents across all hosts can safely run the `/advance-work-from-plan` skill. They will properly push their claims, status updates, and deliverables to their active branch, eliminating the git cross-branch confusion.
