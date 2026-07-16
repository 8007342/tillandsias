# Stale git stashes on the shared checkout are landmines for automation (a bare `stash pop` applied 2026-07-01 foreign work)

- Date: 2026-07-15
- Class: optimization (multi-agent hygiene; near-miss)
- Filed by: macos-osx-next coordination cycle 2026-07-15T23:14Z
- Pickup: any (hygiene decision is the operator's)

## Observed

The shared macOS checkout carries 3 old stashes (oldest 2026-06-02). During
gate forensics an automation idiom (`git stash && … && git stash pop`) hit
the no-op branch ("No local changes to save") and the later bare `pop`
applied **stash@{0} from 2026-07-01** ("violation-era experimental
leftovers — podman reroute hack, exec-guest-interactive draft") onto the
worktree. The pop CONFLICTED (action_host.rs), which preserved the stash
entry; the worktree was restored to the clean startup boundary with
`git reset --hard HEAD` and nothing was lost — but a conflict-free pop
would have silently mixed 2-week-old abandoned work into a live cycle.

## Asks

1. Operator/owner: triage the 3 stashes (keep→branch, or drop) —
   `stash@{0}` osx-next 2026-07-01, `stash@{1}` linux-next 2026-06-03,
   `stash@{2}` osx-next 2026-06-02. The exec-guest-interactive draft in
   stash@{0} may be relevant to order 155/tray work.
2. Automation rule (worth a line in the worktree-guard doc): never bare
   `git stash pop` — capture the created stash ref (`git stash push` output
   or `stash create`) and pop exactly that ref, or skip the pop when the
   push reported "No local changes to save".
