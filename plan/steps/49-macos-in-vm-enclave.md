# Step 49 — macOS in-VM enclave provisioning (the keystone the macOS tray is missing)

- **Status**: open (ready to claim)
- **Owner host**: macos (primary) + linux/recipe (coordination — enclave recipe is Linux-owned)
- **Branch**: osx-next (macOS wiring) / linux-next (recipe contract)
- **Depends on**: []
- **Blocks**: `macos-tray/github-login-pty-hangs-gray`, `macos-tray/empty-project-lists-and-poll-error-masking`, macOS m8 release-acceptance gate
- **Specs**: vm-provisioning-lifecycle, vm-idiomatic-layer, macos-native-tray, forge-as-only-runtime
- **Audit origin**: `plan/issues/macos-m8-interactive-smoke-failures-2026-06-16.md` (finding F2, CRITICAL)

## Why this exists (the finding and its consequence)

The first **user-attended (m8) smoke** of the macOS `Tillandsias.app` (2026-06-16)
FAILED. The status chip showed **"VM Failed"** even though the guest OS booted
cleanly. Root cause, diagnosed from `crates/tillandsias-vm-layer/src/vz.rs`:

> The macOS cloud-init user-data provisions ONLY `tillandsias-headless-fetch.service`
> + `tillandsias-headless.service`. It has **zero podman / forge / enclave / dnf
> setup** (`grep -cE 'podman|dnf|enclave|forge' vz.rs` = 0). The headless agent
> boots and answers vsock, but finds no podman and no forge enclave inside the
> guest → `podman_ready=false` → reports `Failed`.

**Consequence — the macOS tray is non-functional at the interaction layer.**
Everything a user clicks needs the in-VM enclave that was never provisioned:
- local/cloud project lists are empty (F5),
- GitHub-Login opens a terminal that hangs gray (F4 — no forge container to attach to),
- agents / Attach Here / Open Shell all have nothing to attach to.

On Linux, podman runs on the host. On macOS (and Windows), the enclave MUST run
INSIDE the guest VM. That path was specced but never wired into the macOS
first-boot. `images/vm/bootstrap/30-enclave.sh` (the recipe enclave step) exists
but is NOT invoked by the macOS cloud-init.

## Empirical evidence (2026-06-16, after the phase-logging diagnosability fix b93b58e1)

A clean provision + tray launch produces this phase progression (now visible in
the captured serial/tray log; it was silent before):

```
~24s  vm-status: phase=Starting  podman_ready=false  event=tillandsias-in-vm
~84s  vm-status: phase=Failed     podman_ready=false  event=tillandsias-in-vm
```

Interpretation: the in-VM headless DOES attempt enclave startup (phase
`Starting`), waits ~60s, then **times out to `Failed`**. `podman_ready` is never
true → there is no working podman/forge in the guest. `last_event` carries only
an identifier (`tillandsias-in-vm`), not a reason — so even the field that COULD
explain the failure is unpopulated (see `macos-tray/vm-failed-reason-not-surfaced`).
This confirms the root cause: the headless expects a podman/forge enclave that
the macOS cloud-init never provisions, and a ~60s startup wait fails.

## Goal

Make a freshly-provisioned macOS VM bring up the full forge enclave inside the
guest so the headless reports `podman_ready=true` / phase `Ready`, and the tray's
projects / agents / attach / github-login features work — i.e. the m8
user-attended smoke passes.

## Where to look

- `crates/tillandsias-vm-layer/src/vz.rs` (~lines 360-437) — the macOS cloud-init
  `user-data` heredoc; this is where the enclave setup must be added/invoked.
- `images/vm/bootstrap/30-enclave.sh` + `images/vm/Recipefile` + `images/vm/manifest.toml`
  — the Linux-owned enclave recipe to reuse rather than re-implement.
- `crates/tillandsias-headless/` — the in-VM agent: does it self-bootstrap podman,
  or assume podman is present? This decides the strategy below.
- Container security invariants (`--cap-drop=ALL`, `--security-opt=no-new-privileges`,
  `--userns=keep-id`, `--rm`) must hold for the in-VM forge too.

## Design Decision (49a) — Cloud-init installs podman + enclave setup

**Chosen: Option 1 — Cloud-init installs + builds the enclave.**

Rationale:
- Simplest change — extends the existing cloud-init user-data heredoc in `vz.rs`
  without restructuring the provisioning pipeline.
- Reuses the existing `30-enclave.sh` recipe logic (podman.socket enablement).
- Does NOT require switching the rootfs from Fedora Cloud to the recipe-built
  rootfs (which would need aarch64 recipe-artifact availability + plumbing).
- The one-time ~30s `dnf install` cost on first boot is acceptable — provisioning
  already downloads a ~600 MB rootfs image.

Implementation plan:
1. Add `dnf install -y podman` to the cloud-init user-data.
2. Enable `podman.socket` so the headless can drive containers via the REST API.
3. Pull/prime the enclave base images (proxy, git, forge, inference) in the
   background so first user-action has zero pull latency.
4. Keep all existing security flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`,
   `--userns=keep-id`, `--rm`).

This does NOT modify the Recipefile or the rootfs provisioning pipeline. The
recipe-built rootfs (Option 3) remains a future optimization once aarch64
artifacts are published.

## Tasks (implement in order)

- [x] 49a — **Decision**: Option 1 (cloud-init). Recorded above.
- [x] 49b — Wire podman install + podman.socket into the macOS cloud-init (`vz.rs` user-data).
      Landed at `b7321f50` on osx-next. E2E gate PASS at `f39203b5`.
- [x] 49c — Headless reports `podman_ready=true` / phase `Ready` once the
      enclave is up; verified over vsock from the host (vm-status poll).
      Confirmed at ~32s post-boot (2026-06-16T23:28Z).
- [ ] 49d — Re-run the macOS m8 user-attended smoke; projects list, github-login
      terminal yields a working shell, Attach Here opens a forge shell.
- [x] 49e — Add an automated post-provision assertion (host-side) that the VM
      reaches `Ready` within a bound, so this can't silently regress to "Failed"
      Implemented in `scripts/diagnose-macos-enclave.sh`. Validated: phase=Ready
      at ~31s on the provisioned VM.
- [ ] 49d — Re-run the macOS m8 user-attended smoke; projects list, github-login
      terminal yields a working shell, Attach Here opens a forge shell.
- m8 7-step user-attended smoke passes (projects populate; github-login + attach
  open working forge shells).
- Container security invariants verified on the in-VM forge.
- An automated gate fails loudly if the VM stays `Failed`.

## Cross-host coordination

The enclave recipe (`images/vm/`) is Linux/recipe-owned; the in-VM enclave must
match the Linux host enclave (same images, network, vault contract). File the
recipe-side asks on `linux-next` and the macOS wiring on `osx-next`; do not fork
a second enclave definition (tombstone/supersede, never duplicate).

## Events

- type: claim
  ts: "2026-06-16T23:16:19Z"
  agent_id: "macos-tlatoani-big-pickle-20260616T231619Z"
  host: "macos"
  lease_id: "step49-macos-vm-enclave-20260616T231619Z"
  expires_at: "2026-06-17T03:16:19Z"
- type: completed
  task: "49b"
  ts: "2026-06-16T23:17:00Z"
  agent_id: "macos-tlatoani-big-pickle-20260616T231619Z"
  host: "macos"
  commits: ["b7321f50"]
  evidence:
    - "cargo test -p tillandsias-vm-layer: 15/15 PASS"
    - "cargo check: clean"
    - "E2E gate (build-install-smoke-e2e): build+install+provision+diagnose PASS at f39203b5"
- type: completed
  task: "49c"
  ts: "2026-06-16T23:28:00Z"
  agent_id: "macos-tlatoani-big-pickle-20260616T231619Z"
  host: "macos"
  evidence:
    - "Headless reached phase=Ready podman_ready=true ~32s post-boot (was ~84s Failed before 49b)"
- type: completed
  task: "49e"
  ts: "2026-06-16T23:30:00Z"
  agent_id: "macos-tlatoani-big-pickle-20260616T231619Z"
  host: "macos"
  files: ["scripts/diagnose-macos-enclave.sh"]
  evidence:
    - "Script validate: phase=Ready at ~31s on provisioned VM"
    - "Exits 0 on Ready, 2 on Failed/timeout"
    - "120s timeout with polling"
- type: claim
  task: "49d"
  ts: "2026-06-18T23:18:15Z"
  agent_id: "macos-Tlatoanis-MacBook-Air-vz-20260618T231815Z"
  host: "macos"
  lease_id: "step49d-m8-smoke-20260618T231815Z"
  expires_at: "2026-06-19T03:18:15Z"
  note: >
    Operator-attended m8 interactive smoke claimed for live execution. Rebuild +
    install at HEAD (freshness gate: installed --version SHA must equal
    git rev-parse --short HEAD), then drive the 7-step menu checklist while the
    host captures the vsock/enclave side via scripts/diagnose-macos-enclave.sh.
- type: progress
  task: "49d"
  ts: "2026-06-18T21:30:00Z"
  agent_id: "macos-Tlatoanis-MacBook-Air-big-pickle-20260618T213000Z"
  host: "macos"
  lease_id: "step49d-m8-smoke-20260618T231815Z"
  outcome: >
    User-attended m8 interactive smoke at HEAD e4ef0db0.
    Icon PASS (F1), VM Ready PASS (F2 closed), Menu collapsed FAIL (F3 open),
    GitHub Login FAIL (F4 has independent root cause beyond step 49), Quit PASS.
    F4 is NOT resolved by step 49 alone — it needs independent investigation.
  evidence:
    - Icon renders correctly as crisp tinted glyph (1ada1f28 working)
    - Status chip shows Ready tillandsias-in-vm ~32s post-boot
    - Menu shows old always-expanded UX instead of collapsed github-gated form
    - GitHub Login terminal opens and goes full gray immediately
    - Quit exits cleanly
  next_action: >
    F3: implement shared host-shell collapsed menu (cross-host coordination).
    F4: investigate why PTY attach fails even with VM Ready — does the forge
    container actually start? Check in-VM state via vsock after Ready reported.
  results_file: plan/issues/macos-m8-interactive-smoke-results-2026-06-18.md
- type: progress
  task: "49d"
  ts: "2026-06-18T23:30:00Z"
  agent_id: "macos-Tlatoanis-MacBook-Air-vz-20260618T231815Z"
  host: "macos"
  lease_id: "step49d-m8-smoke-20260618T231815Z"
  outcome: >
    Re-provisioned VM with the v0.3.260618.2 headless and landed the F3 fix
    (8f3d87c1), then re-ran the m8 smoke. F3 collapsed login-gated menu:
    FIXED + operator-confirmed. F4 github-login: still gray — root-caused to
    bare-VM `gh auth login` (gh is not on the bare VM; only podman is). The
    orchestrated `--github-login` flow is correct but its
    require_desktop_user_session guard rejects the in-VM headless
    service-account lane, so F4 needs a cross-host in-VM github-login-over-PTY
    entrypoint (headless/linux-owned). 49d remains OPEN on F4; F1/F2/F3/Quit pass.
  commits:
    - "8f3d87c1 fix(host-shell): login-gate the portable tray menu (F3, m8)"
  files:
    - "crates/tillandsias-host-shell/src/menu_state.rs"
    - "crates/tillandsias-macos-tray/src/menu_disabled_v2.rs"
    - "crates/tillandsias-windows-tray/tests/portable_smoke.rs"
  evidence:
    - "Freshness gate PASS: installed --version git 8f3d87c1 == HEAD"
    - "cargo test -p tillandsias-host-shell: 41 pass; -p tillandsias-macos-tray: 50 pass"
    - "Operator: src/cloud menus correctly gated + not displayed when logged out"
    - "F4 host log: PtyOpen/handshake succeed (PTY attached at /dev/ttysNNN) then no bytes"
  next_action: >
    F4 (cross-host): add in-VM interactive github-login-over-PTY entrypoint that
    runs run_github_login orchestration without the desktop-session guard and
    surfaces the device-code prompt over the PTY; then point macОS+Windows
    launch_spec(GithubLogin) at it. Coordinate on linux-next.
  results_file: plan/issues/macos-m8-interactive-smoke-results-2026-06-18.md
