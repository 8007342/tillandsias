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

### Item: w1/tray-icon-rc-and-ico

- id: `w1/tray-icon-rc-and-ico`
- type: feature
- owner_host: windows
- capability_tags: [win32, rc, art-pipeline]
- status: pending
- depends_on: []
- blocks: []
- owned_files:
  - `crates/tillandsias-windows-tray/assets/tillandsias.rc`
  - `crates/tillandsias-windows-tray/assets/*.ico` (new)
  - `crates/tillandsias-windows-tray/build.rs`
- summary: >
    Ship a real Win32 application icon resource (`tillandsias.rc` +
    embedded `.ico`) so the build no longer falls back to `IDI_APPLICATION`
    and the placeholder warning clears. Per
    `plan/steps/windows-next-thin-tray.md`, this was explicitly deferred
    "until art/rasterizer lands"; the rasterizer is now landed (see
    `assets/tillandsias-svg/` from earlier Linux tray work + the
    `tray-svg-rasterizer` proposal in `openspec/changes/`).
- estimated_effort: 1–2 h on Windows; mostly running an existing
    SVG→ICO rasterizer pipeline and committing the resulting `.ico`.
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
| `l1/control-wire-pty-attach-tasks-1` | in_progress (this session) | w4 |
| `l2/recipe-shared-modules` | pending | w5 |
| `l3/in-vm-headless-pty-handler` | pending (after l1) | w4 |
| `l4/replace-vsock-stub-handlers` | pending | w6 |
| `l5/recipe-smoke-ci-publish` | pending (gated on l2) | w5 |

## Events

<!-- Append events here when claiming/progressing items. Append-only. -->
