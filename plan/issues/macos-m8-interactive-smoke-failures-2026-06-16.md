# macOS m8 user-attended smoke — FAILED — findings 2026-06-16

First real user-attended (interactive) smoke of the macOS `Tillandsias.app`
(local build `0.3.260614.9`, osx-next `534e1aeb`). The user drove the menu bar;
the agent verified the VM/poller side from captured stderr. **Result: FAIL** —
multiple user-facing defects the autonomous smoke (build/provision/diagnose)
never exercised, because the live vsock control wire, menu UX, PTY-attach, and
icon rendering are only reachable from a running tray with a user clicking it.

Meta: every prior "smoke PASS" this cycle validated build/install/provision/
diagnose only. The interaction surface was untested until now. ✅ Quit was the
only interactive behavior that worked.

Correction note: two parked commits were consciously discarded during the
`osx-next/reconcile-local-ux-parity-divergence` "merge it" (commit 2979fc32) —
`51a55dfe` (icon PNG) and `78b0b3e5` (collapsed menu). The m8 smoke shows BOTH
were the intended fixes for findings F1 and F3 below; the discard was a
mistake. Recover them from git (objects still reachable by SHA) as fix input.

---

## Work Packet: macos-tray/vm-reports-failed-after-clean-boot  [CRITICAL]

- id: `macos-tray/vm-reports-failed-after-clean-boot`
- type: bug
- owner_host: macos
- capability_tags: [rust, macos, vsock, control-wire, vm-layer, vault, podman]
- status: ready
- discovered_by: m8 user-attended smoke (2026-06-16)
- evidence:
  - User: menu status chip shows **"VM Failed"**.
  - Agent stderr (`/tmp/m8-diag2.log`): guest OS boots cleanly — `Auto-boot: VM
    is running` → `Fedora Linux 44` login prompt + IP in ~7s — but NO
    `vm-status poll: <err>` lines appear, so `poll_vm_status_once` returns
    `Ok(VmPhase::Failed)` (the Ok branch sets the chip silently). The in-VM
    headless agent is reachable over vsock but self-reports Failed.
- impact: cascades to F4 (no podman/forge → empty projects) and F5 (PTY attach
  to a forge container that isn't up hangs).
- ROOT CAUSE (diagnosed 2026-06-16): the macOS cloud-init user-data in
    `vz.rs` (~line 360-437) provisions ONLY `tillandsias-headless-fetch.service`
    + `tillandsias-headless.service` — it has **zero podman / enclave / forge /
    dnf setup** (`grep -cE 'podman|dnf|enclave|forge' vz.rs` = 0). The in-VM
    headless agent therefore boots and answers vsock (vm-status connects, no
    error lines) but finds no podman and no forge enclave → `podman_ready=false`
    → reports Failed. The macOS in-VM enclave path is INCOMPLETE: unlike Linux
    (podman on the host), macOS must run podman+forge INSIDE the guest, but the
    cloud-init never installs/configures podman nor builds the enclave from the
    recipe. This is the keystone for the empty project lists (F5) and the hung
    GitHub-Login PTY (F4 — no forge container to attach to).
- diagnosis_evidence:
  - `crates/tillandsias-vm-layer/src/vz.rs` user-data: only headless services;
    `grep -cE 'podman|dnf install|enclave|forge'` = 0.
  - `/tmp/m8-headless-reason.log`: guest boots, no vm-status error lines (agent
    up), no enclave activity on console.
  - `images/vm/bootstrap/30-enclave.sh` exists (the recipe enclave step) but is
    NOT wired into the macOS cloud-init.
- next_action: >
    Decide the macOS enclave strategy and wire it into the cloud-init (vz.rs
    user-data): install podman in the guest (dnf) + materialize/start the forge
    enclave from the recipe (reuse images/vm/bootstrap/30-enclave.sh), OR have
    tillandsias-headless self-bootstrap podman+forge on first run. Cross-host:
    the enclave recipe is Linux/recipe-owned; coordinate the in-VM enclave
    contract. Separately (diagnosability, partly done in b7bde09c): make the
    headless log its podman/enclave readiness checks to a channel the host can
    see (console= kernel arg → hvc0, or extend VmStatusReply.last_event with the
    Failed reason — the field already exists and the host already renders it).

## Work Packet: macos-tray/menubar-icon-renders-as-white-blob  [HIGH]

- id: `macos-tray/menubar-icon-renders-as-white-blob`
- type: bug
- owner_host: macos
- capability_tags: [macos, appkit, assets]
- status: done (commit 1ada1f28 — user-confirmed icon renders; styling polish deferred)
- discovered_by: m8 user-attended smoke (2026-06-16)
- owned_files:
  - `crates/tillandsias-macos-tray/src/status_item.rs`
  - `crates/tillandsias-macos-tray/assets/icon.pdf`
- evidence:
  - User: the menu-bar icon is "just a white blob".
  - `status_item.rs:187-191` loads `icon.pdf` via `NSImage initWithContentsOfFile`
    + `setTemplate(true)`; stderr logs `CoreGraphics PDF has logged an error` at
    every launch → the bundled `icon.pdf` is not a valid template vector.
- next_action: >
    Recover the discarded `51a55dfe` ("align tray and app icons with linux
    assets") which replaced icon.pdf with `icon.png` (960B) + `tray-icon.png`
    (151B): `git show 51a55dfe -- crates/tillandsias-macos-tray/assets/`.
    Switch `load_status_icon_image()` / `status_icon_path()` to the PNG
    template (keep `setTemplate(true)` for menu-bar tinting) and drop the broken
    pdf. Verify the icon renders as a crisp tinted glyph on a real launch.

## Work Packet: macos-tray/menu-not-collapsed-github-gated  [HIGH]

- id: `macos-tray/menu-not-collapsed-github-gated`
- type: feature
- owner_host: macos
- capability_tags: [rust, host-shell, menu-structure, ux, parity]
- status: ready
- discovered_by: m8 user-attended smoke (2026-06-16)
- owned_files:
  - `crates/tillandsias-host-shell/src/menu_state.rs`
  - `crates/tillandsias-macos-tray/src/menu_disabled_v2.rs`
- evidence:
  - User: sees "the old messy UX" — the full always-shown item list — "instead
    of the collapsed, short, GitHubLogin-gated one we expect".
  - `menu_state.rs build()` docstring + impl still encode the legacy "exactly 9
    top-level items" contract (status/local-projects/cloud-projects/agents/
    observatorium/opencode-web/github-login/version/quit, all always shown).
  - Violates the just-merged `cross_platform_ux_parity_policy`
    (methodology/convergence.yaml): Linux golden UX = collapsed, project
    submenus OR a github-login leaf (mutually exclusive), short list.
- next_action: >
    Implement the collapsed, login-gated menu in shared `menu_state.rs build()`
    so ALL trays render it identically (per the parity policy). Use discarded
    `78b0b3e5` ("implement UX parity per step 50") as design input
    (`git show 78b0b3e5`) but re-apply on CURRENT code — do NOT cherry-pick the
    stale commit (it predates the d150a105 github-login-over-vsock poller and
    would conflict). Coordinate: menu_state.rs is shared host-shell scope —
    Linux + Windows trays must be updated/verified in the same change.

## Work Packet: macos-tray/github-login-pty-hangs-gray  [HIGH]

- id: `macos-tray/github-login-pty-hangs-gray`
- type: bug
- owner_host: macos
- capability_tags: [rust, macos, pty, vsock, control-wire]
- status: ready
- discovered_by: m8 user-attended smoke (2026-06-16)
- owned_files:
  - `crates/tillandsias-macos-tray/src/pty_vsock_bridge.rs`
  - `crates/tillandsias-macos-tray/src/terminal_attach.rs`
- evidence:
  - User: clicking GitHub Login opens a black terminal that stays gray
    (no shell); a retry "flickers" an error then goes gray, too fast to read.
- impact: likely downstream of the VM-Failed state (no forge container to attach
  to), but the UX is a dead gray window with no error surfaced.
- next_action: >
    Reproduce after the VM-Failed root cause is fixed. Regardless, the PTY
    attach must FAIL VISIBLY: when the forge/agent isn't reachable, print the
    error into the terminal and keep it open (don't flash-and-gray). Capture the
    flickered error (redirect the attach command's stderr to a persistent log).

## Work Packet: macos-tray/empty-project-lists-and-poll-error-masking  [MEDIUM-HIGH]

- id: `macos-tray/empty-project-lists-and-poll-error-masking`
- type: bug
- owner_host: macos
- capability_tags: [rust, macos, vsock, diagnosability, logging]
- status: ready
- discovered_by: m8 user-attended smoke (2026-06-16)
- owned_files:
  - `crates/tillandsias-macos-tray/src/action_host.rs`
- evidence:
  - User: nothing listed under local-projects nor cloud-projects, though
    `~/src/` has projects (tillandsias itself).
  - Downstream of VM-Failed (projects come from the in-VM forge over vsock).
  - Diagnosability regression introduced by `21f62c3a`/the cold-boot
    suppression (`vm_ever_ready` gate, action_host.rs ~1559): when the VM never
    reaches ready, the projects/github connect errors are suppressed FOREVER, so
    the host log is silent about why the menu is empty.
- next_action: >
    (a) Fix is mostly downstream of vm-reports-failed-after-clean-boot.
    (b) Refine the cold-boot suppression so it does not mask persistent
    failures: e.g. suppress only the first N warmup rounds or the first ~60s,
    then log once-per-state; or only suppress the specific "Connection reset by
    peer" pre-readiness error, not all errors. Diagnosability must survive a VM
    that never becomes ready.

## PASS

- Quit: clicking Quit exited the app immediately (no orphan; agent confirmed
  the process was gone). ✅
- Cold-boot vsock poll-error suppression: confirmed no warmup error spam in the
  interactive launch (the intended effect held) — but see the masking caveat
  in the packet above.
