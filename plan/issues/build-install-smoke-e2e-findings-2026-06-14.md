# Local build/install smoke findings — 2026-06-14

## macOS Run (Pass — OS-aware skill, first macOS lane) — 20260615T025612Z

- Discovered by: `/build-install-and-smoke-test-e2e (macos)`
- Host: macOS (Apple Silicon), branch `osx-next`
- Commit under test: `d150a105653b0a528fd3cf742fd8e0e5e9acd6aa`
- Built/installed: `tillandsias-tray 0.3.260614.9` → `~/Applications/Tillandsias.app`
- Evidence: `target/build-install-smoke-e2e/20260615T025612Z/`
- Passed gates:
  - `scripts/build-macos-tray.sh` exited 0 (13.49s); ad-hoc codesign valid +
    Designated Requirement satisfied; tarball
    `tillandsias-tray-0.3.260614.9-macos-arm64.tar.gz` (1.54 MiB) + `SHA256SUMS`.
  - Local install (atomic `.new`+`mv` into `~/Applications`) succeeded.
  - **DESTRUCTIVE destruction of the "MacosContainer"**: `rm -rf` of
    `~/Library/Application Support/tillandsias` (4.8 GiB VFR VM state) +
    `~/Library/Caches/tillandsias`. Verified gone.
  - Cold re-provision (`tillandsias-tray --provision`) exited 0: re-downloaded
    the 528 MB Fedora Cloud image → converted → materialized `rootfs.img`
    (5 GiB). `--diagnose --json` reports `provisioned: true`,
    `rootfs_present: true`, `release_tag: fedora-44`, stable schema.
- Forge lane: **n/a (linux-only)** — recorded, not run, per the OS-aware skill.
- Outcome: **PASS** end-to-end on the macOS substrate. Three findings filed
  below (none blocked the run; #1/#2 are latent CLI/path bugs surfaced by the
  smoke, #3 is a cold-boot vsock observation).
- Skill iteration: this run also fixed two path bugs **in the skill itself**
  (the §2 destroy-gate and §3 post-provision check were testing a non-existent
  `…/tillandsias/vm/rootfs.img`; the disk is at `…/tillandsias/rootfs.img`).

## Work Packet: macos-tray/version-help-flags-boot-vm

- id: `macos-tray/version-help-flags-boot-vm`
- type: fix
- title: macOS tray treats `--version`/`--help`/any unknown flag as "launch the tray + boot the VM"
- owner_host: macos
- capability_tags: [rust, macos, tray, cli, lifecycle]
- status: done
- discovered_by: `/build-install-and-smoke-test-e2e (macos)`
- owned_files:
  - `crates/tillandsias-macos-tray/src/main.rs`
- evidence:
  - `crates/tillandsias-macos-tray/src/main.rs:46,49` — `main()` only intercepts
    `--provision` and `--diagnose`; every other argv (incl. `--version`,
    `--help`) falls through to `status_item::run()`.
  - `target/build-install-smoke-e2e/20260615T025612Z/01-installed-version.txt:5,7`
    — invoking `tillandsias-tray --version` printed
    `Auto-boot: spawning worker …` then `Auto-boot: VM is running` and never
    exited (it put up the menu-bar tray and booted the VFR VM); the smoke had to
    SIGKILL it.
- repro:
  - `~/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --version`
    (boots the VM and runs the tray instead of printing a version and exiting)
- next_action: >
    Add fast-exit handling for `--version` (print the crate version, exit 0) and
    `--help` before the `status_item::run()` fallthrough — mirror the
    `--provision`/`--diagnose` argv guards. Consider a strict-unknown-flag policy
    so a typo'd flag never silently boots a VM. This also unblocks the smoke
    skill's `--version` probe (it currently can't read a version off the macOS
    binary).
- events:
  - type: discovered
    ts: "2026-06-15T02:58:00Z"
    agent_id: macos-claude-opus
    host: macos
  - type: completed
    ts: "2026-06-15T03:14:00Z"
    agent_id: macos-claude-opus
    host: macos
    note: >
      Added --version/-V and --help/-h fast-exit handlers in main.rs before the
      status_item::run() fallthrough. Verified on the release binary: all four
      flags print and exit 0 with no VM boot / no menu-bar icon; pgrep confirms
      no tray spawned. `cargo test -p tillandsias-macos-tray` = 48 passed.
      Follow-up (not done here, to avoid breaking the .app launch which receives
      OS-injected argv): a strict unknown-flag policy.

## Work Packet: macos-tray/image-root-vm-subdir-divergence

- id: `macos-tray/image-root-vm-subdir-divergence`
- type: fix
- title: `vz_lifecycle::image_root()` points at a `/vm` subdir that nothing else uses
- owner_host: macos
- capability_tags: [rust, macos, vm-layer, cleanup]
- status: ready
- discovered_by: `/build-install-and-smoke-test-e2e (macos)`
- owned_files:
  - `crates/tillandsias-macos-tray/src/vz_lifecycle.rs`
  - `crates/tillandsias-macos-tray/src/diagnose.rs`
  - `crates/tillandsias-macos-tray/src/status_item.rs`
- evidence:
  - `crates/tillandsias-macos-tray/src/vz_lifecycle.rs:38-47` — `image_root()`
    returns `~/Library/Application Support/tillandsias/vm` (with `/vm`) and is
    wired into a `VzRuntime::new(...)` at `vz_lifecycle.rs:34`.
  - `crates/tillandsias-macos-tray/src/diagnose.rs:56-60` — the `image_root()`
    used by `--provision`/`--diagnose` returns `…/tillandsias` (NO `/vm`).
  - `crates/tillandsias-macos-tray/src/status_item.rs:364` — the live auto-boot
    path (`default_image_root()`) also uses the top-level dir.
  - `target/build-install-smoke-e2e/20260615T025612Z/03-vm-layout.txt` — the
    provisioned `rootfs.img`/`rootfs.qcow2` land at the **top level** of
    `…/tillandsias`, not under `…/tillandsias/vm/`.
  - `target/build-install-smoke-e2e/20260615T025612Z/01-installed-version.txt:5`
    — the auto-boot worker logs `image_root=…/tillandsias` (top-level).
- repro:
  - `tillandsias-tray --provision` then
    `ls "$HOME/Library/Application Support/tillandsias"` → disk is top-level,
    while `vz_lifecycle::image_root()` would look under `…/tillandsias/vm`.
- next_action: >
    Pick one canonical state-dir path and converge all four sources on it
    (top-level appears to be the live one). Either delete/rewire the divergent
    `vz_lifecycle::image_root()` (and confirm its `VzRuntime` instance is not a
    live boot path that would look in an empty `/vm` dir) or move provisioning to
    the `/vm` subdir consistently. Fix the misleading doc comment. Add a unit
    test asserting provision-dir == boot-dir == diagnose-dir.
- events:
  - type: discovered
    ts: "2026-06-15T02:58:00Z"
    agent_id: macos-claude-opus
    host: macos

## Work Packet: macos-tray/cold-boot-vsock-poll-races

- id: `macos-tray/cold-boot-vsock-poll-races`
- type: investigate
- title: vsock control-wire polls error ("Connection reset by peer" / "Broken pipe") during/just after VM auto-boot
- owner_host: macos
- capability_tags: [rust, macos, vsock, control-wire, lifecycle]
- status: ready
- discovered_by: `/build-install-and-smoke-test-e2e (macos)`
- owned_files:
  - `crates/tillandsias-macos-tray/src/action_host.rs`
  - `crates/tillandsias-vm-layer/src/transport_macos.rs`
  - `crates/tillandsias-control-wire/src/lib.rs`
- evidence:
  - `target/build-install-smoke-e2e/20260615T025612Z/01-installed-version.txt:8-10`
    — `local-projects` / `cloud-projects` / `github-login` polls all log
    `vsock connect: VZ connect error: … Connection reset by peer` immediately
    after `Auto-boot: VM is running`.
  - same file `:18-21` — once the guest reaches the login prompt, `vm-status
    poll` then logs `VmStatusRequest: Broken pipe (os error 32)` repeatedly.
- notes: >
    Observed against a warm pre-existing VM that was mid-boot (the tray was
    spawned by the erroneous `--version` invocation — see
    `macos-tray/version-help-flags-boot-vm` — then killed). Lower confidence as a
    standalone defect: the polls may simply be racing the in-guest agent before
    it binds its vsock port. Worth confirming whether the host pollers back off /
    retry cleanly until the agent is listening, vs. surfacing these as user-
    visible errors. Re-observe on a clean cold boot without the `--version` path.
- next_action: >
    Reproduce on a clean `--provision` + normal tray launch, time when the guest
    vsock agent starts listening vs. when the host pollers first dial, and add a
    bounded retry/backoff (or suppress pre-readiness errors) so cold-boot does
    not emit reset/broken-pipe noise.
- events:
  - type: discovered
    ts: "2026-06-15T02:58:00Z"
    agent_id: macos-claude-opus
    host: macos

## Current Run (Blocked)

- Discovered by: `/build-install-and-smoke-test-e2e`
- Host: Linux (`macuahuitl`)
- Branch: `linux-next`
- Commit under test: `73dcb4965ee9cdb9010ab90d0a877003415f422b`
- Installed build: `Tillandsias v0.3.260614.3`
- Evidence: `target/build-install-smoke-e2e/20260614T073632Z/`
- Passed gates:
  - `./build.sh --ci-full --install` exited 0.
  - Pre-build CI passed 14/14 checks; pre-build litmus passed 129/129.
  - Post-build litmus passed 6/6; runtime litmus passed 5/5.
  - `podman system reset --force` exited 0 and the clean-store check found
    zero containers, images, and volumes.
  - `tillandsias --init --debug` exited 0 and built every image from the
    pristine store; Vault remained healthy and unsealed.
- Outcome: BLOCKED at
  `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"`.
  Two consecutive attempts exited 143 with empty stdout/stderr before any forge
  agent container started.

## Verification Run (Pass)

- Discovered by: `/build-install-and-smoke-test-e2e`
- Host: Linux (`macuahuitl`)
- Branch: `linux-next`
- Commit under test: `6235e4f3660dead7df961ecd4600a98b5e66ac19`
- Evidence: `target/build-install-smoke-e2e/20260614T062133Z/`
- Outcome: PASS (All build, installation, reset, init, and diagnostics checks successfully completed).

## Initial Run (Halted)

- Discovered by: `/build-install-and-smoke-test-e2e`
- Host: Linux (`macuahuitl`)
- Branch: `linux-next`
- Commit under test: `ec1c5ac413113083d654e784ca6b087997d16aa2`
- Evidence: `target/build-install-smoke-e2e/20260614T060050Z/`
- Outcome: HALTED at `./build.sh --ci-full --install` with exit 1.
- Safety boundary: install did not complete, so the skill correctly did not run
  `podman system reset --force`, `tillandsias --init --debug`, or the forge lane.

## Work Packet: local-smoke/headless-clippy-clean

- id: `local-smoke/headless-clippy-clean`
- owner_host: linux
- capability_tags: [rust, clippy, headless, testing]
- status: completed
- discovered_by: `/build-install-and-smoke-test-e2e`
- owned_files:
  - `crates/tillandsias-headless/src/vault_bootstrap.rs`
  - `crates/tillandsias-headless/src/main.rs`
- evidence:
  - `target/build-install-smoke-e2e/20260614T060050Z/01-build-install.log:58`
    — `PendingHandover` fields are dead under the workspace clippy build.
  - `target/build-install-smoke-e2e/20260614T060050Z/01-build-install.log:72`
    — in-VM credential helper functions are dead under that build.
  - `target/build-install-smoke-e2e/20260614T060050Z/01-build-install.log:90`
    through `:197` — six `clippy::collapsible_if` failures across
    `vault_bootstrap.rs` and `main.rs`.
- repro:
  - `cargo clippy --workspace -- -D warnings`
- next_action: >
    Preserve the Linux-vs-VM feature contract while removing or correctly
    cfg-gating dead handover surfaces, then apply the mechanical collapsible-if
    fixes. Run workspace clippy with warnings denied and the focused Vault and
    init tests.
- acceptance_evidence:
  - "`cargo clippy --workspace -- -D warnings` passes."
  - "Vault bootstrap and headless init tests pass."
- events:
  - type: discovered
    ts: "2026-06-14T06:03:05Z"
    agent_id: "linux-macuahuitl-codex-20260614T055748Z"
    host: linux

## Work Packet: local-smoke/forge-base-split-validator-drift

- id: `local-smoke/forge-base-split-validator-drift`
- owner_host: linux
- capability_tags: [bash, containers, forge, litmus, testing]
- status: completed
- discovered_by: `/build-install-and-smoke-test-e2e`
- owned_files:
  - `scripts/check-container-bases.sh`
  - `openspec/litmus-tests/litmus-forge-shell-tools-implementation-shape.yaml`
  - `openspec/specs/default-image/spec.md`
  - `openspec/specs/forge-shell-tools/spec.md`
- evidence:
  - `target/build-install-smoke-e2e/20260614T060050Z/01-build-install.log:1320`
    — base policy expects the runtime `Containerfile` to directly name Fedora
    and rejects its canonical `${BASE_IMAGE}` parent.
  - `target/build-install-smoke-e2e/20260614T060050Z/01-build-install.log:1321`
    — the same policy rejects the runtime file's default local
    `tillandsias-forge-base:latest` build argument.
  - `target/build-install-smoke-e2e/20260614T060050Z/01-build-install.log:1633`
    — shell-tools litmus still searches the runtime `Containerfile` for
    `fish zsh`, although packages moved to `Containerfile.base`.
- repro:
  - `scripts/check-container-bases.sh`
  - `./scripts/run-litmus-test.sh forge-shell-tools --size quick`
- next_action: >
    Teach the base policy about the two-stage forge image contract: validate
    Fedora Minimal in `Containerfile.base`, validate the runtime file's
    `${BASE_IMAGE}` handoff without allowing an external mutable pull, and move
    shell-package assertions to `Containerfile.base`. Keep the content-addressed
    build argument supplied by the canonical image builder as the authority.
- acceptance_evidence:
  - "`scripts/check-container-bases.sh` passes without weakening unrelated latest-tag checks."
  - "The forge-shell-tools quick litmus passes."
  - "`./build.sh --check` passes."
- events:
  - type: discovered
    ts: "2026-06-14T06:03:05Z"
    agent_id: "linux-macuahuitl-codex-20260614T055748Z"
    host: linux

## Work Packet: local-smoke/windows-cheatsheet-image-mirror-drift

- id: `local-smoke/windows-cheatsheet-image-mirror-drift`
- owner_host: any
- capability_tags: [docs, cheatsheets, windows, testing]
- status: completed
- discovered_by: `/build-install-and-smoke-test-e2e`
- owned_files:
  - `cheatsheets/runtime/windows-tray-diagnostics.md`
  - `images/default/cheatsheets/runtime/windows-tray-diagnostics.md`
- evidence:
  - `target/build-install-smoke-e2e/20260614T060050Z/01-build-install.log:1424`
    — `litmus:cheatsheet-host-image-sync` expected synchronized trees.
  - `target/build-install-smoke-e2e/20260614T060050Z/01-build-install.log:1425`
    — the Windows diagnostics cheatsheet differs between host and image.
  - Current diff: the host copy documents
    `manifest_pin_x86_64_oci_tar_xz`, while the image copy retains obsolete
    `manifest_pin_x86_64_tar`.
- repro:
  - `./scripts/run-litmus-test.sh cheatsheet-tooling --size quick`
- next_action: >
    Treat the updated host cheatsheet as canonical, synchronize the image mirror,
    verify the field name against current Windows diagnostics JSON, and run the
    host/image synchronization litmus.
- acceptance_evidence:
  - "The two cheatsheet trees are byte-identical."
  - "`litmus:cheatsheet-host-image-sync` passes."
- events:
  - type: discovered
    ts: "2026-06-14T06:03:05Z"
    agent_id: "linux-macuahuitl-codex-20260614T055748Z"
    host: linux

## Work Packet: local-smoke/cli-tray-singleton-self-termination

- id: `local-smoke/cli-tray-singleton-self-termination`
- type: fix
- title: Prevent detached tray startup from terminating foreground CLI modes
- owner_host: linux
- capability_tags: [rust, lifecycle, singleton, tray, opencode, testing]
- status: completed
- discovered_by: `/build-install-and-smoke-test-e2e`
- owned_files:
  - `crates/tillandsias-headless/src/main.rs`
  - `crates/tillandsias-core/src/singleton.rs`
  - `openspec/specs/singleton-guard/spec.md`
  - `openspec/specs/tray-cli-coexistence/spec.md`
  - `openspec/litmus-tests/`
- evidence:
  - `target/build-install-smoke-e2e/20260614T073632Z/07-forge-continuous-enhancement-exit.txt`
    — first launch exited 143 with an empty adjacent log.
  - `target/build-install-smoke-e2e/20260614T073632Z/09-forge-retry-exit.txt`
    — retry reproduced exit 143 with an empty adjacent log.
  - `crates/tillandsias-headless/src/main.rs:260` — foreground `--opencode`
    acquires the global `launcher` singleton before mode dispatch.
  - `crates/tillandsias-headless/src/main.rs:382` and
    `crates/tillandsias-headless/src/main.rs:4257` — that foreground process
    spawns the same executable as detached `--tray`.
  - `crates/tillandsias-core/src/singleton.rs:64` — the child tray finds the
    parent's lock busy and terminates the lock owner with SIGTERM before taking
    the same lock. Exit 143 is `128 + SIGTERM`.
- repro:
  - `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"`
- next_action: >
    Separate tray lifetime ownership from foreground CLI lifetime ownership.
    Start by adding a regression test around the mode-to-singleton policy, then
    give the tray a distinct lock or exempt foreground CLI modes from the
    destructive launcher singleton while preserving collision protection for
    long-lived runtime modes. Verify that spawning the detached tray cannot
    signal its foreground parent and that an already-running tray is reused.
- acceptance_evidence:
  - "The repro no longer exits 143 and starts an OpenCode forge agent container."
  - "A foreground CLI launch can coexist with the detached tray control socket."
  - "A second tray launch still collapses safely without terminating the foreground CLI."
  - "Focused singleton/tray tests and `./build.sh --check` pass."
- fallback_when_blocked: >
    Add a deterministic process-level regression harness using
    `TILLANDSIAS_LOCK_NAME` and a stub tray child so the parent/child singleton
    interaction can be proven without starting Podman.
- events:
  - type: discovered
    ts: "2026-06-14T07:53:03Z"
    agent_id: "linux-macuahuitl-codex-20260614T073632Z"
    host: linux
    note: >
      Full build, install, destructive reset, and pristine init passed. The
      final forge gate reproduced the singleton parent-kill twice.
  - type: fixed
    ts: "2026-06-14T13:06:00Z"
    agent_id: "linux-antigravity"
    host: linux
    note: >
      Exempted CLI modes from the SingletonGuard check in main.rs. Created process-level
      regression test in singleton_coexistence.rs and verified the fix.
