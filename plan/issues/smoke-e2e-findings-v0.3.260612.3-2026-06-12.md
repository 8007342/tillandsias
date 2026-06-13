# Smoke E2E Findings - Release v0.3.260612.3 - 2026-06-12

Discovered by `/smoke-curl-install-and-test-e2e` skill execution.

Run summary: curl-install passed, `podman system reset --force` passed and left the store empty, but fresh `tillandsias --debug --init` failed while building the `forge` image. Per the skill, the smoke halted before the `--opencode` forge continuous-enhancement step.

---

### Work Packet: smoke-finding/forge-cargo-binstall-quickinstall-403

- id: `smoke-finding/forge-cargo-binstall-quickinstall-403`
- owner_host: linux
- capability_tags: [rust, podman, testing, release, forge]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260612.3`
- evidence:
  - `target/smoke-e2e/03-init.log:3548` - `[tillandsias] build-forge: ... cargo-audit-0.22.2 ... Received status code 403 Forbidden, will wait for 120s and retry`
  - `target/smoke-e2e/03-init.log:3561` - `[tillandsias] build-forge:   x For crate cargo-audit: Fallback to cargo-install is disabled`
  - `target/smoke-e2e/03-init.log:3565` - `FAILED forge: Build exited with status exit status: 94`
  - `target/smoke-e2e/03-init.log:3616` - `Error: Failed to build 1 image(s): forge`
- repro:
  - From a pristine Podman store, run `tillandsias --debug --init` using the published `v0.3.260612.3` Linux release binary on a host where the forge build has no usable GitHub API token for `cargo-binstall` quickinstall lookups.
- next_action: >
    Remove the release-critical forge build dependency on unauthenticated `cargo-binstall` quickinstall API lookups. Prefer Fedora-packaged equivalents where available, or pin direct release artifacts with checksums; if a tool must use `cargo-binstall`, either pass a valid rate-limit-safe token during release-runtime image builds or allow a bounded compile fallback. Coordinate with `plan/issues/forge-package-manager-and-telemetry-2026-06-12.md`, which already tracks migrating fragile forge installer paths to native package-manager installs and better build telemetry.
- events:
  - type: discovered
    ts: `2026-06-12T22:18:27Z`
    agent_id: `linux-yoga-codex-20260612T221827Z`
    host: linux
