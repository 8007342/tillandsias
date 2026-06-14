# Local build/install smoke findings — 2026-06-14

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
- status: ready
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
- status: ready
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
- status: ready
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
