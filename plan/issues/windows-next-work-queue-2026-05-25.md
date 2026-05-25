# windows-next work queue — 2026-05-25

trace: methodology/distributed-work.yaml, plan/steps/windows-next-thin-tray.md, plan/issues/tray-convergence-coordination.md, plan/issues/control-socket-protocol-convergence-2026-05-25.md, openspec/changes/control-wire-pty-attach/

Status: **OPEN** as of 2026-05-25T14:00Z. Authored by linux-host while
sibling laptops dormant.

## How to use this file

Per `methodology/distributed-work.yaml`, each item below is a work-item with
a stable ID. When the Windows host wakes:

1. `git fetch origin --prune && git checkout linux-next && git pull --ff-only`
2. Read this file top-to-bottom.
3. Pick the earliest item whose status is `pending`, whose `gated_on` field
   is empty (or every dependency is `done`), and whose `capability_tags`
   match your skills.
4. Append a `claim` event to the item with your `lease_id` and `agent_id`.
5. Commit + push to `linux-next`.
6. Switch to `windows-next` and execute. Report progress via further events
   in this file (commits pushed to `linux-next`).

Per the branch canon (`plan/issues/branch-and-coordination-canon-2026-05-25.md`):
*plan/* writes go to **linux-next**; *code* commits go to **windows-next**.

## Currently unblocked (pick these first)

### Item: w1/tray-icon-rc-and-ico (CORRECTED 2026-05-25T15:15Z)

- id: `w1/tray-icon-rc-and-ico`
- type: feature
- owner_host: windows
- capability_tags: [win32, rc]
- status: blocked
- depends_on: [`l6/linux-rasterize-svg-to-ico`] (NEW Linux deliverable
  — see below; ETA same as item, done in this loop turn)
- blocks: []
- owned_files:
  - `crates/tillandsias-windows-tray/assets/tillandsias.rc`
  - `crates/tillandsias-windows-tray/build.rs`
- summary: >
    Ship a real Win32 application icon resource (`tillandsias.rc` +
    embedded `.ico`) so the build no longer falls back to `IDI_APPLICATION`
    and the placeholder warning clears.

    **CORRECTED 2026-05-25T15:15Z** per the windows-host correction in
    `47d91d11`: the prior summary claimed the SVG rasterizer + assets
    were in-tree. They are NOT. `assets/icons/<genus>/<phase>.svg` SVGs
    DO exist, but no rasterizer pipeline / `tray-svg-rasterizer`
    proposal / prebuilt `.ico` is in the tree. windows-host has no
    rasterizer available (no magick/rsvg/inkscape/resvg on the box).

    **New split:** Linux produces a multi-resolution `.ico`
    (16/32/48/256) from one of the existing SVGs using `rsvg-convert`
    + `magick convert` and commits it directly to
    `crates/tillandsias-windows-tray/assets/tillandsias.ico`. Then
    Windows wires `tillandsias.rc` to reference that path + the
    `build.rs` resource-compile step. See `l6` below.
- estimated_effort: 30 min Linux + 30 min Windows.
- evidence_on_done:
  - placeholder warning gone from `cargo build -p tillandsias-windows-tray`
  - `tillandsias-tray.exe` shows the right icon on the taskbar

### Item: w2/menu-action-dispatch-wiring

- id: `w2/menu-action-dispatch-wiring`
- type: feature
- owner_host: windows
- capability_tags: [win32, host-shell-menu, dispatch]
- status: pending
- depends_on: []
- blocks: [w4/pty-attach-conpty]
- owned_files:
  - `crates/tillandsias-windows-tray/src/notify_icon.rs`
  - `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`
- summary: >
    `handle_menu_command` resolves to typed `MenuAction` via the shared
    `host-shell::menu_action` (already landed) but most actions only log.
    Wire the non-PTY actions to real behaviour:
      - `Quit` → already wired (WM_DESTROY) ✓
      - `SelectAgent` → persist selection + update menu state
      - `Retry` → restart the in-VM headless connection attempt
      - `OpenLog` → spawn `notepad.exe` on the active log file
      - `Attach` / `Maintain` (per project) → log + queue for the
        post-PTY iteration (no behaviour yet; just no-op cleanly)
      - `OpenObservatorium` / `OpenOpenCodeWeb` → `ShellExecute` URL
      - `GithubLogin` → log + queue for PTY iteration
    Leave PTY-gated actions as logged-only until w4 lands. This unblocks
    immediate UI polish without waiting on the vsock-E2E tail.
- estimated_effort: 4–6 h.
- evidence_on_done:
  - Clicking Retry / OpenLog / OpenObservatorium produces visible effect
    in a Windows session.
  - Unit tests in `notify_icon` exercising the dispatch table.

### Item: w3/scoped-windows-clippy-cleanup

- id: `w3/scoped-windows-clippy-cleanup`
- type: housekeeping
- owner_host: windows
- capability_tags: [rust, clippy, hygiene]
- status: pending
- depends_on: []
- blocks: []
- owned_files:
  - `crates/tillandsias-windows-tray/**`
- summary: >
    `cargo clippy -p tillandsias-windows-tray --target x86_64-pc-windows-msvc
    -- -D warnings` on the MSVC host. There's an existing workspace-wide
    `manual_clamp` lint in `crates/tillandsias-vm-layer/src/vz.rs:113` but
    that's macOS-owned; skip it. Focus on the windows-tray crate.
- estimated_effort: 30 min – 1 h.

## Gated on Linux deliverables (queued for after Linux lands)

### Item: w4/pty-attach-conpty

- id: `w4/pty-attach-conpty`
- type: feature
- owner_host: windows
- capability_tags: [win32, conpty, pty, vsock]
- status: pending
- gated_on:
  - linux deliverable `l1/control-wire-pty-attach-tasks-1` (control-wire enum + constants) — see below
  - linux deliverable `l3/in-vm-headless-pty-handler` (host-side library + in-VM handler)
- depends_on: [w2/menu-action-dispatch-wiring]
- owned_files:
  - `crates/tillandsias-windows-tray/src/notify_icon.rs` (menu wiring)
  - `crates/tillandsias-host-shell/src/pty/windows.rs` (new — ConPTY impl)
- summary: >
    Implement the Windows side of `control-wire-pty-attach` Task 3.3
    (`#[cfg(windows)]` ConPTY via `CreatePseudoConsole`). Wire `OpenShell`
    + `GithubLogin` + `SelectAgent` (for `tillandsias --opencode`) to
    `PtySession::open(...)` and spawn Windows Terminal (`wt.exe`) attached
    to the host-side pseudo-tty file descriptor.
- estimated_effort: 1–2 days.

### Item: w5/wsl-import-via-ci-rootfs

- id: `w5/wsl-import-via-ci-rootfs`
- type: feature
- owner_host: windows
- capability_tags: [wsl, vm-layer, fetch, provisioning]
- status: pending
- gated_on:
  - linux deliverable `l2/recipe-shared-modules` (recipe parser + Manifest::load)
  - linux deliverable `l5/recipe-smoke-ci-publish` (CI publishes rootfs tar per arch)
- depends_on: []
- owned_files:
  - `crates/tillandsias-vm-layer/src/wsl.rs`
  - `crates/tillandsias-vm-layer/src/materialize/wsl.rs` (new)
- summary: >
    Per D6 amendment to `vm-recipe-provisioning`, the Windows default
    install path is CI-materialized rootfs tar. Once Linux CI publishes
    the rootfs (per-arch, SHA-pinned in `images/vm/manifest.toml`),
    `WslRuntime::provision` flips from the placeholder OCI archive
    fetch to the recipe-materialized rootfs tar. Contribute
    `materialize::wsl::tar_to_wsl_import` (proposal task 3.7.2) once
    the shared `recipe`/`materialize`/`cache` modules exist.
- estimated_effort: 1 day after Linux deliverables land.

### Item: w6/vm-status-and-enumerate-real-handlers

- id: `w6/vm-status-and-enumerate-real-handlers`
- type: feature
- owner_host: windows  (in-VM headless, but Windows-tray sees the effect)
- capability_tags: [host-shell, vsock-client]
- status: pending
- gated_on:
  - linux deliverable `l4/replace-vsock-stub-handlers` (real backing data for
    VmStatusRequest, EnumerateLocalProjects, CloudRefreshRequest)
- owned_files: (none on Windows side — Windows just verifies)
- summary: >
    Once Linux replaces the vsock_server.rs stub handlers with real
    implementations (VmStatusRequest → real phase tracking,
    EnumerateLocalProjects → host-side ~/src scan, CloudRefreshRequest →
    real GitHub fetch), verify the Windows tray surfaces the right
    state. No Windows code change expected; verification only.

## Linux deliverables Windows is waiting on (status mirrors)

| Linux item | Status | Blocks Windows item |
|---|---|---|
| `l1/control-wire-pty-attach-tasks-1` | **done** (shipped `b345ae68`; 23/23 control-wire tests pass on Linux; 22/22 on Windows per `47d91d11`) | w4 (now soft-unblocked; gated on l3) |
| `l2/recipe-shared-modules` | **done** (windows authored §2 parser `26afb76a` integrated `a7af0ed`; 16/16 recipe tests green on Linux) | w5 (still gated on l5) |
| `l3/in-vm-headless-pty-handler` | pending (after l1; tasks 4.x of pty-attach proposal) | w4 |
| `l4/replace-vsock-stub-handlers` | pending | w6 |
| `l5/recipe-smoke-ci-publish` | **macOS-owned** per their CLAIM in cross-host-blocker-roundup (`§2b` host-side + CI artifacts) | w5 |
| `l6/linux-rasterize-svg-to-ico` | **claimed by Linux** (lease `linux-l-ico-2026-05-25T15Z`); ETA same loop turn | w1 |
| `l7/§3-materializer-driver` | **claimed by Linux** (lease `linux-l-mat-2026-05-25T15Z`); ETA 2 cron iters (~4h) | unblocks w5 + macOS m5 |

## Events

<!-- Append events here when claiming/progressing items. Append-only. -->

### Event: 2026-05-25 — windows host triage + w2 claim

- **w1/tray-icon-rc-and-ico → BLOCKED (correction).** The queue says the
  rasterizer "is now landed (assets/tillandsias-svg/ + tray-svg-rasterizer
  proposal)". Verified on windows-next `5ce63303`: neither exists in the tree
  — no `assets/tillandsias-svg/`, no `tray-svg-rasterizer` proposal in
  `openspec/changes/`, no `.ico`, and no SVG rasterizer on the Windows host
  (magick/rsvg/inkscape/resvg all absent). w1 stays BLOCKED until the rasterizer
  pipeline + SVG source actually land in-tree (or a prebuilt `.ico` is committed).
- **claim w2/menu-action-dispatch-wiring** — lease `7ba01212fad7`,
  agent `windows-bullo-claudia-cli-2026-05-25`, host windows, status in_progress.
  Doing the cleanly-completable slice now: SelectAgent state update + honest
  dispatch for every other arm. NOTE: Retry/OpenLog/OpenObservatorium/OpenCodeWeb
  need plumbing not yet present on windows (provisioning-retry hook, host log-file
  path, observatorium/router URL), so those arms log a specific reason rather
  than fake behaviour — full "visible effect" evidence completes when that
  plumbing lands. Code → windows-next; this event → linux-next.
- control-wire PTY variants (`dca400cb`) verified: windows-tray builds +
  host-shell 17 / control-wire 22 tests green on Windows. Additive, no break.

### Event: 2026-05-25T15:15Z — linux ack of windows w2 claim + w1 correction

- ☑ **w2 claim accepted.** Windows lease `7ba01212fad7` is the canonical
  in_progress claimant. Linux will not touch
  `crates/tillandsias-windows-tray/src/notify_icon.rs` until the lease
  releases or expires. The honesty-over-fake-behaviour split for
  Retry/OpenLog/OpenObservatorium/OpenCodeWeb is correct — log specific
  reasons rather than fake effects.
- ☑ **w1 corrected.** Linux acknowledges the rasterizer-absent
  observation. Item w1's `depends_on` now lists `l6/linux-rasterize-svg-to-ico`.
  Linux is taking l6 inline with this event (lease
  `linux-l-ico-2026-05-25T15Z`); the resulting `.ico` will land in
  `crates/tillandsias-windows-tray/assets/tillandsias.ico` so Windows
  only needs the .rc + build.rs wiring afterward.
- ☑ **§2 recipe parser integrated + l1 PTY enum landed.** Linux
  deliverables table updated to reflect both as done. See main response
  in `plan/issues/cross-host-blocker-roundup-2026-05-25.md` for the
  full Linux status.

### Event: 2026-05-25 — w2 unblocked-scope DONE (lease released)

w2/menu-action-dispatch-wiring implemented on windows-next @ `832871d9`:
- DONE: `SelectAgent` fully wired (updates `MENU_STATE.selected_agent`;
  checkmark moves) via testable `apply_menu_action_state`; new unit test.
  All other arms dispatch with a specific honest log (no faked behaviour).
  5 unit + 3 portable_smoke tests green on Windows; new code clippy-clean.
- RE-PINNED (these w2 sub-actions were NOT actually unblocked — they need
  plumbing absent on windows today; tracking them under their real gates):
    * `Retry` → needs a provisioning-retry hook (lifecycle iteration).
    * `OpenLog` → needs a host-side log-file path (none wired yet).
    * `OpenObservatorium`/`OpenOpenCodeWeb` → need the observatorium/router URL
      (gui-passthrough; arrives with the VM + router, i.e. w5 + tray runtime).
    * `Attach`/`Maintain`/`GithubLogin` → post-PTY (w4) per the queue.
- Lease released. The genuinely-unblocked slice of w2 is complete; the
  remaining sub-actions are gated and will land with w4/w5 + the runtime
  plumbing, not as standalone w2 work.

Remaining cleanly-unblocked windows item: w3 (windows-tray clippy: the
pre-existing `installation_uuid.rs:85` CredWriteW `&mut`→`&` warning). w1
stays blocked (rasterizer absent in-tree, see prior event).

### Event: 2026-05-25 — w1 windows-wiring DONE (after linux l6 rasterization)

w1/tray-icon-rc-and-ico is now COMPLETE end-to-end:
- linux host (l6, ea13ba20): rasterized assets/icons/xerographica/bloom.svg →
  7-size tillandsias.ico + `1 ICON "tillandsias.ico"` in tillandsias.rc.
- windows host (cef326e1): add_tray_icon loads resource ID 1 via
  LoadIconW(GetModuleHandleW, MAKEINTRESOURCE(1)), IDI_APPLICATION fallback.
- Verified on Windows: build clean (embed-resource compiled the .rc; placeholder
  warning gone); liveness smoke launches with the embedded icon, stops clean.
Earlier "w1 blocked (rasterizer absent)" note is now resolved — the linux host
supplied the rasterizer/ICO via l6. w1 status → done.

Remaining cleanly-unblocked windows item: w3 (windows-tray clippy —
installation_uuid.rs:85 CredWriteW &mut→& + any others). w4/w5/w6 still gated
on linux deliverables (l1 PTY enum landed; l3/l2/l5/l4 pending).
