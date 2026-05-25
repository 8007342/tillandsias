# Multi-Host Integration Loop — 2026-05-24

trace: methodology/multi-host-development.yaml, plan/issues/multi-host-coordination-2026-05-24.md

## Status

Active. This issue is the durable ledger for the Linux-host integration loop
that periodically pulls `windows-next` and `osx-next` work into `linux-next`,
verifies tests, and records outcomes. Loop runs every 2 hours via session-local
cron (job `a98ef6e2`, expires after 7 days unless renewed). Ledger push is
unconditional every cycle.

## Loop Contract

See the prompt body in the session cron job. Summary:

1. Fetch + verify clean working tree on `linux-next`.
2. Detect new commits on `origin/windows-next` and `origin/osx-next` not in
   `linux-next`.
3. Attempt `git merge --no-ff --no-commit` per sibling.
4. Run `./build.sh --check` then `./build.sh --test` before committing.
5. Push successful merges; abort on conflict or test failure and log.
6. Upsert this file with a per-cycle entry. Commit + push the ledger.

Guardrails: never force-push, never push to `main`/`osx-next`/`windows-next`,
never delete another host's plan notes (tombstone/supersede only). Escalate at
three consecutive same-cause failures.

## Cycle Log (reverse chronological — keep latest 20 verbatim)

### Cycle 2026-05-25T01:43:10Z — SKIPPED (dirty working tree, unchanged from prior cycle)

- host_id: linux-tlatoani-fedora (macuahuitl.ayahuitlcalpan.com)
- platform: linux
- branch: linux-next
- upstream_commit: 1ed8153a151b1f6f3685ea9770cca313216445f4
- observed_sibling_heads:
  - main: ddf52dffcda4f5d32104179cdaf7e4b87221300d
  - linux-next: 1ed8153a151b1f6f3685ea9770cca313216445f4
  - windows-next: 24dfab6c86b1204d28820e216b9ae94692197ff2
  - osx-next: ddf52dffcda4f5d32104179cdaf7e4b87221300d

- windows-next: **dirty-tree-skipped** — backlog grew to **11 commits ahead**
  of `linux-next` (was 3 last cycle, +8 new):
  - `24dfab6c` feat(windows-next): embed app manifest via tillandsias.rc (DPI awareness)
  - `057c60f8` chore(windows-next): untrack session-local cron lock, gitignore scheduler state
  - `b1926962` feat(windows-next): host-side ~/src project scan into the tray menu
  - `99e22370` chore(windows-next): target-gate vm-layer download + record integration-loop awareness
  - `30b9b8da` docs(windows-next): correct cold-start NEXT ACTION — drop OCI-flatten, recipe-blocked
  - `8cb3f8c3` feat(windows-next): Phase 4 — portable menu-action resolver + Windows test portability
  - `e67ee603` docs(windows-next): state Windows recipe-convergence preferences in shared ./plan
  - `29c6c675` docs(windows-next): record 3-tray convergence coordination + Phase 2 supersession
  - `c43390b4` feat(windows-next): Phase 2 — verified resumable provisioning downloads
  - `704e8f04` checkpoint(windows-next): Phase 0+1 done — toolchain in, tray builds on MSVC host
  - `a82c465d` checkpoint(windows-next): commit thin-tray bring-up plan + architecture decision
- osx-next: no-op — 0 new commits beyond `linux-next` (still at `ddf52dff` =
  `main`).

- Reason for skip: working tree still has 33 modified tracked files + 8
  untracked paths (no change since cycle `00:12Z` — user has not yet committed
  the methodology/openspec edits). STEP 1 guardrail blocks integration.

- Spec-drift watch (advisory): windows-next has begun touching shared `plan/`
  and `methodology` semantics (commits `99e22370`, `e67ee603`, `29c6c675`).
  Specifically `99e22370` mentions "integration-loop awareness" — the Windows
  host is coordinating *with this loop*, which means cross-host conflicts on
  `plan/issues/multi-host-*` are likely on next merge. Expect to need careful
  reconciliation (tombstone/supersede rather than overwrite).

### Cycle 2026-05-25T00:12:21Z — SKIPPED (dirty working tree)

- host_id: linux-tlatoani-fedora (macuahuitl.ayahuitlcalpan.com)
- platform: linux
- branch: linux-next
- upstream_commit: 2fb37e3b4f8152f69225a2c466e2ee22b39d5f98
- observed_sibling_heads:
  - main: ddf52dffcda4f5d32104179cdaf7e4b87221300d
  - linux-next: 2fb37e3b4f8152f69225a2c466e2ee22b39d5f98
  - windows-next: c43390b4f8759048aa406cb0b2f0ce754db6911d
  - osx-next: ddf52dffcda4f5d32104179cdaf7e4b87221300d

- windows-next: **detected, not integrated this cycle** — 3 commits ahead of
  `linux-next`:
  - `c43390b4` feat(windows-next): Phase 2 — verified resumable provisioning downloads
  - `704e8f04` checkpoint(windows-next): Phase 0+1 done — toolchain in, tray builds on MSVC host
  - `a82c465d` checkpoint(windows-next): commit thin-tray bring-up plan + architecture decision
- osx-next: no-op — 0 new commits beyond `linux-next` (still at the shared tip
  shared with `main`).

- Reason for skip: working tree has 33 modified tracked files + 8 untracked
  paths (user/linter in-progress edits to `CLAUDE.md`, `methodology/`,
  `openspec/specs/`, `plan/`, etc.). Per the loop's STEP 1 guardrail, a dirty
  tree blocks integration to avoid tangling user work with merge commits.

- Action requested from human: commit (or stash) the in-progress methodology &
  spec edits. The next cron tick (or a manual loop nudge) will then integrate
  `windows-next` Phase 0–2 into `linux-next`.

- Spec-drift watch (advisory, no merge performed): `windows-next` Phase 0–2
  appear platform-isolated (toolchain + provisioning downloads). When merged,
  re-check whether any shared crate or shared protocol contract was touched.

## Open Recommendations

- **Two consecutive dirty-tree skips.** The integration backlog from
  `windows-next` is now 11 commits and growing. Commit (or stash) the
  in-progress local methodology/openspec edits so the loop can absorb Windows
  Phase 0–4 work.
- Expect `plan/issues/multi-host-*` conflicts on the next merge attempt:
  Windows host is also writing to shared `plan/`. Resolution policy is
  tombstone/supersede, never delete.
- `osx-next` has not advanced since alignment; the macOS terminal will likely
  push Phase 5+ work soon — the loop will pick it up automatically.
