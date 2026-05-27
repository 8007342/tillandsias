# windows-next work queue — 2026-05-25

trace: methodology/distributed-work.yaml, plan/issues/multi-agent-work-shaping-2026-05-25.md, plan/steps/windows-next-thin-tray.md, plan/issues/tray-convergence-coordination.md, plan/issues/control-socket-protocol-convergence-2026-05-25.md, openspec/changes/control-wire-pty-attach/

Status: **OPEN** as of 2026-05-27T23:25Z. Windows w1, w2, w3, w4, w6
diagnostics, the w5 converter, the shared forge-container `launch_spec` /
`intent_for_action` amendment, the l9 URL resolver, the w5
`provision_via_recipe` runtime flip, and w8 HvSocket Ready proof are done on
the Windows lane. Windows real hardware proved rootfs fetch/SHA/import,
systemd boot, headless fetch HTTP 200, the F1 `Type=exec` unit fix, HvSocket
connect, Hello/HelloAck over the control-wire codec, tray status flipping to
Ready, VmStatus request/reply over HvSocket, Ready-phase provisioning gating,
PtyOpen/PtyData/PtyClose proof, bidirectional PTY stdin/stdout, WSL VM
keepalive, deterministic Quit drain, native-terminal menu launch for the Open
Shell / Attach / Maintain / GitHub Login argv path, Open Shell terminal-click
smoke, file-based tray logging plus working Open Log, Retry reprovisioning, and
forge-container Open Shell smoke. Newer Windows commits `9c7b30ce` and
`cca9da4a` add `--provision-once` headless mode and report the full
live-provision dress rehearsal as done.
The Windows-owned rustfmt blocker is cleared by `9315e9de`, and
`origin/windows-next` through `1e20d6d0` is now merged into
`origin/linux-next` by integration cycle `edfb72c6` / merge `b9cee2fd`;
`./build.sh --check` and `./build.sh --test` passed on the merged tree.
Runtime-litmus `20260527T231258Z-b06a5997-1e20d6d0-b06a5997` failed at `Disk
quota exceeded`; replacement full installed runtime-litmus
`20260527T231940Z-b06a5997-1e20d6d0-b06a5997` passed build/install and init,
then failed in the OpenCode diagnostics phase with a nested-runtime panic at
`crates/tillandsias-headless/src/vault_bootstrap.rs:205`. Push-time rebase
later absorbed `origin/linux-next` `891bb757`; after the panic is fixed, Linux
should start a fresh runtime for current `origin/linux-next`. Optional wire
`EnumerateLocalProjects` remains a fallback, not a blocker. The old PR #3 /
recipe-publish / SHA-pin / F1 / F2 gates are closed.

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

- `w8/hvsocket-control-wire-ready` is done on `windows-next`: `8a96a880`
  proved AF_HYPERV connect, `2b97be30` proved Hello/HelloAck, `340cac99`
  wired the handshake into `provision_via_recipe`, and `e0405f2f` flips the
  tray to Ready on handshake success. Linux integration-loop merge/test is
  complete in `b9cee2fd`; replacement full installed runtime validation is now
  blocked by diagnostics panic
  `20260527T231940Z-b06a5997-1e20d6d0-b06a5997`.
- `w9/control-wire-session-menu-routing` is in progress on `windows-next`:
  `8b785ced` proves VmStatus request/reply over HvSocket, `791c0187` makes
  provisioning wait for VM phase `Ready`, and `5188dce6` proves the
  PtyOpen/PtyData/PtyClose mechanism behind Open Shell. Newer commits
  `fc7d0b74`, `531bcce4`, `bc23a529`, and `c997fc43` add bidirectional PTY
  proof, WSL keepalive, Quit drain, and native-terminal launch for the resolved
  `launch_spec` argv. Commits `8e84df7d`, `0626a318`, `41c32174`, and
  `29fe3807` add Open Shell terminal-click smoke, file-based tray logging /
  working Open Log, Cargo.lock sync, and an updated thin-tray next action. The
  newer commits `f4c3d70f` and `c0a9558b` wire Retry to re-trigger guarded
  provisioning and prove the forge-container Open Shell argv. `9c7b30ce` /
  `cca9da4a` add and prove the live provision dress rehearsal. `9315e9de`
  clears the `wsl_lifecycle.rs` rustfmt blocker, and integration cycle
  `edfb72c6` merged Windows through `1e20d6d0` into `linux-next`. The
  remaining packet is the full installed runtime-litmus result plus optional
  wire EnumerateLocalProjects, not another transport primitive,
  terminal-launch proof, Retry hook, or formatting cleanup.
- `w7/recipe-diagnostics-and-branch-sync` is no longer the primary packet; use
  it only as a no-code fallback if the `c0a9558b` merge/test exposes stale
  diagnostics or a manifest/branch-sync conflict.
- `w6/vm-status-and-enumerate-real-handlers` is done as a no-VM diagnostics
  fallback through `948af711` / integration cycle `b3ae21a`. Live VM status
  verification now belongs to w9 session/menu routing over the proven Ready
  transport, not to the old artifact or F2 gates.
- `w4/pty-attach-conpty` is done and integrated through `95e4714`. Do not
  create a competing claim; use the completed lease `8a3307907d94` as history.
- `w5/wsl-import-via-ci-rootfs` has converter, URL resolver, runtime
  provisioning flip, systemd/root fixes, and real E2E proof. Treat remaining
  interaction work as w9 session/menu routing, not as w5 artifact gates.

Do not re-claim w1, w2, w3, w4, w5, w6, or w8; their terminal events are
recorded below. Continue w9 by waiting for the integrated full runtime-litmus
result, with optional wire EnumerateLocalProjects after validation and w7
diagnostics as the independent fallback if the runtime exposes stale branch or
manifest state.

### Item: w8/hvsocket-control-wire-ready

- id: `w8/hvsocket-control-wire-ready`
- type: feature
- owner_host: windows
- capability_tags: [win32, hvsocket, wsl, control-wire]
- status: done
- completed_at: 2026-05-27T06:51Z
- integration_status: merged into `linux-next` at `b9cee2fd`; `./build.sh
  --check` and `./build.sh --test` passed in integration cycle `edfb72c6`.
  Runtime-litmus `20260527T231258Z-b06a5997-1e20d6d0-b06a5997` failed at disk
  quota; replacement runtime-litmus
  `20260527T231940Z-b06a5997-1e20d6d0-b06a5997` failed in diagnostics with
  the `vault_bootstrap.rs:205` nested-runtime panic.
- gated_on: []
- cleared_gates:
  - Linux/recipe F1 headless service restart loop fixed at `f5801968`
    (`Type=exec`)
- depends_on: [w5/wsl-import-via-ci-rootfs]
- owned_files:
  - `crates/tillandsias-windows-tray/src/hvsocket.rs`
  - `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`
  - `crates/tillandsias-windows-tray/src/notify_icon.rs`
- summary: >
    Complete the Windows host-to-guest control-wire transport. WSL2 exposes
    the guest AF_VSOCK listener through Hyper-V sockets rather than a standard
    host AF_VSOCK CID. Use the WSL utility-VM GUID plus the port-derived
    service GUID to connect to the existing in-VM listener without changing the
    wire protocol.
- next_action: >
    Wait for Linux to fix or assign the `vault_bootstrap.rs:205`
    nested-runtime diagnostics panic, then let the integration loop run a fresh
    current-head runtime. Do not reopen w8 transport work unless the runtime
    produces fresh evidence against this item.
- acceptance_evidence:
  - Windows tray reaches Ready via HvSocket after `fetch-headless.service`
    installs the listener binary.
  - `scripts/diagnose-windows.ps1` or equivalent notes distinguish F2
    transport failures from any post-`f5801968` recipe-rootfs/unit regression.
- fallback_when_blocked: >
    Keep the recipe-provisioned distro and w5 proof as evidence; update w7
    diagnostics so the next agent sees the current F2/post-F1-fix split.
- agent_status_packet_expected:
  - current plan
  - dependencies and blockers
  - files touched
  - evidence produced
  - next checkpoint
  - lease intent

### Item: w9/control-wire-session-menu-routing

- id: `w9/control-wire-session-menu-routing`
- type: feature
- owner_host: windows
- capability_tags: [win32, hvsocket, control-wire, pty, menu]
- status: in_progress
- latest_progress_at: 2026-05-27T23:25Z
- latest_progress_refs:
  - `8b785ced` — VmStatus request/reply over HvSocket proven
  - `791c0187` — provisioning waits for VM phase `Ready`
  - `5188dce6` — PtyOpen/PtyData/PtyClose over HvSocket proven
  - `fc7d0b74` — host-to-guest PtyData stdin plus echoed stdout proven
  - `531bcce4` — WSL keepalive holds the control wire warm
  - `bc23a529` — Quit drains the VM / keepalive via `wsl --terminate`
  - `c997fc43` — menu actions launch the resolved argv in `wt.exe` / `wsl.exe`
  - `8e84df7d` — Open Shell terminal-click smoke passed on real Windows hardware
  - `0626a318` — file-based tray logging and Open Log reveal landed
  - `41c32174` — Cargo.lock synced for Windows tracing dependencies
  - `29fe3807` — thin-tray next action refreshed to current remaining scope
  - `f4c3d70f` — Retry re-triggers guarded provisioning after failure
  - `c0a9558b` — forge-container Open Shell smoke passed on real Windows hardware
  - `9c7b30ce` — `--provision-once` headless mode live dress rehearsal passed
  - `cca9da4a` — full live-provision dress rehearsal marked done
  - `9315e9de` — `wsl_lifecycle.rs` rustfmt blocker cleared
  - `edfb72c6` / `b9cee2fd` — Windows w9 delta merged/tested into `linux-next`
- depends_on: [w8/hvsocket-control-wire-ready]
- gated_on: []
- owned_files:
  - `crates/tillandsias-windows-tray/src/hvsocket.rs`
  - `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`
  - `crates/tillandsias-windows-tray/src/notify_icon.rs`
- summary: >
    Continue from the proven Ready flow by retaining the live HvSocket
    control-wire stream in the tray session and routing menu actions over it.
    Ready should become the start of real interaction, not just the end of
    provisioning.
- next_action: >
    Wait for Linux to fix or assign the `vault_bootstrap.rs:205`
    nested-runtime diagnostics panic, then start a fresh runtime for current
    `origin/linux-next`. If the fresh current-head run passes, treat w9 as
    integration-complete and continue only optional wire EnumerateLocalProjects
    if host-side project scan is not sufficient.
- acceptance_evidence:
  - `8b785ced`: Windows tray can request VmStatus after the Ready flip without
    reopening provisioning.
  - `791c0187`: tray reports Ready only after the VM replies with phase
    `Ready` and `podman_ready: true`.
  - `5188dce6`: PtyOpen over HvSocket receives PTY output and PtyClose for the
    Open Shell mechanism.
  - `fc7d0b74`: PtyData from host to guest is echoed back over the HvSocket PTY
    path.
  - `531bcce4`: a held `wsl --exec sleep infinity` keepalive prevents utility
    VM idle shutdown while the tray is running.
  - `bc23a529`: Quit tears down the VM/keepalive with bounded `wsl --terminate`.
  - `c997fc43`: Open Shell / Attach / Maintain / GitHub Login launch the
    resolved forge argv in Windows Terminal with `wsl.exe` fallback.
  - `8e84df7d`: terminal-click smoke passed for `wt.exe`, `wsl.exe`, bare-VM
    `/bin/bash -l`, and spaced-title quoting.
  - `0626a318` / `41c32174`: file-based tracing writes
    `%LOCALAPPDATA%\tillandsias\logs\tray.log`; Open Log reveals it in
    Explorer; lockfile includes the tracing deps.
  - `f4c3d70f`: Retry sets the tray to "Retrying provisioning..." and
    re-triggers `provision_via_recipe` only after failure while avoiding
    duplicate in-flight tasks.
  - `c0a9558b`: forge-container Open Shell smoke passed through `wsl.exe` into
    a running `tillandsias-<name>-forge` container.
  - `9c7b30ce` / `cca9da4a`: full live-provision dress rehearsal is reported
    done.
  - `9315e9de` / `edfb72c6`: Windows-owned rustfmt cleanup and
    integration-loop merge/test into `linux-next` are complete.
  - Remaining: full installed runtime-litmus result and optional wire
    EnumerateLocalProjects.
  - `cargo test -p tillandsias-windows-tray --target x86_64-pc-windows-msvc`
    or equivalent Windows-host evidence stays green.
- fallback_when_blocked: >
    Append a no-code agent_status_packet here and run w7 diagnostics with the
    current `linux-next` and `windows-next` heads.
- agent_status_packet_expected:
  - current plan
  - dependencies and blockers
  - files touched
  - evidence produced
  - next checkpoint
  - lease intent

### Item: w7/recipe-diagnostics-and-branch-sync

- id: `w7/recipe-diagnostics-and-branch-sync`
- type: diagnostics
- owner_host: windows
- capability_tags: [powershell, diagnostics, git, wsl]
- status: ready
- depends_on: []
- owned_files:
  - `scripts/diagnose-windows.ps1`
- summary: >
    Keep the Windows no-VM diagnostic current only as a fallback. The recipe
    artifact path is proven, so diagnostics should now distinguish completed
    w5 provisioning from F2 HvSocket transport work and any post-`f5801968`
    recipe-rootfs/unit regression. `origin/windows-next` has active unmerged code delta; do
    not report PR #3, first green recipe-publish, or manifest SHA pins as live
    blockers.
- next_action: >
    If F2/HvSocket is blocked, pull or merge latest `origin/linux-next` into
    `windows-next`, run `scripts/diagnose-windows.ps1` on Windows, and append
    an agent_status_packet here with branch-sync result plus the current F2
    state.
- acceptance_evidence:
  - `scripts/diagnose-windows.ps1` output on Windows, including WSL presence,
    recipe input detection, and the current workflow/artifact gate.
  - Pushed `windows-next` status/diagnostic commit if the script needs changes,
    or a no-code agent_status_packet if `83e2cd51` is sufficient.
- fallback_when_blocked: >
    Hand off to `w8/hvsocket-control-wire-ready` if diagnostics are current.
- agent_status_packet_expected:
  - current plan
  - dependencies and blockers
  - files touched
  - evidence produced
  - next checkpoint
  - lease intent

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
  - Open Log later became real at `0626a318`: the tray writes
    `%LOCALAPPDATA%\tillandsias\logs\tray.log` and reveals it in Explorer.
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
- status: done
- completed_at: 2026-05-27
- acceptance_status: rootfs_import_and_headless_fetch_proven_ready_waits_on_f1_f2
- gated_on: []
- cleared_gates:
  - linux deliverable `l2/recipe-shared-modules` integrated at `a7af0ed`
  - linux deliverable `l7/§3-materializer-driver` shipped at `9dca2c47`
  - macOS-authored `§3.7.1` converter and `§2b.3` recipe-publish workflow
    scaffolding landed through `55ff55c6`/`fad97244`
  - Windows-owned `§3.7.2` converter integrated at `b3ae21a`
  - l9 artifact URL template + `Manifest::artifact_url` resolver landed at
    `963baeb1`
  - Windows-owned `RemoteArtifact` resolver for the l9 URL contract landed at
    `83e2cd51` and was integrated/tested at `150d8a14`
  - recipe artifacts and manifest SHA pins landed; Windows proved the
    `x86_64.tar` fetch/SHA/import path against a real WSL2 distro
  - headless release asset publish fixed the first-boot fetch 404; Windows
    confirmed HTTP 200 and listener binding
- depends_on: []
- owned_files:
  - `crates/tillandsias-vm-layer/src/wsl.rs`
  - `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`
  - `crates/tillandsias-windows-tray/assets/provisioning-manifest.json`
  - `crates/tillandsias-vm-layer/src/materialize/wsl.rs`
- summary: >
    Per D6 amendment to `vm-recipe-provisioning`, the Windows default
    install path is CI-materialized rootfs tar. Once Linux CI publishes
    the rootfs (per-arch, SHA-pinned in `images/vm/manifest.toml`),
    `WslRuntime::provision` flips from the placeholder OCI archive
    fetch to the recipe-materialized rootfs tar. The converter primitive and
    URL resolver are done; the remaining Windows work is the runtime
    fetch/provisioning flip from the legacy OCI provisioning manifest to the
    recipe-published tar with SHA verification and a recoverable
    `"pending-ci"` state before the first artifact run. This is now
    implemented and proven; Ready state depends on F2 HvSocket transport and
    smoke of the `f5801968` unit fix, not on additional w5 artifact work.
- estimated_effort: done.
- progress:
  - Windows-owned converter slice `materialize::wsl::tar_to_wsl_import`
    landed on `origin/windows-next` at `cb39cb7c` and was integrated/tested
    into `linux-next` at `b3ae21a`.
  - Linux l8 real `BuildahExec` + `materialize-cli` landed at `6aeae3a7`.
  - Windows-owned `RemoteArtifact` resolver for the l9 URL contract landed on
    `origin/windows-next` at `83e2cd51` and was integrated/tested into
    `linux-next` at `150d8a14`.
  - Runtime provisioning flip landed on `origin/windows-next` at `56760531`,
    with follow-up `wsl.conf` systemd/default-root fixes and idempotent
    skip-if-registered behavior.
  - Deep E2E proved rootfs fetch/SHA/import, systemd boot, headless fetch HTTP
    200, and listener bind. Remaining Ready work is tracked as F2 plus smoke
    of the `f5801968` unit fix.

### Item: w6/vm-status-and-enumerate-real-handlers

- id: `w6/vm-status-and-enumerate-real-handlers`
- type: feature
- owner_host: windows  (in-VM headless, but Windows-tray sees the effect)
- capability_tags: [host-shell, vsock-client]
- status: done
- completed_at: 2026-05-26T01:43Z
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
- progress:
  - No-VM diagnostics fallback landed at `948af711` and was merged/tested into
    `linux-next` at `b3ae21a`.
  - Live VM surface verification should be recorded under w9 now that the
    recipe artifact, F1 unit, F2 transport, and Ready gates are closed.

## Linux deliverables Windows is waiting on (status mirrors)

| Linux item | Status | Blocks Windows item |
|---|---|---|
| `l1/control-wire-pty-attach-tasks-1` | **done** (shipped `b345ae68`; 23/23 control-wire tests pass on Linux; 22/22 on Windows per `47d91d11`) | w4 done |
| `l2/recipe-shared-modules` | **done** (windows authored §2 parser `26afb76a` integrated `a7af0ed`; 16/16 recipe tests green on Linux) | w5 done |
| `l3/in-vm-headless-pty-handler` | **done** (`f770e013`/`8dc0d129`; tasks 4.1-4.7, two pump tests ignored pending AsyncFd rewrite) | w4 done |
| `l4/replace-vsock-stub-handlers` | **done** (`6956c825`; real VmStatus/EnumerateLocalProjects/CloudRefresh backing data) | w6 diagnostics done; live interaction continues in w9 |
| `l5/recipe-smoke-ci-publish` | **done for Windows path**; artifacts and SHA pins are published/proven | w5 done |
| `l6/linux-rasterize-svg-to-ico` | **done** (`ea13ba20`) | w1 done |
| `l7/§3-materializer-driver` | **done** (`9dca2c47`; materializer feature and cache/export API shipped) | w5 done |
| `l8/buildah-exec-recipe-publish-smoke` | **done** (`6aeae3a7`; real BuildahExec + `materialize-cli`; 43/43 vm-layer materialize tests, full CI/install pass in ledger) | w5 done |
| `l9/recipe-artifact-url-and-publish-smoke` | **done for Windows w5**; artifact URL contract, recipe artifacts, manifest SHA pins, fixed F1 rootfs, and headless release asset fetch are all proven. Remaining follow-up is manifest `release_tag`, not l9 artifact publication. | w5 and w8 done |

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

### Event: 2026-05-26T02:04Z — linux coordinator status reconciliation

- Observed remote heads: `linux-next` `fad97244`, `windows-next` `d937e761`,
  `osx-next` `fad97244`, `main` `ddf52dff`.
- Folded terminal events into headers: w5 converter and w6 diagnostics are now
  integrated/tested through `b3ae21a`; the old `cb39cb7c needs merge/test`
  watch is resolved.
- New Windows watch: `origin/windows-next` has diagnostic refinement
  `d937e761`, but that branch is based before the latest `linux-next`
  recipe-publish commits. Merge latest `linux-next` into `windows-next`, or
  let the integration loop merge/test `d937e761` and record exact conflicts.
- Current blocker for w5 is not the converter anymore. It is the production
  artifact path: `BuildahExec` still returns its scaffold error, manifest SHAs
  are `pending-ci`, and `wsl_lifecycle.rs` still consumes the legacy
  provisioning manifest. Windows should use w7 diagnostics/branch-sync while
  Linux l8 produces first real rootfs artifacts.

### Event: 2026-05-26T02:59Z — linux coordinator status reconciliation

- Observed remote heads: `linux-next` `f2546427`, `windows-next` `042bf22a`,
  `osx-next` `fad97244`, `main` `ddf52dff`.
- Folded terminal events into headers: Linux l8 real `BuildahExec` +
  `materialize-cli` shipped at `6aeae3a7`; the stale "BuildahExec scaffold"
  blocker is resolved.
- Windows branch sync progressed: `origin/windows-next` merged latest
  `linux-next` at `042bf22a`, so the old "d937e761 is behind latest
  linux-next" warning is resolved. The integration loop still needs to
  merge/test `042bf22a` into `linux-next` or record exact conflicts.
- Current blocker for w5 is l9: settle the artifact URL/release-asset contract,
  get first green recipe-publish artifacts, and write manifest SHA pins before
  flipping `wsl_lifecycle.rs` from the legacy provisioning manifest.

### Event: 2026-05-26T04:11Z — linux coordinator status reconciliation

- Observed remote heads: `linux-next` `18405840`, `windows-next` `042bf22a`,
  `osx-next` `18405840`, `main` `ddf52dff`.
- The `042bf22a` integration watch is resolved: Linux integrated and tested
  that Windows diagnostics refinement at `881306a`.
- `origin/windows-next` now has no unmerged Windows delta, but it is 7 commits
  behind latest `linux-next`. Windows should branch-sync before stacking new
  code, then run w7 diagnostics against the l9 artifact gate.
- w5 remains blocked on l9: artifact URL/release-asset contract, first green
  recipe-publish artifacts, and manifest SHA pins.

### Event: 2026-05-26T06:02Z — linux coordinator status reconciliation

- Observed remote heads: `linux-next` `fcebc98d`, `windows-next` `042bf22a`,
  `osx-next` `0aff8003`, `main` `ddf52dff`.
- No unmerged Windows code delta exists, but `windows-next` now trails latest
  `linux-next` by 17 commits after macOS m4 slices 3-5 and two coordination
  commits landed.
- Keep w7 as the ready Windows fallback: merge or pull latest `linux-next`,
  run `scripts/diagnose-windows.ps1`, and append an agent_status_packet showing
  whether diagnostics still identify l9 as the artifact gate.
- Windows volunteered in `plan/issues/tray-convergence-coordination.md` to
  land the pure host-shell `launch_spec` forge-target amendment. Treat that as
  available Windows-owned follow-up unless l-headless or m4 objects in the next
  cycle.
- w5 remains blocked on l9: artifact URL/release-asset contract, first green
  recipe-publish artifacts, and manifest SHA pins.

### Event: 2026-05-26T07:54Z — linux coordinator status reconciliation

- Observed remote heads: `linux-next` `89de6219`, `windows-next` `35cbdb16`,
  `osx-next` `89de6219`, `main` `ddf52dff`.
- The Windows forge-container `launch_spec` / `intent_for_action` amendment is
  resolved and integrated: `35cbdb16` merged/tested into `linux-next` at
  `a1e1df1`, with `host-shell` tests 38/38 in the integration ledger.
- No unmerged Windows code delta exists. `windows-next` trails current
  `linux-next` by 10 commits, mostly macOS m4 adapter/fallback work plus
  coordination ledger updates.
- Keep w7 as the ready Windows packet: branch-sync to `89de6219`, run
  `scripts/diagnose-windows.ps1`, and report whether diagnostics still
  identify l9 as the only artifact gate. Do not reopen the launch_spec work
  unless the branch-sync exposes a regression.
- w5 remains blocked on l9: artifact URL/release-asset contract, first green
  recipe-publish artifacts, and manifest SHA pins.

### Event: 2026-05-26T09:47Z — linux coordinator status reconciliation

- Observed remote heads: `linux-next` `e60afe93`, `windows-next` `83e2cd51`,
  `osx-next` `dddd3eb8`, `main` `ddf52dff`.
- The w5 artifact URL consumer slice is resolved: Windows commit `83e2cd51`
  added the `RemoteArtifact` resolver for the l9 URL contract and the
  integration loop merged/tested it at `150d8a14`.
- No unmerged Windows code delta exists. `windows-next` trails current
  `linux-next` by 9 commits, including macOS m4 live attach completion and
  Linux coordination commits.
- Keep w7 as the ready Windows packet: branch-sync to `e60afe93`, run
  `scripts/diagnose-windows.ps1`, and report whether diagnostics identify the
  remaining gate as first green recipe-publish artifacts plus manifest SHA
  pins. The URL contract itself should no longer be reported as missing.
- w5 remains blocked on real recipe-publish artifacts and SHA pins. Consumers
  should treat `"pending-ci"` SHA values as a recoverable not-yet-published
  state, not as a crash or permanent failure.

### Event: 2026-05-26T11:47Z — linux coordinator status reconciliation

- Observed remote heads after rebase: `linux-next` `1d8217d3`,
  `windows-next` `a675e814`, `osx-next` `bdb7f9cb`, `main` `ddf52dff`.
- No unmerged Windows code delta exists. `windows-next` trails current
  `linux-next` by 11 commits, including Step 15 router-before-project code,
  the tray-network-bootstrap litmus, macOS m5 integration, and coordination
  ledger updates.
- Keep w7 as the ready Windows packet: branch-sync to `1d8217d3`, run
  `scripts/diagnose-windows.ps1`, and report whether diagnostics identify the
  current gate as recipe-publish workflow registration plus manifest SHA pins.
- New l9 detail for Windows diagnostics: GitHub Actions does not register
  `.github/workflows/recipe-publish.yml` while it is absent from default branch
  `main`; `gh run list --workflow recipe-publish.yml` returns 404. Do not
  report this as a missing URL contract; that contract is complete.
- w5 remains blocked on real recipe-publish artifacts and SHA pins. Consumers
  should continue treating `"pending-ci"` SHA values as a recoverable
  not-yet-published state.

### Event: 2026-05-26T13:39Z — linux coordinator status reconciliation

- Observed remote heads after fast-forward: `linux-next` `72aa7917`,
  `windows-next` `7e95c7e2`, `osx-next` `bdb7f9cb`, `main` `ddf52dff`.
- No unmerged Windows code delta exists. `windows-next` already contains Step
  16 slice 1 and trails current `linux-next` only by the pty_handler AsyncFd
  rewrite (`65980b02`) and its plan checkpoint (`72aa7917`).
- Keep w7 ready: branch-sync to `72aa7917`, run
  `scripts/diagnose-windows.ps1`, and report whether diagnostics still name
  recipe-publish workflow registration plus manifest SHA pins as the current
  artifact gate.

### Event: 2026-05-26T15:29Z — linux coordinator status reconciliation

- Observed remote heads after fast-forward: `linux-next` `aa8fc2b9`,
  `windows-next` `7e95c7e2`, `osx-next` `bdb7f9cb`, `main` `ddf52dff`.
- No unmerged Windows code delta exists. `windows-next` trails current
  `linux-next` by 6 commits: the pty_handler AsyncFd and pump-cancel code
  slices plus coordination checkpoints.
- Keep w7 ready: branch-sync to `aa8fc2b9`, run
  `scripts/diagnose-windows.ps1`, and report whether diagnostics still name
  recipe-publish workflow registration plus manifest SHA pins as the current
  artifact gate. The l9 URL contract remains done; do not re-open it.

### Event: 2026-05-26T17:21Z — linux coordinator status reconciliation

- Observed remote heads after fast-forward: `linux-next` `a18bcbf3`,
  `windows-next` `7e95c7e2`, `osx-next` `a3152fc5`, `main` `03c3c50c`.
- No unmerged Windows code delta exists. `windows-next` is an ancestor of
  `linux-next` and trails by 17 commits. The extra distance is expected remote
  progress, not a Windows blocker.
- l9 state changed: PR #2 registered `recipe-publish` on `main`, but real
  main-branch runs `26463370993` and `26463472551` failed before artifacts or
  SHAs. The live failure is rootless Buildah overlay mount exit 125; the fix is
  on `linux-next` `a18bcbf3` and PR #3
  (`ci-recipe-publish-rootless-fix-2026-05-26`) targeting `main`.
- Keep w7 ready: branch-sync to `a18bcbf3`, run
  `scripts/diagnose-windows.ps1`, and report that the current artifact gate is
  PR #3 plus a green recipe-publish run and manifest SHA pins.

### Event: 2026-05-27T05:05Z — linux coordinator status reconciliation

- Observed remote heads after fetch/rebase: `linux-next` `f5801968`,
  `windows-next` `d15e0fb3`, `osx-next` `fa5a5c4c`, `main` `f9c465b3`.
- Folded terminal events from `plan/issues/tray-convergence-coordination.md`:
  PR #3, recipe-publish artifacts, manifest SHA pins, headless release assets,
  and Windows w5 rootfs/headless-fetch proof are resolved.
- `origin/windows-next` has active unmerged code delta into `linux-next`:
  materialize Windows portability, recipe provisioning runtime refinements, and
  F2 HvSocket work through `d15e0fb3`. The integration loop should merge/test
  these or record exact conflicts; do not treat normal linux-next remote
  progress as a blocker.
- Current Windows dependency chain: w5 is done; F1 headless service stability
  has code fix `f5801968` and needs smoke; F2 HvSocket is Windows-owned and in
  progress; w7 is a fallback diagnostics packet only.

### Event: 2026-05-27T06:57Z — linux coordinator status reconciliation

- Observed remote heads after fetch/pull: `linux-next` `a5f915e4`,
  `windows-next` `e0405f2f`, `osx-next` `deba10d8`, `main` `f9c465b3`.
- Folded terminal events from `origin/windows-next`: `8a96a880` proved
  AF_HYPERV connect, `2b97be30` proved Hello/HelloAck, `340cac99` wired that
  handshake into `provision_via_recipe`, and `e0405f2f` flips tray status to
  Ready on success.
- Header reconciliation: w8 is now done on Windows. The integration loop still
  needs to merge/test the Windows code into `linux-next`; preserve the newer
  `13cf3af0` manifest repin if the branch merge exposes Windows' older
  manifest block.
- New ready packet: w9 `control-wire-session-menu-routing` should retain or
  reacquire the live stream and route menu actions over the proven transport.

### Event: 2026-05-27T08:50Z — linux coordinator status reconciliation

- Observed remote heads after fetch/pull: `linux-next` `46ef33b1`,
  `windows-next` `5188dce6`, `osx-next` `deba10d8`, `main` `f9c465b3`.
- Folded new `origin/windows-next` terminal evidence: `8b785ced` proves
  VmStatus request/reply over HvSocket, `791c0187` makes provisioning wait for
  VM phase `Ready`, and `5188dce6` proves PtyOpen/PtyData/PtyClose over the
  HvSocket transport for the Open Shell mechanism.
- Header reconciliation: w9 is now `in_progress`, not done. The transport
  primitives are proven, but the menu UX still needs to hold/reacquire the
  session, bridge `launch_spec`/PtyOpen to ConPTY or `wt.exe`, and route
  GitHub Login plus agent attach over the same path.
- Integration-loop gate moved forward from `e0405f2f` to `5188dce6`. During
  merge/test, preserve the newer `13cf3af0` manifest repin and newer
  `linux-next` plan entries if the Windows branch presents older blocks.

### Event: 2026-05-27T10:43Z — linux coordinator status reconciliation

- Observed remote heads after fetch/pull: `linux-next` `732603b1`,
  `windows-next` `c997fc43`, `osx-next` `deba10d8`, `main` `f9c465b3`.
- Folded new `origin/windows-next` w9 evidence after `5188dce6`:
  `fc7d0b74` proves bidirectional PTY stdin/stdout, `531bcce4` holds the WSL
  utility VM warm while the tray runs, `bc23a529` drains that keepalive on
  Quit, and `c997fc43` launches the resolved `launch_spec` argv in Windows
  Terminal / `wsl.exe`.
- Header reconciliation: w9 remains `in_progress`, but the stale "bridge
  `launch_spec`/PtyOpen to ConPTY or `wt.exe`" wording is superseded by the
  native-terminal path. Remaining evidence is integration-loop merge/test plus
  focused terminal-click smoke/status for Open Shell, Attach, Maintain, and
  GitHub Login.
- Integration-loop gate moved forward from `5188dce6` to `c997fc43`. During
  merge/test, preserve the newer `13cf3af0` manifest repin and newer
  `linux-next` plan entries if the Windows branch presents older blocks.

### Event: 2026-05-27T12:35Z — linux coordinator status reconciliation

- Observed remote heads after fetch/pull: `linux-next` `3370f04e`,
  `windows-next` `29fe3807`, `osx-next` `deba10d8`, `main` `f9c465b3`.
- Folded new `origin/windows-next` w9 evidence after `c997fc43`:
  `8e84df7d` proves Open Shell terminal-click smoke on real Windows hardware,
  `0626a318` adds file-based tray logging plus working Open Log, `41c32174`
  syncs the tracing lockfile entries, and `29fe3807` refreshes the thin-tray
  next-action cache.
- Header reconciliation: w9 remains `in_progress`, but bare Open Shell
  terminal-click smoke is resolved. Remaining evidence is integration-loop
  merge/test, forge-container Open Shell E2E against a live provisioned VM,
  Retry wiring, and optional wire EnumerateLocalProjects.
- Integration-loop gate moved forward from `c997fc43` to `29fe3807`. During
  merge/test, preserve the newer `13cf3af0` manifest repin and newer
  `linux-next` plan entries if the Windows branch presents older blocks.

### Event: 2026-05-27T14:29Z — linux coordinator status reconciliation

- Observed remote heads after fetch/pull: `linux-next` `91061b61`,
  `windows-next` `c0a9558b`, `osx-next` `deba10d8`, `main` `f9c465b3`.
- Folded new `origin/windows-next` w9 evidence after `29fe3807`:
  `f4c3d70f` wires Retry to re-trigger guarded provisioning after a failed
  attempt, and `c0a9558b` proves the forge-container Open Shell argv through
  `wsl.exe` into a running `tillandsias-<name>-forge` container.
- Header reconciliation: w9 remains `in_progress`, but Retry and both Open
  Shell legs are no longer blockers. Remaining evidence is integration-loop
  merge/test, optional full live-provision dress rehearsal, and optional wire
  EnumerateLocalProjects.
- Integration-loop gate moved forward from `29fe3807` to `c0a9558b`. During
  merge/test, preserve the newer `13cf3af0` manifest repin and newer
  `linux-next` plan entries if the Windows branch presents older blocks.

### Event: 2026-05-27T16:24Z — linux coordinator status reconciliation

- Observed remote heads after fetch/pull: `linux-next` `011d7b49`,
  `windows-next` `c0a9558b`, `osx-next` `deba10d8`, `main` `f9c465b3`.
- No new Windows commits landed after `c0a9558b`; the branch delta against
  `linux-next` remains the w9 transport/menu/Open Shell/Retry code plus
  related documentation and lockfile updates.
- Header reconciliation unchanged: w9 remains `in_progress` until the
  integration loop merge/tests `origin/windows-next` through `c0a9558b`.
  w7 remains the no-code fallback if that merge/test exposes stale branch,
  diagnostics, or manifest state.

### Event: 2026-05-27T18:15Z — linux coordinator status reconciliation

- Observed remote heads after fetch/pull: `linux-next` `9081212c`,
  `windows-next` `c0a9558b`, `osx-next` `deba10d8`, `main` `e22a6853`.
- No new Windows commits landed after `c0a9558b`; the branch delta against
  `linux-next` remains the w9 transport/menu/Open Shell/Retry code plus
  related documentation and lockfile updates.
- Header reconciliation unchanged: w9 remains `in_progress` until the
  integration loop merge/tests `origin/windows-next` through `c0a9558b`.
  w7 remains the no-code fallback if that merge/test exposes stale branch,
  diagnostics, or manifest state.
- Release-side note: PR #5 merged to `main`, so the durable release workflow
  now auto-publishes the in-VM headless agents. This closes the prior
  release.yml cleanup ask but does not change the Windows w9 merge/test gate.

### Event: 2026-05-27T19:19Z — runtime-litmus clean merge, rustfmt blocker

- Observed remote heads after fetch/pull: `linux-next` `f3838069`,
  `windows-next` `1aebb284`, `osx-next` `deba10d8`, `main` `e22a6853`.
- Runtime-litmus `20260527T190639Z-2c239138-1aebb284-deba10d8` clean-merged
  `origin/windows-next` and found `origin/osx-next` already integrated, then
  failed `./build.sh --ci-full --install` at the `rust-formatting` check.
- Windows-owned blocker: rustfmt wants to reflow the
  `tracing::info!(wire_version, attempt, "VM operationally Ready...")` call in
  `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`.
- Next Windows packet: run `cargo fmt --all` or a scoped rustfmt that covers
  `wsl_lifecycle.rs`, push the formatting checkpoint to `windows-next`, and
  append an agent_status_packet here. Do not reopen transport, Retry, or Open
  Shell behavior; this is a formatting-only gate before the integration loop
  can rerun the full installed runtime litmus.

### Event: 2026-05-27T19:23Z — pull-awareness for forge diagnostics lane

- Coordination commit pending on `linux-next` updates
  `methodology/litmus.yaml`, `methodology/forge-diagnostics.yaml`,
  `.codex/skills/coordinate-multihost-work/SKILL.md`,
  `plan/issues/forge-diagnostics-automation-2026-05-27.md`, and
  `plan/index.yaml`.
- This is informational for Windows w9; it does not supersede the current
  primary action to clear the `wsl_lifecycle.rs` rustfmt diff.
- If Windows observes forge diagnostics output during live-provision dress
  rehearsal, record it as non-blocking evidence. Do not accept requests for
  broader host mounts, host credentials, privileged containers, raw host
  sockets, or proxy/router/enclave bypasses.
- Required acknowledgement in the next Windows `agent_status_packet`: confirm
  the `linux-next` coordination commit was pulled or list the fetch/rebase
  blocker, then report whether any forge diagnostic evidence was produced.

### Event: 2026-05-27T21:16Z — runtime-litmus for `cca9da4a` failed at Windows rustfmt

- Observed remote heads after fetch/pull: `linux-next` `b463cb53`,
  `windows-next` `cca9da4a`, `osx-next` `b463cb53`, `main` `fa746f03`.
- Windows advanced after the prior rustfmt gate: `9c7b30ce` adds
  `--provision-once` headless mode and live dress rehearsal evidence;
  `cca9da4a` marks the full live-provision dress rehearsal done.
- macOS/vm-layer rustfmt is no longer the blocker. `linux-next` includes the
  formatting cleanup (`4935404a`) and the follow-up ACK (`feb51d66`).
- Runtime-litmus `20260527T211507Z-b463cb53-cca9da4a-b463cb53` clean-merged
  `origin/windows-next`, found `origin/osx-next` already integrated, passed
  pre-build litmus 57/57, and wrote centicolon evidence, then failed
  `./build.sh --ci-full --install` at rustfmt.
- Exact Windows-owned blocker from `/tmp/fmt-check.log`:
  `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs` needs the
  `tracing::info!(wire_version, attempt, "VM operationally Ready...")` call
  reflowed by `cargo fmt`.
- Required next Windows status packet: pull this coordination update, wait for
  the runtime result before reopening behavior work, clear only the formatting
  diff first, and only continue optional wire EnumerateLocalProjects after the
  integration gate is green.

### Event: 2026-05-27T23:25Z — rustfmt resolved, Windows integrated, runtime retry running

- Observed remote heads after fetch/rebase: `origin/linux-next` `891bb757`
  before this coordination commit, `windows-next` `1e20d6d0`, `osx-next`
  `f8778350`, `main` `fa746f03`.
- Windows fixed the rustfmt blocker at `9315e9de`; `1e20d6d0` added
  `--status-once` control-wire health diagnostics.
- Integration cycle `edfb72c6` clean-merged `origin/windows-next` into
  `linux-next` at merge commit `b9cee2fd`; `./build.sh --check` and
  `./build.sh --test` both passed on the merged tree.
- Runtime-litmus `20260527T231258Z-b06a5997-1e20d6d0-b06a5997` found
  `merged_siblings=none` because both sibling branches are already ancestors
  of `linux-next`, then failed at `Disk quota exceeded` during
  `./build.sh --ci-full --install`. Old scratch worktrees were removed.
- Replacement full installed runtime-litmus
  `20260527T231940Z-b06a5997-1e20d6d0-b06a5997` passed build/install and init,
  then failed in OpenCode diagnostics with the `vault_bootstrap.rs:205`
  nested-runtime panic.
- Required next Windows status packet: pull this coordination commit, keep wire
  `EnumerateLocalProjects` optional, and do not reopen Windows w9 unless a
  fresh current-head runtime produces Windows-specific evidence.
