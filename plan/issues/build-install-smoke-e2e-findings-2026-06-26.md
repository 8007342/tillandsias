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

---

## Rerun: 20260626T041632Z

**Commit tested**: 72e1fb8f plus local checkpoint 08a7a3cc
**Installed version**: Tillandsias v0.3.260626.2
**Log dir**: target/build-install-smoke-e2e/20260626T041632Z/

| Gate | Result | Notes |
|------|--------|-------|
| §0 Preflight | PASS | branch=linux-next, clean at start |
| §1 Build + install | FAIL | Pre-build CI passed; portable launcher installed; post-build smoke failed |
| §2 Podman reset | NOT REACHED | Build/install gate exited 1 before destructive reset |
| §3 `tillandsias --init` | NOT REACHED | Build/install gate exited 1 |
| §4 Forge meta-orch | NOT REACHED | Build/install gate exited 1 |

Evidence:

- `target/build-install-smoke-e2e/20260626T041632Z/01-build-install.log:2246`
  shows `tillandsias-vault` bootstrap completed. The previous
  `cannot use condition "healthy"` / missing HEALTHCHECK error did not recur.
- `podman inspect tillandsias-vault --format '{{json .Config.Healthcheck}}'`
  reported the expected Vault HTTPS healthcheck metadata after the rerun.
- `target/build-install-smoke-e2e/20260626T041632Z/01-build-install.log:2305`
  shows the recurring inference model cache failure:
  `Error: open /home/ollama/.ollama/models/blobs: permission denied`.
- `target/build-install-smoke-e2e/20260626T041632Z/01-build-install.log:2313`
  shows `litmus:opencode-prompt-e2e-shape` timing out in step 3.
- `target/build-install-smoke-e2e/20260626T042455Z/00-smoke-lock.log:1`
  shows the nested meta-orchestration child waiting on the same
  `build-install-smoke-e2e` lock held by the parent run.

## Finding: nested meta-orchestration local-build smoke waits on parent smoke lock

- id: `local-smoke/nested-build-install-smoke-lock-skip`
- owner_host: linux
- capability_tags: [bash, smoke, meta-orchestration, concurrency]
- status: done
- discovered_by: `/build-install-and-smoke-test-e2e` (linux)
- evidence:
  - `target/build-install-smoke-e2e/20260626T041632Z/01-build-install.log:2313`
    — `opencode-prompt-e2e-shape` timed out launching the nested forge prompt.
  - `target/build-install-smoke-e2e/20260626T042455Z/00-smoke-lock.log:1`
    — the nested child attempted `./build.sh --ci-full --install` and waited
    for `build-install-smoke-e2e.lock` while the parent `./build.sh` still held
    it.
- root_cause: >
    The nested `/meta-orchestration` agent saw an otherwise eligible mutable
    Linux host and started `/build-install-and-smoke-test-e2e` from inside a
    parent post-build litmus. Because the parent `./build.sh --ci-full --install`
    runs under `scripts/with-smoke-lock.sh`, the child blocked on the same lock
    until the e2e timeout fired.
- fix: >
    `scripts/e2e-preflight.sh eligibility` now probes the
    `build-install-smoke-e2e` lock non-blockingly and returns
    `skip:smoke-lock-held` when another local smoke owns it. The
    meta-orchestration E2E gate guidance now records that verdict and skips the
    nested local-build gate. `litmus:e2e-eligibility-probe-shape` pins the new
    deterministic skip branch.
- verification:
  - `bash -n scripts/e2e-preflight.sh`
  - `bash scripts/e2e-preflight.sh eligibility`
  - `scripts/run-litmus-test.sh meta-orchestration --phase pre-build --size instant`
- next_action: >
    Rerun the local-build smoke after this guard. A nested forge prompt should
    skip its own local-build gate with `skip:smoke-lock-held`, avoiding the
    parent/child smoke-lock wait.
- events:
  - type: discovered
    ts: "2026-06-26T04:32:58Z"
    agent_id: "linux-tlatoani-codex-20260626T041632Z"
    host: linux
  - type: completed
    ts: "2026-06-26T04:40:00Z"
    agent_id: "linux-tlatoani-codex-20260626T0440Z"
    host: linux
    note: >
      Added a structured `skip:smoke-lock-held` preflight verdict and pinned it
      with the existing e2e-eligibility litmus.
