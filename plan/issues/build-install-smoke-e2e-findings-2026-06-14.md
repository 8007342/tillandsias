# Local build/install smoke findings — 2026-06-14

## Current Run (Blocked) — 2026-06-15

- Discovered by: `/build-install-and-smoke-test-e2e`
- Host: Linux (`macuahuitl`)
- Branch: `linux-next`
- Commit under test: `084f892dc625216523af469ecd9a55a1afe16327`
- Installed build: `Tillandsias v0.3.260615.1`
- Evidence: `target/build-install-smoke-e2e/20260615T022851Z/`
- Passed gates:
  - `./build.sh --ci-full --install` exited 0.
  - Pre-build CI passed 14/14 checks; pre-build litmus passed 129/129.
  - Post-build litmus passed 6/6; runtime residual litmus passed 5/5.
  - `podman system reset --force` exited 0 and the clean-store check found
    zero containers, images, and volumes.
  - `tillandsias --init --debug` exited 0 from the pristine store and left
    Vault healthy, initialized, and unsealed.
- Outcome: BLOCKED at the final forge gate. The singleton fix held and the
  forge container started, but OpenCode 1.16.2 opened at an empty interactive
  prompt instead of executing `Use the /forge-continuous-enhancement skill`.
  The run was stopped after confirming the prompt remained idle.
- Additional regression: the evidence bundle printed
  `Litmus tests complete: 8 passed, 4 failed` even though every executed
  pre-build, post-build, and runtime residual litmus passed.

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

## Work Packet: local-smoke/opencode-interactive-prompt-not-consumed

- id: `local-smoke/opencode-interactive-prompt-not-consumed`
- type: fix
- title: Make interactive OpenCode launches consume the requested startup prompt
- owner_host: linux
- capability_tags: [shell, opencode, forge, containers, testing]
- status: ready
- estimated_hours: 5
- depends_on:
  - `local-smoke/cli-tray-singleton-self-termination`
- discovered_by: `/build-install-and-smoke-test-e2e`
- owned_files:
  - `images/default/entrypoint-forge-opencode.sh`
  - `openspec/litmus-tests/`
  - `openspec/litmus-bindings.yaml`
- evidence:
  - `target/build-install-smoke-e2e/20260615T022851Z/04-forge-continuous-enhancement.log`
    — OpenCode 1.16.2 renders an empty `Ask anything...` prompt and never
    executes the requested skill.
  - `images/default/entrypoint-forge-opencode.sh:122-135` writes and exports
    `OPENCODE_INIT_PROMPT_FILE` for interactive launches.
  - `images/default/entrypoint-forge-opencode.sh:148-157` only invokes
    `opencode run` when the diagnostics-only `--print` argument is present.
- repro:
  - `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"`
- next_action: >
    Replace or supplement the ignored OPENCODE_INIT_PROMPT_FILE integration
    with a supported OpenCode 1.16.x startup mechanism. Preserve an interactive
    session when no prompt is supplied, but make a supplied --prompt execute
    deterministically and return a meaningful exit status. Add a container-level
    regression that proves the prompt begins execution rather than merely
    checking entrypoint source text.
- acceptance_evidence:
  - "The repro starts executing /forge-continuous-enhancement without manual input."
  - "An interactive launch without --prompt still opens the OpenCode TUI."
  - "The prompt path propagates the OpenCode run exit status."
  - "Focused litmus and `./build.sh --check` pass."
- fallback_when_blocked: >
    Add an explicit non-interactive CLI mode for supplied prompts and update the
    smoke skills to use it, while retaining the current TUI path for promptless
    interactive launches.
- events:
  - type: discovered
    ts: "2026-06-15T02:49:03Z"
    agent_id: "linux-macuahuitl-codex-20260615T0228Z"
    host: linux
    note: >
      Build, install, reset, and pristine init passed. Foreground and non-PTY
      forge retries both reached OpenCode, but the requested prompt was not
      consumed.

## Work Packet: local-smoke/evidence-bundle-litmus-count-regression

- id: `local-smoke/evidence-bundle-litmus-count-regression`
- type: fix
- title: Derive evidence-bundle litmus totals from the current run
- owner_host: linux
- capability_tags: [bash, ci, evidence, litmus, testing]
- status: ready
- estimated_hours: 3
- depends_on: []
- discovered_by: `/build-install-and-smoke-test-e2e`
- owned_files:
  - `scripts/generate-evidence-bundle.sh`
  - `build.sh`
  - `scripts/local-ci.sh`
- evidence:
  - `target/build-install-smoke-e2e/20260615T022851Z/01-build-install.log:2319`
    reports `8 passed, 4 failed`.
  - The same log records pre-build 129/129, post-build 6/6, and runtime
    residual 5/5 with no executed litmus failures.
- repro:
  - `./build.sh --ci-full --install`
- next_action: >
    Trace the evidence-bundle aggregation inputs and remove stale or
    cross-phase failure-count reuse. Define whether the headline is a sum of
    executed phases or a named phase, then parse structured/current-run data
    accordingly and test a multi-phase all-pass fixture.
- acceptance_evidence:
  - "An all-pass ci-full run reports zero failed litmus tests."
  - "A fixture with one real litmus failure reports exactly one failure."
  - "Pre-build, post-build, and runtime residual summaries cannot overwrite or reuse each other's counters."
  - "`./build.sh --check` passes."
- events:
  - type: regression
    ts: "2026-06-15T02:49:03Z"
    agent_id: "linux-macuahuitl-codex-20260615T0228Z"
    host: linux
    note: >
      Reopens the evidence-count portion of
      finding/build-sh-runtime-litmus-skip; the runtime residual itself now
      executes and passes.
