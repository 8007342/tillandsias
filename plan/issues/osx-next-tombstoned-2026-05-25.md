# `osx-next` tombstoned (aligned to linux-next) — 2026-05-25

trace: plan/issues/multi-host-integration-loop-2026-05-24.md, plan/issues/tray-convergence-coordination.md, plan/issues/macos-recipe-convergence-response-2026-05-24.md

Author: macos-next worker on `Tlatoanis-MacBook-Air` (Apple Silicon).
Authority: owner directive 2026-05-25 ("Tombstone osx-next: force-align it to linux-next periodically; remove from integration loop's observed set").

## What happened

Until 2026-05-25, the multi-host workflow had a contract mismatch:

- **Integration-loop contract** (defined in the cron prompt on the linux-next host, ledger `plan/issues/multi-host-integration-loop-2026-05-24.md`) assumed the macOS worker would push to `origin/osx-next`, and the loop would `git merge --no-ff` osx-next → linux-next every cycle.
- **Reality**: per owner directive 2026-05-24 ("our local branch afterwards should be macos-next with the latest code from linux-next … pull-merge with fast forward should be the new way to go"), the macOS worker on `Tlatoanis-MacBook-Air` pushes its `macos-next` branch *directly* to `origin/linux-next` via `git push origin macos-next:linux-next`. The loop saw macOS commits arrive on linux-next as if from a local commit; it never had osx-next to merge from.
- **Optics drift**: the loop's ledger kept reporting "osx-next: no-op — 0 new commits beyond `linux-next` (still at `ddf52dff` = `main`)" cycle after cycle, which read as "macOS hasn't engaged" — but macOS had in fact been pushing dozens of commits and the integration loop was implicitly absorbing them via linux-next.

## Action taken

1. **Verified osx-next's tip (`ddf52dff`) was an ancestor of linux-next's tip.** It was — osx-next had no unique commits to lose; `main` is in linux-next's history.
2. **Fast-forwarded `origin/osx-next` → `origin/linux-next` tip.** `git push origin origin/linux-next:osx-next` (no force; pure FF).
3. Pre-align: `osx-next` at `ddf52dff` (= main).
4. Post-align: `osx-next` at `b0951b7c` (= linux-next tip at the moment of alignment; linux-next has since moved on independently — that's fine).

## What the linux-next integration loop should change

**Request for the linux-tlatoani-fedora cron prompt (`7ed95aed`)** maintained by the integration loop:

- **Drop `origin/osx-next` from `observed_sibling_heads`** in step 2 of the loop contract ("Detect new commits on `origin/windows-next` and `origin/osx-next` not in `linux-next`"). It is now an alias of linux-next at every alignment moment.
- **Drop the "macOS host: please respond / osx-next will likely advance soon" advisory** from Open Recommendations — that text reflects the old contract.
- **Optionally**: schedule a periodic re-alignment of osx-next → linux-next (every few cycles, or every linux-next push). This keeps osx-next visibly current for any external tooling that consumes it. A one-liner suffices: `git push origin origin/linux-next:osx-next` (fast-forward) at the end of every successful integration cycle.

## What the macOS worker (this file's author) will do going forward

- Continue pushing to `origin/linux-next` directly. This is unchanged.
- Stop documenting "osx-next is intentionally stale" as a caveat in macOS responses (the caveat is now resolved by this tombstone).
- If the integration loop's prompt isn't updated quickly, the macOS worker will mirror its pushes to `osx-next` opportunistically (in the same cron iteration that pushes to linux-next) so osx-next stays current. This is a low-cost belt-and-suspenders pending the prompt amendment.

## Why this is the right shape

Per the owner's three-tray-wrapper architecture (Linux/macOS/Windows trays speaking idiomatic transports), the *branch* topology should mirror the *runtime* topology. Linux is canonical; macOS + Windows host-shells are thin wrappers around the canonical Linux tillandsias-headless. Reflecting this in git:

- `main`: canonical Tillandsias releases (all trays version-locked).
- `linux-next`: integration branch where work from all three host-shell teams lands.
- `osx-next`, `windows-next`: per-host work-in-progress branches *when a host needs isolation* from linux-next (e.g., long-lived Windows-specific refactors). When a host's worker can land directly on linux-next without disruption (the macOS case today), the per-host branch is just a mirror of linux-next.

The Windows host's per-host branch is still active because windows-next does substantial OS-specific work that needs incubation before merge. The macOS work today is mostly additive (vz.rs body + macOS-only crates) and lands cleanly on linux-next directly, so osx-next as a mirror suffices.

## Falsifiability

To verify the tombstone holds:

```bash
git fetch origin --prune
git merge-base --is-ancestor origin/osx-next origin/linux-next  # → exit 0
git rev-list --count origin/osx-next..origin/linux-next         # → 0 or small (just the lag since last alignment)
```

If the second check returns a large number consistently, osx-next is drifting again and the integration loop needs to re-align or the macOS worker needs to push the mirror.
