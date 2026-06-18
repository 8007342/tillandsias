# Clone succeeds on disk but tray UX never updates and ~/src list is not refreshed — 2026-06-18

Reported by: The Tlatoani (direct, 2026-06-18)

## Summary

Cloning a remote repo from the tray succeeds on disk, but the tray UX is never
updated and the local `~/src` project list never picks up the new checkout.
Operator report (verbatim):

> "Cloning remote repos: the tray UX line updates to a 'cloning repo'
> notification, and the clone succeeds on disk, but the tray UX is never updated
> (stays on 'cloning repo'), and the ~/src/ (home/src/) list is never updated
> with the cloned checkout."

Two distinct UX defects, same handler:

1. The "⏳ Cloning … " status line is set but never cleared/replaced on the
   success path, so the tray appears stuck on the cloning notification.
2. The local `~/src` submenu (`🏠 ~/src`) is built from `state.projects`, which
   is populated **once at tray startup** and is never re-scanned after a clone,
   so the freshly cloned checkout does not appear.

## Suspected code paths

Active clone handler (the path the tray actually uses today):

- `crates/tillandsias-headless/src/tray/mod.rs:1692-1798` —
  `handle_launch_cloud_project`. This is the live "clone-then-launch" flow used by
  the `☁️ Cloud >` submenu.
  - `mod.rs:1755-1759` sets `"⏳ Cloning {name} ..."` via `set_status(...,
    TrayIconState::Building, None)`.
  - `mod.rs:1760-1769` clones (`remote_projects::clone_project_from_github`). On
    **error** it sets a `"🥀 Clone failed"` status and returns.
  - On **success** there is **no `set_status` call** to clear the cloning line —
    control falls straight through to `handle_launch_project` at `mod.rs:1789`.
    So the "⏳ Cloning …" text is never replaced on success → tray "stays on
    'cloning repo'", exactly as reported.
  - Crucially, this handler also never re-scans `~/src` and never calls
    `rebuild_after_state_change`, so `state.projects` is not updated with the new
    checkout.

Where the local `~/src` list comes from (and why it goes stale):

- `crates/tillandsias-headless/src/tray/mod.rs:2285-2312` —
  `build_local_projects_submenu` builds the `🏠 ~/src` menu purely from
  `state.projects`.
- `crates/tillandsias-headless/src/tray/mod.rs:1263-1274+` —
  `discover_projects()` scans `$HOME/src`.
- `crates/tillandsias-headless/src/tray/mod.rs:3247-3248` —
  `discover_projects()` is called **once**, at tray startup, to seed
  `state.projects`. Grep shows no other writer of `state.projects` (no
  `state.projects =`, no re-scan-and-store after clone). So after the initial
  scan the local list is effectively frozen for the tray's lifetime.
- `crates/tillandsias-headless/src/tray/mod.rs:690-708` — there is an
  `EnumerateLocalProjects` control-message handler that does call
  `local_projects::scan_project_root(&host_project_root())`, but it replies over
  the control socket; it does not appear to write back into the tray's
  `state.projects` used to render the menu. Confirm whether anything consumes
  that reply to refresh the live menu.

What the *legacy* (dead) handler did right — useful as a reference:

- `crates/tillandsias-headless/src/tray/mod.rs:1894-1951` —
  `handle_clone_project` (marked `#[allow(dead_code)]`, "Legacy clone-project
  handler"). On success it sets `"✓ Cloned {name}"` (`mod.rs:1927-1931`) and then
  calls `rebuild_after_state_change` (`mod.rs:1945`). It still does NOT re-scan
  `~/src` into `state.projects` (so even this path would not add the checkout to
  the local list), but it does demonstrate the success-status + rebuild pattern
  the active handler is missing.

How a rebuild reaches the menu (for the fix):

- `crates/tillandsias-headless/src/tray/mod.rs:1116-1118`
  `rebuild_after_state_change` → `emit_refresh(true)` →
  `DbusMenuIface::layout_updated` (`mod.rs:1101-1111`). Rebuilding only re-renders
  from current `state.projects`; to surface the new checkout the handler must
  first re-scan `~/src` and store it into `state.projects` (via `with_state`,
  `mod.rs:1092`), then call `rebuild_after_state_change`.

## Reproduction (as the operator described)

1. Launch the tray on Linux with a logged-in GitHub session.
2. Open `☁️ Cloud >` and pick a repo not yet on disk (triggers
   `handle_launch_cloud_project`).
3. Observe the tray status change to `⏳ Cloning <name> ...`.
4. The clone completes and the checkout appears under `~/src/<name>` on disk.
5. Observed: the tray status stays on `⏳ Cloning <name> ...` (never cleared),
   and `🏠 ~/src` does not list the new checkout.

## Work Packet: bug/clone-tray-ux-not-refreshed

- id: `bug/clone-tray-ux-not-refreshed`
- type: bug
- owner_host: linux
- status: open
- severity: medium — clone functionally succeeds on disk; the defect is UX
  feedback and stale local-project listing, not data loss. Confusing (looks
  hung) but recoverable by restarting the tray.
- capability_tags: [clone, tray, ux, headless, fs-watch]
- depends_on: []
- related_packets:
  - `bug/github-login-failure`  # cloud discovery/clone are downstream of GitHub auth
- owned_files:
  - crates/tillandsias-headless/src/tray/mod.rs  # handle_launch_cloud_project (1692), discover_projects (1263), build_local_projects_submenu (2285), startup seed (3247), legacy handle_clone_project (1894), rebuild_after_state_change (1116)
  - crates/tillandsias-headless/src/local_projects.rs  # scan_project_root used by EnumerateLocalProjects
- investigation checklist (builder agent next steps):
  1. Reproduce the cloud clone of a not-yet-on-disk repo and confirm the status
     stays on "⏳ Cloning …" and the `🏠 ~/src` submenu does not gain the new
     checkout.
  2. In `handle_launch_cloud_project` (mod.rs:1692), on the clone-success path
     (after mod.rs:1769), set a success/cleared status (e.g. "✓ Cloned <name>"
     or return to the steady status) instead of falling straight through to
     `handle_launch_project` while still showing "Cloning …".
  3. After a successful clone, re-scan `~/src` (`discover_projects()` /
     `local_projects::scan_project_root(&host_project_root())`) and write the
     result into `state.projects` via `with_state` + `bump_revision`, then call
     `rebuild_after_state_change` so the `🏠 ~/src` submenu lists the new
     checkout. NOTE: no current code writes `state.projects` after startup — this
     refresh-and-store is the missing piece, and the legacy
     `handle_clone_project` did not have it either.
  4. Decide whether to centralize this in a single `refresh_local_projects()`
     helper used by both clone handlers (and any future fs-watch), to avoid the
     two handlers drifting again.
  5. Check whether the `EnumerateLocalProjects` control reply (mod.rs:690-708) is
     meant to feed the live menu; if so, reuse that scan rather than duplicating.
  6. Consider whether the legacy dead `handle_clone_project` (mod.rs:1894) should
     be removed or folded in once the active handler is fixed, to avoid two
     divergent clone behaviors.
  7. Add a test/gate proving: after a (mocked) successful clone, the cloning
     status is cleared AND `state.projects` contains the new checkout.
- acceptance_evidence:
  - After a successful clone from `☁️ Cloud >`, the tray status no longer stays
    on "⏳ Cloning …" (shows success or returns to steady state).
  - The `🏠 ~/src` submenu lists the newly cloned checkout without restarting the
    tray.
  - The clone-failure path still surfaces "🥀 Clone failed …".

## Events

- type: discovered
  ts: "2026-06-18T00:00:00Z"
  reporter: "The Tlatoani (direct)"
  host: linux
  note: >
    Operator reports a cloud clone succeeds on disk but the tray stays on the
    "cloning repo" notification and ~/src is never refreshed. Investigation: the
    active handler handle_launch_cloud_project (tray/mod.rs:1692) sets the
    cloning status but never clears it on success and never re-scans ~/src;
    state.projects is seeded once at startup (mod.rs:3247) and never updated after
    a clone. The legacy handle_clone_project shows the success-status+rebuild
    pattern but is dead code and also never re-scans ~/src. Filed as an open bug
    packet for pickup by /advance-work-from-plan.

- type: claimed
  ts: "2026-06-18T04:40:39Z"
  agent_id: linux-tlatoani-opus-worker3-20260618T044039Z
  host: linux
  note: >
    Claimed bug/clone-tray-ux-not-refreshed on linux-next. Root cause confirmed
    against current code: handle_launch_cloud_project (tray/mod.rs ~1716-1798)
    sets "⏳ Cloning …" but the clone-success path returns no clearing status —
    control falls through to handle_launch_project still showing the cloning
    line. state.projects is seeded once at startup (run_tray_mode_with_debug,
    discover_projects()) with no post-startup writer (grep confirms no other
    `state.projects =`), so a fresh checkout never reaches build_local_projects_
    submenu's 🏠 ~/src list. The EnumerateLocalProjects control handler scans but
    only replies over the socket; it does not write back into the live
    state.projects. Matches the packet's analysis exactly.

- type: progress
  ts: "2026-06-18T04:40:39Z"
  agent_id: linux-tlatoani-opus-worker3-20260618T044039Z
  host: linux
  fix_commit: 8e9fa2d9
  note: >
    Implemented the minimal fix in crates/tillandsias-headless/src/tray/mod.rs:
    (1) Added TrayService::refresh_local_projects() — the missing post-startup
    writer: re-scans ~/src via discover_projects(), stores into state.projects,
    updates projects_hash, bumps revision. (2) On the clone-success path in
    handle_launch_cloud_project (after clone_project_from_github succeeds) it now
    sets "✓ Cloned <name>" (TrayIconState::Mature), calls refresh_local_projects(),
    then rebuild_after_state_change() before handing off to handle_launch_project.
    The 🥀 Clone failed path is unchanged; the git-fetch (already-on-disk) branch
    is unchanged. (3) Extracted discover_projects_in(&Path) from discover_projects()
    so the scan-and-sort contract is unit-testable without mutating the
    process-global HOME. (4) Added regression test
    refresh_local_projects_picks_up_new_checkout (uses tempfile) asserting a
    rescan surfaces a newly created checkout, sorted, and bumps the menu revision.
    Did NOT remove the dead legacy handle_clone_project, and did NOT centralize
    both handlers into one helper beyond refresh_local_projects (handle_clone_
    project is dead and out of scope). Validated: cargo build/clippy --features
    tray (clean; pre-existing fetch_github_username dead_code + vault-cfg clippy
    suggestion are unrelated), cargo fmt --check clean, the new test passes, and
    ./build.sh --check passes (the "Failed to start dev proxy container" dev-cache
    warning is the known unrelated local issue).

- type: completed-pending-runtime
  ts: "2026-06-18T04:40:39Z"
  agent_id: linux-tlatoani-opus-worker3-20260618T044039Z
  host: linux
  fix_commit: 8e9fa2d9
  note: >
    Source-level fix landed on linux-next (commit 8e9fa2d9). Acceptance evidence
    for the status-clear, ~/src-refresh, and rebuild is covered at the unit level
    and by code inspection. OUTSTANDING / open evidence item: full runtime
    validation — actually cloning a not-yet-on-disk repo from ☁️ Cloud > on a
    live tray with a logged-in GitHub session and visually confirming the status
    clears to "✓ Cloned …" and 🏠 ~/src gains the new checkout without a restart —
    requires an operator and is left open. Not pushed; no merge-to-main/release.
