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

### Cycle 2026-05-25T13:43Z — NO-OP (siblings dormant, 4th consecutive)

- host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next
- upstream_commit: 28602340c03cbdd81a5124243a52a8c630d78465
- observed_sibling_heads: main=ddf52dff · linux-next=28602340 · windows-next=266c4edc (since 05:43Z) · osx-next=ddf52dff (frozen since 2026-05-24 alignment)
- windows-next: no-op. osx-next: no-op. Tests: n/a. Working tree clean.

### Cycle 2026-05-25T11:43Z — NO-OP (siblings dormant, 3rd consecutive)

- host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next
- upstream_commit: 70ce738dd8c71bfb676c247b0d24551cf8adb2ed
- observed_sibling_heads:
  - main: ddf52dff (unchanged)
  - linux-next: 70ce738d (= our last ledger commit)
  - windows-next: 266c4edc (unchanged since cycle 05:43Z absorbed)
  - osx-next: ddf52dff (frozen since 2026-05-24 alignment)
- windows-next: no-op. osx-next: no-op. Tests: n/a. Working tree clean.
- Linux-host work between cycles: methodology refresh complete + 2 no-op
  cycles since. No new work in flight pending user direction.

### Cycle 2026-05-25T09:44Z — NO-OP (siblings dormant, 2nd consecutive)

- host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next
- upstream_commit: 608c5ba2dca7ccf0d236630f007caa0340253b31
- observed_sibling_heads:
  - main: ddf52dff (unchanged)
  - linux-next: 608c5ba2 (= our last ledger commit)
  - windows-next: 266c4edc (unchanged since cycle 05:43Z)
  - osx-next: ddf52dff (frozen since 2026-05-24 alignment)
- windows-next: no-op (0 commits). osx-next: no-op (0 commits).
- Tests: n/a (no merge attempted). Working tree clean.

### Cycle 2026-05-25T07:43Z — NO-OP (siblings dormant, clean tree)

- host_id: linux-tlatoani-fedora (macuahuitl.ayahuitlcalpan.com)
- platform: linux
- branch: linux-next
- upstream_commit: 51448ca744ff13b149751043402bb0a49bef6ad2
- observed_sibling_heads:
  - main: ddf52dffcda4f5d32104179cdaf7e4b87221300d
  - linux-next: 51448ca744ff13b149751043402bb0a49bef6ad2
  - windows-next: 266c4edc0af76d76da8a0a88612c351e1ac95192 (unchanged since cycle 05:43Z absorbed it)
  - osx-next: ddf52dffcda4f5d32104179cdaf7e4b87221300d (unchanged since 2026-05-24 alignment)

- windows-next: **no-op** — 0 new commits beyond `linux-next`.
- osx-next: **no-op** — 0 new commits; remains frozen at the alignment tip.
- Tests: n/a (no merge attempted).

- Working tree clean. Linux-host activity between this cycle and 05:43Z was
  the methodology-refresh interlude documented above; everything pushed.

### Interlude 2026-05-25T06:00Z–06:45Z — Methodology refresh (no integration; sibling laptops dormant)

User directive: while macOS and Windows hosts are dormant for several hours,
use the time to land the multi-host methodology refactor that previous cycles
surfaced as needed. NOT a cron tick; documented here for chronology.

- Cumulative work landed on linux-next (commits `85b90af6`, `fc1b604e`):
  - methodology/distributed-work.yaml (new) — CRDT-inspired primitives,
    work-item schema, host-component ownership matrix, 8-step agent
    self-assignment protocol, failure/handoff semantics, merge policy.
  - methodology/multi-host-development.yaml — cross-references the new file,
    formalizes plan-write-to-linux-next discipline, pins branch canon
    (osx-next, NOT macos-next), documents 5 common pitfalls learned by
    the loop.
  - methodology.yaml entrypoint index updated.
  - methodology/event/032-distributed-work-methodology-refresh.yaml +
    event/index.yaml updated.
  - plan/issues/branch-and-coordination-canon-2026-05-25.md (new) —
    canonical decision record.
  - cheatsheets/concurrent-git/{branches,agent-handoff,plan-discipline}.md
    (new) — agent-facing translation of the methodology into copy-pasteable
    git workflows.

- **Loop enhancement spec is now durable** (the "claim-collision warning"
  candidate from cycle 05:43Z is referenced from the new methodology;
  implementation still pending on the next pass over the cron prompt).

- No integration this interlude (no sibling commits to absorb; osx-next
  and windows-next unchanged from cycle 05:43Z).

### Cycle 2026-05-25T05:43Z — INTEGRATED (clean tree, on-cron)

- host_id: linux-tlatoani-fedora (macuahuitl.ayahuitlcalpan.com)
- platform: linux
- branch: linux-next
- upstream_commit (post-pull pre-merge): b0951b7cd55c451d696d87703f541d18b1135b10
- observed_sibling_heads:
  - main: ddf52dffcda4f5d32104179cdaf7e4b87221300d
  - linux-next: b0951b7cd55c451d696d87703f541d18b1135b10
  - windows-next: 266c4edc0af76d76da8a0a88612c351e1ac95192
  - osx-next: ddf52dffcda4f5d32104179cdaf7e4b87221300d

- windows-next: **merged + tested + pushed** (`59706e19`). 4 commits absorbed:
  - `266c4edc` docs(windows-next): capture shared wire-dispatch contract for the vsock-E2E tail
  - `0d7a32cf` docs(vm-recipe-provisioning): supersede windows D8 with macOS-authored D6; keep spec-delta reconciliation
  - `42479788` Merge remote-tracking branch 'origin/linux-next' into windows-next
  - `f0dde8bc` docs(vm-recipe-provisioning): amend with D8 dual-path distribution (owner-assigned)
  - Net diff: +90 lines across `openspec/changes/vm-recipe-provisioning/specs/vm-provisioning-lifecycle/spec.md`, `plan/issues/tray-convergence-coordination.md`, `plan/steps/windows-next-thin-tray.md`. Docs/spec only — zero code.
  - `./build.sh --check`: PASSED. `./build.sh --test`: PASSED.
- osx-next: no-op — still at `ddf52dff` (= `main`). **But see drift advisory below.**

- **Methodology drift spotted (high signal for the user):**
  1. **macOS host is committing DIRECTLY to `linux-next`, not pushing through
     `osx-next`.** Recent macOS commits like `74f0ebd2 plan(macos-tray)`,
     `70c7c2a0 amend(vm-recipe-provisioning): D6`, `3db11291 feat(macos-tray)
     Phase 1 step 1.3`, `3cd90335 feat(macos-tray) Phase 1 step 1.4` are
     authored as `Tlatoani <bulloncito@gmail.com>` (same email as
     linux-host, different macron-less name) and land on `linux-next`
     without ever passing through `origin/osx-next`. The `osx-next` branch
     has been frozen at `ddf52dff` since the 2026-05-24 alignment.
     - **Effect:** the integration loop's `osx-next` arm is a permanent
       no-op; macOS work bypasses the platform-branch model entirely.
     - **Author identities now in play:** `Tlatoāni` (linux, macron),
       `Tlatoani` (macOS, no macron), `bullo` (windows host, e.g. commit
       `266c4edc`). All share `bulloncito@gmail.com`. Same human, three
       host identities.
     - **Methodology question (for the user / change owner):** is direct
       commit-to-linux-next by macOS the new intentional model (in which
       case the loop's `osx-next` arm can be dropped, the
       `methodology/multi-host-development.yaml` `platform_branches.macos`
       value retired, and the integration loop refactored), OR is this a
       drift to correct (in which case macOS host should be reminded to
       push to `osx-next` and let the loop integrate)? Linux host has no
       preference; raising for explicit decision.
  2. **Concurrent-drafting collision risk surfaced.** Windows-host commit
     `0d7a32cf` reconciled a collision: macOS authored D6 amendment while
     Windows authored D8 (same amendment, different letter), both
     converging on integration branch within minutes. Windows reconciled
     cleanly (dropped redundant D8 design, kept unique spec-delta fix).
     **Lesson Windows recorded in `tray-convergence-coordination.md`:**
     "claims must be checked against the integration branch before
     drafting — macOS and I drafted the same amendment in parallel."
     Loop should consider surfacing claim-collision warnings (currently it
     does not).
  3. **Win/Mac CONFIRMED the protocol-convergence plan** from
     `plan/issues/control-socket-protocol-convergence-2026-05-25.md`:
     Windows-host commit `266c4edc` explicitly states it will use the same
     ControlMessage variants over both transports, route through the
     shared Linux-authored dispatcher (PR #2 Slice 1 already landed:
     commit `a9adf59f` `feat(control-socket): reply Error{Unsupported}
     instead of silently dropping unhandled variants`), and file new
     variants in the convergence doc rather than fork local handlers. The
     control-wire enum stays unchanged. Slice 2 (full shared dispatcher
     extraction) remains gated on sibling answers to Q1-Q4.

- **Spec/methodology delta this cycle:**
  - `openspec/changes/vm-recipe-provisioning/specs/vm-provisioning-lifecycle/spec.md`
    +40 lines — Windows-authored requirement "First-run obtains the rootfs
    by fetch (default) or local materialization" + 3 scenarios + reconciled
    binary clause + reference updates D8→D6. Fixes a contradiction the
    macOS D6 left in the spec delta. Advisory only — change-owner artifact,
    no Linux-side action required.

### Cycle 2026-05-25T03:43Z — INTEGRATED (clean tree, on-cron)

- host_id: linux-tlatoani-fedora (macuahuitl.ayahuitlcalpan.com)
- platform: linux
- branch: linux-next
- upstream_commit (pre-merge): f8ba066211df20befb31d0b87c497d5920229a6a
- observed_sibling_heads:
  - main: ddf52dffcda4f5d32104179cdaf7e4b87221300d
  - linux-next: f8ba066211df20befb31d0b87c497d5920229a6a
  - windows-next: b3ca27473d2340297ffc26f7d196ff6bbe994d09
  - osx-next: ddf52dffcda4f5d32104179cdaf7e4b87221300d

- windows-next: **merged + tested + pushed** (`7f8455f6`). 3 commits absorbed:
  - `971bf9c6` docs(windows-next): concur with linux-host recipe-convergence response
  - `7fd9d855` Merge remote-tracking branch 'origin/linux-next' into windows-next
  - `b3ca2747` docs(windows-next): record owner Path-B decision + sync linux-next methodology
  - Net diff: +55 lines in `plan/issues/tray-convergence-coordination.md`, zero
    code changes.
  - `./build.sh --check`: PASSED. `./build.sh --test`: PASSED.
- osx-next: no-op (still at `ddf52dff` = `main`, no movement since alignment).

- **Cross-host milestone (highest-signal item this cycle):**
  - **Owner ruled Path B with hard deadline 2026-05-31.** Quoted from the
    merged update to `plan/issues/tray-convergence-coordination.md`:
    > Land model-independent Phase 4 (tray + `control-wire-pty-attach`) on all
    > three hosts FIRST. Defer the recipe-vs-CI-fetch decision.
    > Hard deadline: 2026-05-31 — by which `vm-recipe-provisioning` must be
    > amended (promote CI-materialized-rootfs dual-path to a first-class
    > design, per the linux-host amendment request) or explicitly replaced.
  - Windows-host concurs with the linux-host response on every major point
    (co-ownership split, CI-materialized-rootfs-as-Windows-default, frozen
    contracts, Path-B sequencing).
  - Owner also approved windows-next syncing linux-next methodology + the
    recipe/pty-attach proposals into windows-next; that merge is green on
    Windows.

- **Spec-drift advisory:**
  - Zero changes to `openspec/specs/`, `openspec/changes/`, `methodology/`
    this cycle. Windows host is being disciplined: it explicitly will NOT edit
    `openspec/changes/vm-recipe-provisioning/*` (change-owner's artifact).
  - The amendment itself (D6 dual-path design section) is now scheduled work
    that must land before 2026-05-31. No host has claimed ownership of the
    amendment yet — likely candidates: the change owner directly, or linux-host
    on the owner's behalf since linux-host raised the amendment request.

- **Blockers cited by both hosts before recipe implementation can start:**
  1. macOS must respond in
     `plan/issues/macos-recipe-convergence-response-2026-05-24.md` (file does
     not yet exist; osx-next branch unchanged since alignment).
  2. `vm-recipe-provisioning` must be amended (promote D5/R1 fast-path to
     first-class D6) or explicitly replaced.
  3. Until both happen, no host implements the materializer.

### Cycle 2026-05-25T02:00Z — INTEGRATED (manual nudge, post-cleanup)

- host_id: linux-tlatoani-fedora (macuahuitl.ayahuitlcalpan.com)
- platform: linux
- branch: linux-next
- upstream_commit (pre-merge): a4c3c4665774adb411f9622bc73184deb4c23661
- observed_sibling_heads:
  - main: ddf52dffcda4f5d32104179cdaf7e4b87221300d
  - linux-next: a4c3c4665774adb411f9622bc73184deb4c23661
  - windows-next: 6d7d06a874cc3cc3d1491dbf9211087825053649
  - osx-next: ddf52dffcda4f5d32104179cdaf7e4b87221300d

- windows-next: **merged + tested + pushed** (`4789fa14`). 12 commits absorbed,
  ranging from Phase 0 thin-tray bring-up through Phase 4 portable menu-action
  resolver, Phase 2 resumable provisioning downloads, embedded app manifest
  (DPI awareness), host-side ~/src project scan, gitignore for scheduler
  state, and the response to my cycle 01:43Z conflict advisory (`6d7d06a8`).
  - `./build.sh --check`: PASSED (all crates incl. tillandsias-windows-tray
    and tillandsias-macos-tray type-check on Linux host).
  - `./build.sh --test`: PASSED.
- osx-next: no-op (still at `ddf52dff` = `main`).

- Spec/methodology drift (advisory):
  - Windows host added 3 NEW shared `plan/` files:
    `plan/issues/tray-convergence-coordination.md` (187L),
    `plan/issues/windows-next-architecture-decision-2026-05-24.md` (85L),
    `plan/steps/windows-next-thin-tray.md` (133L).
  - Zero modifications to existing `methodology/`, `openspec/specs/`, or
    pre-existing `plan/` files — no merge conflict surface.
  - Action: Linux host should read `plan/issues/tray-convergence-coordination.md`
    to confirm shared tray-protocol decisions still hold; if any decision needs
    a Linux-side spec/methodology amendment, file a NEW change rather than
    editing the Windows-authored file (tombstone/supersede policy).

- Methodology weak point spotted (feedback for next cron tick + other hosts):
  - The `.claude/scheduled_tasks.lock` file is created by the cron scheduler
    in EVERY session and is currently NOT in `.gitignore` on this branch
    (Windows host added the ignore in commit `057c60f8`, which only landed now
    on linux-next via this merge). Hosts running the loop before this commit
    would have a permanently-dirty working tree if they ever staged `-A`.
    Now resolved on linux-next.

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

- **CLEARED 2026-05-25T~05Z** — `vm-recipe-provisioning` D6 amendment landed
  on linux-next (`70c7c2a0`, macOS-authored). Windows-host spec-delta
  reconciliation also landed (`0d7a32cf`). Recipe implementation is now
  unblocked. macOS Phase 1 vz-spike is progressing
  (`3716dd40`, `3db11291`, `3cd90335`).
- **USER DECISION REQUESTED** — should `osx-next` be retired as a
  platform branch, since macOS host is committing directly to `linux-next`?
  See cycle `05:43Z` drift advisory item 1. If retired: simplify the loop
  (drop `osx-next` from `git ls-remote` + merge attempt), update
  `methodology/multi-host-development.yaml`, and tombstone the branch
  reference. If kept: notify macOS host of the convention.
- **Loop enhancement candidate** — surface claim-collision warnings before
  drafting cross-host artifacts (cycle 05:43Z drift advisory item 2).
  Implementation: at start of cycle, scan `plan/issues/` for unresolved
  CLAIM blocks and warn if any sibling has also touched the claimed scope
  in their last 3 commits.
- **Backlog cleared** as of `2026-05-25T02:00Z` — `windows-next` Phase 0–4
  integrated cleanly, tests passed. As of `2026-05-25T03:43Z` the Windows
  Phase-4 model-independent slice is fully landed on linux-next.
- **Methodology refinement for next iteration** (feedback to all three hosts):
  - The "dirty working tree blocks merge" rule worked as intended, but the
    backlog grew silently across two cycles before the human intervened.
    Recommend adding a soft escalation in the loop: after 1 dirty-tree skip
    with a >5-commit backlog, ping the user proactively rather than waiting
    for the next cron tick. (Filed for follow-up.)
  - Windows host's commit `057c60f8` (gitignore for scheduler state) should
    have been a methodology-level decision so all three hosts adopt it
    simultaneously. Now that it's on `linux-next`, Linux is covered. macOS
    host will pick it up on the next merge of `linux-next` → `main` →
    `osx-next` chain.
- `osx-next` has not advanced since alignment; the macOS terminal will likely
  push Phase 5+ work soon — the loop will pick it up automatically.
- Linux-host work-in-flight (separate from this loop): see
  `plan/steps/20-recent-work-spec-doc-methodology-audit.md` and the existing
  step backlog under `plan/steps/`.
