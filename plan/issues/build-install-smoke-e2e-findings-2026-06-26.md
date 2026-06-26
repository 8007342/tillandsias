# Build-Install-Smoke E2E Findings — 2026-06-26

**Run ID**: 20260626T035811Z  
**Commit tested**: 8a707b3a (linux-next, then in-forge checkpoints through 481f58c5)  
**Installed version**: Tillandsias v0.3.260626.1  
**Host**: linux_mutable  
**Log dir**: target/build-install-smoke-e2e/20260626T035811Z/

---

## Gate Results

| Gate | Result | Notes |
|------|--------|-------|
| §0 Preflight | PASS | branch=linux-next, clean worktree |
| §1 Build + install | FAIL | Pre-build CI passed; portable launcher installed; post-build smoke failed with the already-filed inference/loop_status false positives |
| §2 Podman reset | NOT REACHED | Build/install gate exited 1 before destructive reset |
| §3 `tillandsias --init` | NOT REACHED | Build/install gate exited 1 |
| §4 Forge meta-orch | NOT REACHED | Build/install gate exited 1 |

---

## Finding: Rust image build path dropped HEALTHCHECK metadata

- id: `local-smoke/vault-image-build-docker-format-healthcheck`
- owner_host: linux
- capability_tags: [rust, podman, vault, healthcheck, build]
- status: done
- discovered_by: `/build-install-and-smoke-test-e2e` (linux)
- evidence:
  - `target/build-install-smoke-e2e/20260626T035811Z/01-build-install.log:2243` — Vault bootstrap failed with `vault container did not report healthy`.
  - `target/build-install-smoke-e2e/20260626T035811Z/01-build-install.log:2244` — Podman reported `cannot use condition "healthy"` because the launched `tillandsias-vault` container had no healthcheck metadata.
  - `images/vault/Containerfile:49` — the image does declare `HEALTHCHECK`, so the metadata was lost during build.
- root_cause: >
    The Rust `build_image_with_logging` path used by Vault invoked
    `podman build` without `--format docker`. The shell builder and shared
    `ImageBuilder` path already pass Docker format, but this runtime builder
    path could produce an OCI image whose metadata did not preserve Dockerfile
    `HEALTHCHECK`. Order 100 then made the regression visible by waiting on
    `podman wait --condition=healthy`.
- fix: >
    `build_image_with_logging` now constructs its build argv through a testable
    helper that includes `--format docker`; the new unit test
    `image_build_argv_uses_docker_format_for_healthchecks` pins this contract.
- verification:
  - `cargo test -p tillandsias-headless image_build_argv_uses_docker_format_for_healthchecks`
- next_action: >
    Rerun the local-build smoke gate. The existing post-build litmus false
    positives may still make `./build.sh --ci-full --install` exit 1 before
    reset; treat those separately from this fixed Vault image metadata issue.
- events:
  - type: discovered
    ts: "2026-06-26T04:10:39Z"
    agent_id: "linux-tlatoani-codex-20260626T035811Z"
    host: linux
  - type: completed
    ts: "2026-06-26T04:14:00Z"
    agent_id: "linux-tlatoani-codex-20260626T0414Z"
    host: linux
    note: >
      Patched the Rust runtime image builder to pass `podman build --format
      docker`, preserving Dockerfile HEALTHCHECK metadata for Vault and other
      managed images. Added a focused unit test.

## Recurring Finding: post-build litmus false positives before reset/init

The 2026-06-24 finding recurred:

- `litmus:inference-deferred-model-pulls` failed on a fresh model cache with
  `models/blobs: permission denied`.
- `litmus:opencode-prompt-e2e-shape` failed because the in-forge meta cycle
  advanced HEAD but did not modify `plan/loop_status.md` in the new commit(s).

These are already tracked as the post-build chicken-and-egg/false-positive
class in `plan/issues/build-install-smoke-e2e-findings-2026-06-24.md`. They
still prevent the scripted local-build smoke from reaching the destructive reset
stage.
