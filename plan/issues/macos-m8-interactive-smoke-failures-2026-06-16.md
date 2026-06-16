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
- status: partially-done (diagnosability landed b93b58e1; project-population blocked on step 49)
- progress:
  - DONE (b93b58e1): vm-status now logs phase transitions, so a Failed/degraded
    VM is no longer silent — empirically captured `phase=Starting` → `phase=Failed`
    (~60s), `podman_ready=false`. Resolves the masking/diagnosability half.
  - BLOCKED: project lists are empty because there is no in-VM enclave to
    enumerate from — fixed only when `plan/steps/49-macos-in-vm-enclave.md` lands.
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

---

## Sequencing & consequences (what must be implemented next, in order)

```
F2 vm-reports-failed  ──►  Step 49 (in-VM enclave)  ──► unblocks ──► F4 (PTY), F5 (projects)
   [KEYSTONE]                                                         [downstream of F2]

F1 icon            ── DONE (1ada1f28)
F3 collapsed menu  ── independent of F2; shared host-shell, needs xplat coordination
provenance         ── DONE (3505a521)
diagnosability     ── parallel aid for F2 (surface the Failed reason)
```

- **Do F2 / Step 49 first.** It is the keystone: F4 and F5 cannot be properly
  fixed or verified until the in-VM enclave exists. Attempting F4/F5 before F2
  only adds "fail visibly" polish on a fundamentally non-functional surface.
- **F3 (collapsed menu)** can proceed in parallel but touches SHARED
  `host-shell/menu_state.rs` — Linux + Windows trays must move together (parity
  policy). Treat as a cross-host change, not a solo macOS edit.
- **Release-acceptance consequence:** the macOS m8 user-attended smoke is the
  step-level release gate (per plan/index.yaml). It is currently **RED**. No
  macOS release should be claimed "verified" until Step 49 lands and m8 is re-run
  green. Update the coordinator's macOS gate accordingly.

## Meta-finding: autonomous smoke gave false PASS confidence

Every `/build-install-and-smoke-test-e2e` macOS run this cycle reported PASS, but
each validated only build / install / destroy / provision / `--diagnose` — i.e.
the disk is present and the binary runs. It NEVER exercised the live vsock
control wire, menu UX, PTY attach, project enumeration, or icon rendering, all of
which are only reachable from a running tray a user clicks. The first interactive
test (m8) failed immediately.

**Consequence (process):** the macOS autonomous smoke must NOT be read as release
acceptance. Either (a) add an automated interaction probe (drive the menu model +
assert the VM reaches Ready over vsock + a scripted attach), or (b) keep the
mandatory user-attended m8 gate and stop labeling autonomous runs "PASS" without
it. Recorded as `macos-tray/smoke-does-not-cover-interaction-surface` below; the
`/build-install-and-smoke-test-e2e` SKILL.md gets a caveat note (this change).

---

## Work Packet: macos-tray/build-provenance-unverifiable  [DONE]

- id: `macos-tray/build-provenance-unverifiable`
- type: fix
- owner_host: macos
- capability_tags: [rust, macos, build, testing]
- status: done
- completed_at: 2026-06-16T22:22Z
- discovered_by: operator (running binary showed a stale-looking version; risk of
  testing an old artifact because macOS resolves names loosely)
- completion_note: >
    Added crates/tillandsias-macos-tray/build.rs embedding the git short SHA
    (+ -dirty) and build timestamp; surfaced in `--version`
    ("tillandsias-tray 0.1.0 (git <sha>, built <ts>)"). Verified: installed app
    reports git 3505a521 == HEAD, built today. Audit confirmed no stale copies in
    /Applications and nothing on PATH; the absolute-path binary tests use is the
    fresh build. Commit 3505a521.
- consequence (follow-up packet below): every smoke/interactive run should assert
    the running binary's `--version` SHA equals `git rev-parse --short HEAD`.

## Work Packet: testing/assert-binary-sha-equals-head  [MEDIUM]

- id: `testing/assert-binary-sha-equals-head`
- type: fix
- owner_host: any
- capability_tags: [testing, ci, macos, bash]
- status: done (smoke + build-macos-tray skills both gate --version SHA == HEAD; Windows mirror pending its own SHA stamp)
- next_action: >
    Add a guard to `/build-install-and-smoke-test-e2e` (and the build-macos-tray
    skill) preflight: after build+install, run the installed binary's
    `--version`, extract the git SHA, and FAIL the run if it != `git rev-parse
    --short HEAD` (or is `-dirty` when a clean build was expected). This makes
    "are we testing the latest binary?" a hard gate, not a manual check. Mirror
    on Windows tray once it embeds the same stamp.

## Work Packet: macos-tray/vm-failed-reason-not-surfaced  [MEDIUM-HIGH]

- id: `macos-tray/vm-failed-reason-not-surfaced`
- type: fix
- owner_host: macos (host render) + linux (in-VM agent populates reason)
- capability_tags: [rust, macos, control-wire, vsock, diagnosability]
- status: ready
- discovered_by: m8 user-attended smoke (2026-06-16)
- evidence:
  - `VmStatusReply` ALREADY carries `last_event: Option<String>`
    (control-wire/src/lib.rs:157) and the host ALREADY renders it via
    `compose_chip_text` — but on phase=Failed the chip showed a bare "VM Failed",
    so the in-VM agent does not populate the reason.
  - Console forwarding added in b7bde09c (StandardOutput/Error=journal+console on
    the in-VM units) did NOT surface output — likely the kernel `console=` arg is
    not `hvc0`, or the headless does not log readiness checks to stdout.
- next_action: >
    (a) In-VM headless: when reporting phase=Failed/podman_ready=false, populate
    `VmStatusReply.last_event` with the concrete reason (e.g. "podman not
    installed", "forge image missing", "enclave build failed: <err>"). (b) macOS
    host: confirm the kernel cmdline sets `console=hvc0` so journal+console
    actually reaches the serial the tray captures; otherwise drop b7bde09c's
    forwarding as ineffective. Goal: a Failed VM tells the user/agent WHY,
    on-screen and in the captured log.

## Work Packet: macos-tray/smoke-does-not-cover-interaction-surface  [MEDIUM]

- id: `macos-tray/smoke-does-not-cover-interaction-surface`
- type: process
- owner_host: any
- capability_tags: [testing, methodology, macos]
- status: partially-done (SKILL.md caveat + m8-gate doc landed; automated interaction probe still open)
- discovered_by: m8 user-attended smoke (2026-06-16)
- next_action: >
    Either add an automated interaction probe to the macOS smoke (assert the VM
    reaches Ready over vsock; drive the MenuStructure; scripted attach), or make
    the mandatory user-attended m8 gate explicit and stop reporting autonomous
    runs as release-"PASS" without it. Add a caveat to
    skills/build-install-and-smoke-test-e2e/SKILL.md (done in this change) and to
    the macОS coordinator gate in plan/loop_status.md.
