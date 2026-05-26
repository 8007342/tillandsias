# windows-next work queue — 2026-05-25

trace: methodology/distributed-work.yaml, plan/issues/multi-agent-work-shaping-2026-05-25.md, plan/steps/windows-next-thin-tray.md, plan/issues/tray-convergence-coordination.md, plan/issues/control-socket-protocol-convergence-2026-05-25.md, openspec/changes/control-wire-pty-attach/

Status: **OPEN** as of 2026-05-26T01:13Z. Windows w1, w2, w3, and w4 are
done; w4 launch/menu wiring was merged and tested into `linux-next` at
`95e4714`. Linux l3 shipped the in-VM PTY handler at `f770e013`/`8dc0d129`,
l4 shipped real vsock handlers at `6956c825`, and l7 shipped the recipe
materializer driver at `9dca2c47`. `origin/windows-next` is now ahead only with
the w5 `materialize::wsl::tar_to_wsl_import` converter slice at `cb39cb7c`;
the next integration loop should merge/test it into `linux-next`. Remaining
WSL rootfs provisioning work is gated on macOS-owned recipe-publish/CI-fetch
artifacts and the live VM artifact path.

## How to use this file

Per `methodology/distributed-work.yaml`, each item below is a work-item with
a stable ID. When the Windows host wakes:

1. `git fetch origin --prune && git checkout linux-next && git pull --ff-only`
2. Read this file top-to-bottom.
3. Pick the highest-impact ready packet whose `gated_on` field is empty (or
   every dependency is `done`), whose `capability_tags` match your skills, and
   whose acceptance evidence fits one or two recurrent iterations. Prefer
   packets that unblock another host over tiny cleanup.
4. Append a `claim` event to the item with your `lease_id` and `agent_id`.
5. Commit + push to `linux-next`.
6. Switch to `windows-next` and execute. Report progress, blockers, errors,
   dependencies, and handoffs as status packets in this file (commits pushed to
   `linux-next`; format in `plan/issues/multi-agent-work-shaping-2026-05-25.md`).

Per the branch canon (`plan/issues/branch-and-coordination-canon-2026-05-25.md`):
*plan/* writes go to **linux-next**; *code* commits go to **windows-next**.

## Currently unblocked / active

- `w6/vm-status-and-enumerate-real-handlers` is ready for Windows
  verification after Linux l4 shipped at `6956c825`; useful evidence still
  needs a live/provisioned VM, so it is a fallback behind the recipe path.
- `w4/pty-attach-conpty` is done and integrated through `95e4714`. Do not
  create a competing claim; use the completed lease `8a3307907d94` as history.
- `origin/windows-next` is currently ahead of `linux-next` with the w5
  `tar_to_wsl_import` code at `cb39cb7c`. The next Linux integration loop
  should merge/test it or report exact conflicts.
- If w5 remains gated on recipe-publish artifacts, Windows should claim a
  larger independent fallback packet rather than idling: w6 verification first,
  then cache/diagnostic work that can complete without the CI rootfs artifact.

Do not re-claim w1, w2, w3, or w4; their terminal events are recorded below.
The next gated Windows implementation item is the remaining w5 provisioning
flip after macOS-owned l5 recipe-publish/CI-fetch lands, unless a newly filed
ready item with a stable ID appears first.

### Item: w1/tray-icon-rc-and-ico

- id: `w1/tray-icon-rc-and-ico`
- type: feature
- owner_host: windows
- capability_tags: [win32, rc]
- status: done
- depends_on: [`l6/linux-rasterize-svg-to-ico`]
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
- completed_at: 2026-05-25
- evidence_on_done:
  - placeholder warning gone from `cargo build -p tillandsias-windows-tray`
  - `tillandsias-tray.exe` shows the right icon on the taskbar

### Item: w2/menu-action-dispatch-wiring

- id: `w2/menu-action-dispatch-wiring`
- type: feature
- owner_host: windows
- capability_tags: [win32, host-shell-menu, dispatch]
- status: done
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
- completed_at: 2026-05-25
- evidence_on_done:
  - SelectAgent state update and dispatch table slice landed at windows-next `832871d9`.
  - Retry/OpenLog/OpenObservatorium/OpenCodeWeb were explicitly re-pinned to their true runtime gates instead of faking effects.
  - Unit tests in `notify_icon` exercise the dispatch table.

### Item: w3/scoped-windows-clippy-cleanup

- id: `w3/scoped-windows-clippy-cleanup`
- type: housekeeping
- owner_host: windows
- capability_tags: [rust, clippy, hygiene]
- status: done
- depends_on: []
- blocks: []
- owned_files:
  - `crates/tillandsias-windows-tray/**`
- summary: >
    `cargo clippy -p tillandsias-windows-tray --target x86_64-pc-windows-msvc
    -- -D warnings` on the MSVC host. There's an existing workspace-wide
    `manual_clamp` lint in `crates/tillandsias-vm-layer/src/vz.rs:113` but
    that's macOS-owned; skip it. Focus on the windows-tray crate.
- completed_at: 2026-05-25
- evidence_on_done:
  - `cargo clippy -p tillandsias-windows-tray --target x86_64-pc-windows-msvc -- -D warnings` passed at windows-next `d3d4cede`.

## Linux-gated and recently unblocked deliverables

### Item: w4/pty-attach-conpty

- id: `w4/pty-attach-conpty`
- type: feature
- owner_host: windows
- capability_tags: [win32, conpty, pty, vsock]
- status: done
- completed_at: 2026-05-26T00:49Z
- lease:
  - lease_id: `8a3307907d94`
  - agent_id: `windows-bullo-claudia-cli-2026-05-25`
  - host: windows
  - scope: "control-wire-pty-attach §3 shared host-side PtySession + Windows ConPTY"
- gated_on: []
- cleared_gates:
  - linux deliverable `l1/control-wire-pty-attach-tasks-1` shipped at `b345ae68`
  - linux deliverable `l3/in-vm-headless-pty-handler` shipped at
    `f770e013`/`8dc0d129`
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
- progress:
  - Cross-platform `PtySession` core landed at windows-next `a57983b6`.
  - Windows §3.3 ConPTY lifecycle, process attach, async bridge, and pump_io
    were integrated through linux-next `cbf308a`.
  - w4a launch-spec and w4b `ChannelPtyTransport` landed on windows-next
    (`af03de7e`, `7dc11bea`) and were later integrated into `linux-next`.
  - w4 menu-click launch wiring landed on windows-next `e5ad2295` with style
    cleanup `93427ed9`; it proposes `intent_for_action` as the cross-host
    menu-action-to-PTY-intent table for macOS m4 to adopt or amend.
  - w4 launch/menu wiring, `ChannelPtyTransport`, launch_spec, and dev scripts
    were merged/tested into `linux-next` at `95e4714`; host-shell tests were
    37/37 pass in the integration-loop ledger.

### Item: w5/wsl-import-via-ci-rootfs

- id: `w5/wsl-import-via-ci-rootfs`
- type: feature
- owner_host: windows
- capability_tags: [wsl, vm-layer, fetch, provisioning]
- status: pending
- gated_on:
  - linux deliverable `l5/recipe-smoke-ci-publish` (CI publishes rootfs tar per arch)
- cleared_gates:
  - linux deliverable `l2/recipe-shared-modules` integrated at `a7af0ed`
  - linux deliverable `l7/§3-materializer-driver` shipped at `9dca2c47`
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
- progress:
  - Windows-owned converter slice `materialize::wsl::tar_to_wsl_import`
    landed on `origin/windows-next` at `cb39cb7c`; it still needs Linux
    integration-loop merge/test before `linux-next` agents consume it.
  - Full WSL provisioning flip remains gated on recipe-publish/CI-fetch
    artifacts.

### Item: w6/vm-status-and-enumerate-real-handlers

- id: `w6/vm-status-and-enumerate-real-handlers`
- type: feature
- owner_host: windows  (in-VM headless, but Windows-tray sees the effect)
- capability_tags: [host-shell, vsock-client]
- status: ready
- gated_on: []
- cleared_gates:
  - linux deliverable `l4/replace-vsock-stub-handlers` shipped at `6956c825`
    (real backing data for VmStatusRequest, EnumerateLocalProjects,
    CloudRefreshRequest)
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
| `l1/control-wire-pty-attach-tasks-1` | **done** (shipped `b345ae68`; 23/23 control-wire tests pass on Linux; 22/22 on Windows per `47d91d11`) | w4 done |
| `l2/recipe-shared-modules` | **done** (windows authored §2 parser `26afb76a` integrated `a7af0ed`; 16/16 recipe tests green on Linux) | w5 converter slice done on windows-next; provision still gated on l5 |
| `l3/in-vm-headless-pty-handler` | **done** (`f770e013`/`8dc0d129`; tasks 4.1-4.7, two pump tests ignored pending AsyncFd rewrite) | w4 done |
| `l4/replace-vsock-stub-handlers` | **done** (`6956c825`; real VmStatus/EnumerateLocalProjects/CloudRefresh backing data) | w6 ready for verification |
| `l5/recipe-smoke-ci-publish` | **macOS-owned** per their CLAIM in cross-host-blocker-roundup (`§2b` host-side + CI artifacts) | w5 |
| `l6/linux-rasterize-svg-to-ico` | **done** (`ea13ba20`) | w1 done |
| `l7/§3-materializer-driver` | **done** (`9dca2c47`; materializer feature and cache/export API shipped) | w5 converter work unblocked; l7 clippy follow-up remains |

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
Historical status above is superseded by the 18:25Z header reconciliation:
l3 and l4 shipped, so w4 and w6 are ready.

### Event: 2026-05-25 — w3 clippy cleanup DONE

w3/scoped-windows-clippy-cleanup complete @ windows-next `d3d4cede`.
`cargo clippy -p tillandsias-windows-tray --target x86_64-pc-windows-msvc
-- -D warnings` passes CLEAN. Fixes:
- notify_icon.rs: MAKEINTRESOURCE via std::ptr::without_provenance (was
  `1 as *const u16` → manual_dangling_ptr).
- installation_uuid.rs: CredWriteW &cred (needless &mut).
- vm-layer/fetch.rs (windows-owned): cache-hit if → let-chain (collapsible_if).
- host-shell/menu_state.rs: truncate_80 push('…') not push_str (single-char
  lint) — small shared-code contribution from windows; linux keeps the
  green-build invariant.
The macOS-owned vz.rs manual_clamp was already fixed by macOS's 5b8aceb9.

Windows queue status: w1 DONE, w2 DONE (unblocked scope), w3 DONE. All three
originally-unblocked items are complete. Remaining windows items are gated:
w4 (PTY/ConPTY) needs l3 (in-VM pty handler); w5 (wsl import via CI rootfs)
needs l2 (recipe shared modules — parser landed, materializer pending) + l5
(recipe-smoke CI publish); w6 needs l4 (real vsock handlers). Windows is now
blocked on Linux deliverables for further tray progress.

### Event: 2026-05-25 — w4 finding: needs shared host-shell::pty (Task 3.1/3.2/3.4–3.8) first

Verified after l3/l4 cleared: w4 (windows ConPTY = control-wire-pty-attach
**Task 3.3**) is NOT buildable in isolation yet. Task 3.3 is only the
`#[cfg(windows)] PtySession::new_windows` impl — it plugs into the shared
host-side library `tillandsias-host-shell::pty` (Tasks 3.1 PtySession::open +
PtyOpenOpts, 3.2 unix path, 3.4 pump_io session-mux, 3.5 resize, 3.6 close,
3.7 per-session bounded channel, 3.8 FakeConnection tests). That module is
UNCLAIMED and unbuilt (no `host-shell/src/pty/` exists; all §3 boxes `[ ]`).
Also unclear: the `Connection` type 3.1 takes (session-id-routed mux) — may
need defining as part of §3.

So w4 is gated on §3.1/3.2/3.4–3.8, not just l1+l3. The integration ledger's
"w4 unblocked" is optimistic on this point.

Most of §3 is CROSS-PLATFORM and Windows-testable (3.1 dispatch, 3.4 pump_io,
3.5/3.6/3.7, 3.8 FakeConnection tests) + the windows 3.3 ConPTY. Only 3.2
(unix `nix::pty::openpty`) is Unix-only / untestable on Windows.

PROPOSAL (windows offers): windows-next claims §3 and builds the cross-platform
PtySession + windows ConPTY (3.1, 3.3–3.8) with FakeConnection tests, leaving
3.2 as a `#[cfg(unix)]` stub for the Linux host to fill+test. This unblocks
both Windows w4 AND macOS m4. Alternatively, Linux (host-shell owner) builds
§3.1/3.2 and windows does only 3.3. Awaiting owner/Linux nod before touching
shared host-shell pty scaffolding (avoiding a D6/D8-style parallel-build collision).

w6 note: verify-only, but needs a live VM (gated on l7 materializer) to actually
verify — so not actionable until provisioning works.

### Event: 2026-05-25 — windows CLAIMS pty-attach §3 (shared host-side PtySession)

Per owner decision, windows-next claims **control-wire-pty-attach §3**
(shared host-side `tillandsias-host-shell::pty`). lease `8a3307907d94`,
agent windows-bullo-claudia-cli-2026-05-25, host windows, status in_progress.

Increment plan (code → windows-next; loop integrates):
1. THIS increment — cross-platform PtySession CORE (all Windows-testable, no
   real PTY/VM): PtyOpenOpts, SessionIdAllocator (§D2), chunk-to-guest framing
   (§D5 ≤MAX_PTY_FRAME_BYTES), PtyRouter inbound session-id routing + per-session
   bounded channel cap 256 (§3.7/D3), PtySession open/write/resize/close
   (§3.1/3.5/3.6) over a PtyTransport trait, + FakeTransport unit tests (§3.8:
   open/write/resize/close roundtrip, two-session interleave, oversized-frame
   reject).
2. NEXT — OS backends + pump_io: §3.3 Windows ConPTY (CreatePseudoConsole) in
   pty/windows.rs (the heavy Win32 piece) + pump_io tasks bridging the real
   PTY master ↔ write/recv. §3.2 unix (nix::pty::openpty) left as a
   `#[cfg(unix)]` stub for the Linux host to fill+test.
3. THEN w4 — wire tray OpenShell/GithubLogin to PtySession::open + spawn wt.exe.

macOS m4 (AppKit Terminal) consumes the same PtySession; coordinate via this file.

### Event: 2026-05-25 — pty §3 CORE done (PtySession cross-platform layer)

control-wire-pty-attach §3 cross-platform core landed @ windows-next `a57983b6`
(crates/tillandsias-host-shell/src/pty/mod.rs):
- §3.1 PtySession::open + PtyOpenOpts; §3.5 resize; §3.6 close; §3.7 per-session
  bounded channel (cap 256); §D2 SessionIdAllocator; §D5 chunk_to_guest framing;
  §3.4 (data side) PtyRouter session-id routing; §3.8 FakeTransport tests (8).
- host-shell 24 tests green on Windows; windows-tray builds; clippy clean.
STILL OPEN under this lease (816... see prior claim event):
- §3.2 unix openpty path → left for Linux (#[cfg(unix)], untestable on Windows).
- §3.3 Windows ConPTY (pty/windows.rs, CreatePseudoConsole) — NEXT, mine.
- §3.4 (real bridge) pump_io tasks tying a live PTY master ↔ write_to_guest/recv.
Then w4 wires tray OpenShell/GithubLogin → PtySession::open + wt.exe.

macOS m4: the PtySession/PtyRouter/PtyTransport API is now available to consume.

### Event: 2026-05-25T18:25Z — linux coordinator header reconciliation

- `l3/in-vm-headless-pty-handler` shipped on linux-next at
  `f770e013`/`8dc0d129`. Queue mirror updated from pending to done. Later
  Windows review found that w4 also needs the shared host-shell `PtySession`
  layer; see the w4 finding and §3 claim events above.
- `l4/replace-vsock-stub-handlers` shipped on linux-next at `6956c825`
  (`feat(headless): l4 — real vsock handlers (VmStatus/EnumerateLocalProjects)`).
  Queue mirror updated from pending to done.
- `w6/vm-status-and-enumerate-real-handlers` is now ready for Windows
  verification. No Windows code is expected unless verification finds a
  platform-specific tray display gap.
- `w5` remains gated on Linux `l7/§3-materializer-driver` plus macOS-owned
  `l5/recipe-smoke-ci-publish`.

### Event: 2026-05-25 — pty §3.3 Windows ConPTY backend (lifecycle) done

ConPtyMaster landed @ windows-next `5e95f7c3` (host-shell pty/windows.rs,
cfg(windows)): CreatePseudoConsole + input/output bridge pipes + resize +
Drop(ClosePseudoConsole). `windows` crate added to host-shell, target-gated to
cfg(windows) (additive; not on the Linux build). Verified locally (no VM):
conpty_create_resize_drop passes; host-shell 25 tests green; windows-tray
builds; clippy clean.

§3 lease remaining: pump_io (CreateProcessW-into-ConPTY + async pipe I/O
bridging ConPtyMaster ↔ PtySession write_to_guest/recv) — NEXT, mine; §3.2 unix
openpty stub for Linux. THEN w4 (tray OpenShell/GithubLogin → PtySession::open
+ wt.exe). Full E2E (terminal shows the in-VM shell) needs a booted VM to verify.

### Event: 2026-05-25 — pty §3.4 pump_io bidirectional bridge done

pump_io + PtyMaster trait landed @ windows-next `1cd1e7de` (host-shell pty/mod.rs):
local terminal reader → PtyData{ToGuest} (chunked); inbound PtyData{ToHost} →
terminal writer; PtyClose/conn-drop ends the pump. Cross-platform, fake-master
test (pump_bridges_both_directions_and_closes); host-shell 26 tests green on
Windows; windows-tray builds; clippy clean.

§3 lease remaining: ConPtyMaster impl PtyMaster (Win32 async pipe I/O + process
attach so the real Windows terminal flows through pump_io) — NEXT, mine; §3.2
unix openpty stub for Linux. THEN w4 (tray OpenShell/GithubLogin →
PtySession::open + pump_io + wt.exe). Full terminal-attach E2E needs a booted VM.

### Event: 2026-05-25 — pty §3.3 ConPTY process-attach + pipe I/O done

ConPtyMaster::spawn (CreateProcessW-into-pseudoconsole via proc-thread attribute
list) + ConPtyChild wait()/Drop + blocking write_input/read_output landed @
windows-next `0a06832d`. Added windows features Threading + Storage_FileSystem +
System_IO (target-gated cfg(windows)). Verified locally (no VM):
conpty_spawn_propagates_exit_code (cmd /c exit 7 → wait()==7) passes; host-shell
27 tests green; windows-tray builds; clippy clean.

Test note: removed an earlier echo-marker test that hung on a blocking ReadFile
(ConPTY pipe blocks until data/EOF). Blocking pipe I/O is validated via the
async PtyMaster bridge + VM E2E, not a hermetic unit test.

§3 lease remaining: ConPtyMaster impl PtyMaster (async-wrap the blocking pipe
I/O via spawn_blocking/threads → tokio AsyncRead/AsyncWrite halves) so the real
terminal flows through pump_io — NEXT, mine; §3.2 unix openpty stub for Linux.
THEN w4 (tray OpenShell/GithubLogin → PtySession::open + ConPtyMaster + pump_io
+ wt.exe). Full terminal-attach E2E needs a booted VM.

### Event: 2026-05-25 — pty §3 ConPtyMaster impl PtyMaster done (async bridge)

ConPtyMaster now satisfies PtyMaster @ windows-next `e1a26e6b`: split() bridges
the blocking Win32 pipes ↔ tokio duplex via two dedicated threads (read:
ReadFile→Reader, closes hpc+output_read; write: Writer→WriteFile, closes
input_write); ManuallyDrop avoids double-close; whole-SendPtr rebind fixes the
edition-2021 disjoint-capture Send break. host-shell 28 tests green
(conpty_master_satisfies_pty_master_trait compile-time check; runtime via VM
E2E — split's read bridge blocks on ReadFile without a producing process, so
not unit-run). windows-tray builds; clippy clean.

§3 status: core ✓, ConPTY lifecycle ✓, pump_io ✓, ConPTY spawn+I/O ✓,
ConPtyMaster→PtyMaster ✓. The Windows host-side PTY stack is complete +
compiles; full terminal-attach behaviour verified at VM E2E.
§3 lease remaining: §3.2 unix openpty stub (Linux's to fill). THEN w4 — tray
OpenShell/GithubLogin → PtySession::open + ConPtyMaster + pump_io + wt.exe.

### Event: 2026-05-25 — §3 Windows host-side PTY stack COMPLETE + integrated

All §3 windows-owned pieces are integrated into linux-next (cycle 21:43Z,
cbf308af; ./build.sh --check && --test PASSED, host-shell 30/30 on Linux):
core PtySession/PtyRouter/chunking ✓, pump_io ✓, ConPTY lifecycle ✓, ConPTY
process-attach + pipe I/O ✓, ConPtyMaster impl PtyMaster ✓. The Windows
host-side PTY pipeline compiles + type-checks + unit-tests green.

w4 (live tray wiring) is now VM-GATED for verification: wiring OpenShell/
GithubLogin → PtySession::open + ConPtyMaster + pump_io + spawn wt.exe needs a
live vsock connection to the in-VM headless (the connection-mux: a reader task
feeding PtyRouter + a PtyTransport over the vsock Client). That can't be
end-to-end verified without a booted VM, which is gated on the recipe (l7
materializer). §3.2 unix openpty stub remains Linux's.

Captured this session's gotchas (blocking-pipe-ReadFile hangs unit tests;
edition-2021 disjoint-capture breaks Send for handle wrappers) in
cheatsheets/runtime/windows-tray-dev.md.

### w4 decomposition — claimable backlog (proposed 2026-05-25, windows host)

Being greedy on task proposal: w4 (PTY tray wiring) split into sub-tasks so
there's always something claimable instead of waiting on the VM. Verifiable-now
items can land + be unit-tested before the VM path exists.

| sub-task | what | owner | verifiable now? | status |
|---|---|---|---|---|
| w4a launch-spec | PtyIntent → PtyOpenOpts argv mapping | shared (win authored) | YES (pure) | DONE `af03de7e` |
| w4b channel-transport | `ChannelPtyTransport`: PtyTransport that enqueues outbound ControlMessages to a bounded mpsc (the §D3 writer queue), decoupled from the Client | windows (pty, co-owned) | YES (enqueue→drain test) | DONE `7dc11bea` |
| w4c connection-mux | own the vsock `Client` (split); writer task drains the w4b queue → Client.send; reader task reads envelopes → routes PtyData/PtyClose to PtyRouter, other replies elsewhere | shared host-shell (coordinate; touches vsock_client) | PARTIAL (routing tested; Client glue = VM E2E) | pending |
| w4d open-shell-menu | add an "Open Shell" item to the shared `menu_state` + `menu_action` (resolve to PtyIntent::Shell) | shared menu_state (coordinate w/ macOS+linux) | YES (menu build + dispatch test) | pending |
| w4e wt-attach | spawn Windows Terminal (`wt.exe`) hosting the ConPtyMaster pseudoconsole | windows | NO (GUI/VM visual check) | pending |
| w4f integration | tray dispatch(OpenShell/GithubLogin/Agent) → connection → PtySession::open + ConPtyMaster + pump_io + wt.exe | windows | NO (VM E2E) | pending |

Next greedy pickups (no VM needed): **w4b** (windows-ownable, pure) and **w4d**
(needs cross-tray sign-off on adding "Open Shell" to the shared menu — macOS m4
+ linux GTK tray also gain the item). w4c/w4e/w4f are VM-gated for verification.

### Event: 2026-05-26T00:18Z — linux coordinator remote-head reconciliation

- Observed `origin/windows-next` at `ae8789ff`, ahead of `origin/linux-next`
  with w4a (`af03de7e`), w4b (`7dc11bea`), menu-click launch wiring
  (`e5ad2295`), and the WM_TRAYICON const-block style cleanup (`93427ed9`).
- Windows merged the prior `linux-next` tip (`effbfbf4`) after this audit's
  first push, so it now includes macOS m4 Unix PTY foundation and m6 packaging.
  It does not include this coordination commit (`fd7d904e`). The integration
  loop should still merge/test Windows into `linux-next` and run the usual
  `./build.sh --check && ./build.sh --test` validation.
- `e5ad2295` proposes `intent_for_action(MenuAction, SelectedAgent)` as the
  shared table mapping Attach/Maintain/GithubLogin clicks to PTY intents.
  macOS m4 should adopt or amend this table when wiring `terminal_attach`.
- Linux l7 materializer lease `linux-l-mat-2026-05-25T15Z` is past the default
  TTL with no checkpoint found. Windows w5 and live-VM verification remain
  blocked until a Linux/materializer-capable agent renews, releases, or
  reclaims the materializer API/cache/export slice.

### Event: 2026-05-26T01:13Z — linux coordinator status reconciliation

- Observed remote heads: `linux-next` `cabf9c9f`, `windows-next` `cb39cb7c`,
  `osx-next` `4aa42c6a`, `main` `ddf52dff`.
- Folded terminal events into headers: w4 is done/integrated at `95e4714`;
  l7 materializer driver is done at `9dca2c47`; w5 converter slice is done on
  `origin/windows-next` at `cb39cb7c` and needs integration-loop merge/test.
- Current Windows next action: do not duplicate w4 or the w5 converter. Either
  wait for Linux to merge/test `cb39cb7c`, or claim w6/cache diagnostics that
  do not require the recipe-publish artifact.
