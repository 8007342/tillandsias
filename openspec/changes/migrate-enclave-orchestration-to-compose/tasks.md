# Tasks: Migrate Enclave Orchestration to Podman Compose

@trace spec:enclave-compose-migration

## Phase 1 — Scaffolding

- [ ] **1. New crate** `crates/tillandsias-compose/` skeleton with
      `tokio`, `thiserror`, `rust-embed`, and `serde_yaml` dependencies.
      Public surface: `Compose`, `ComposeProfile`, `ComposeError`,
      `ServiceState`. No call-site wiring yet.
- [ ] **2. Asset tree** under `src-tauri/assets/compose/`:
      - [ ] `compose.yaml` — four-service topology, two networks
            (`enclave` internal, `egress` external), three external secrets.
      - [ ] `compose.dev.yaml` — bind-mount overlay for live source dev.
      - [ ] `compose.local.yaml` — single-forge scratchpad overlay; default
            rootless network; no enclave / no proxy / no git / no inference.
      - [ ] `README.md` — the multi-environment contract: what each
            overlay enables, exact `podman-compose` invocations, expected
            behavior diff between envs.
- [ ] **3. Move existing per-service files** into
      `src-tauri/assets/compose/services/`:
      - [ ] `services/forge/` ← from `images/default/` (with renames so
            "forge" is the canonical service name; `images/default/` is
            historical and confusing).
      - [ ] `services/proxy/` ← from `images/proxy/`.
      - [ ] `services/git/` ← from `images/git/`.
      - [ ] `services/inference/` ← from `images/inference/`.
- [ ] **4. Update build pipeline** to point at the new paths:
      - [ ] `flake.nix` — update all `./images/default/...` and other
            `./images/<service>/...` paths to `./src-tauri/assets/compose/services/<service>/...`.
      - [ ] `scripts/build-image.sh` — update `IMAGE_DIR` case
            dispatcher (lines ~255–261) and the untracked-files /
            staleness-hash globs (lines ~178, ~201, ~208) to scan the new
            tree.
      - [ ] Confirm `./build.sh --check` still passes against the new
            layout.

## Phase 2 — Cutover

- [ ] **5. Implement `Compose` API** in
      `crates/tillandsias-compose/src/lib.rs`:
      - [ ] `materialize(project, profile)` extracts embedded assets into
            `$XDG_RUNTIME_DIR/tillandsias/compose/<project>/`.
      - [ ] `up(&self)` → `podman-compose -f ... -p ... up -d`.
      - [ ] `down(&self, volumes)` → `podman-compose -f ... -p ... down [-v]`.
      - [ ] `restart(&self, service)` → `... restart <service>`.
      - [ ] `logs(&self, service)` → returns `tokio::process::Child` for
            streaming.
      - [ ] `ps(&self)` → parses `--format json` output.
      - [ ] `exec(&self, service, cmd)` → `... exec <service> <cmd...>`.
- [ ] **6. Wire `handlers.rs`** enclave bring-up paths to call
      `Compose::up(project, profile)`; keep the existing Rust-side
      readiness-probe loop for service ordering.
- [ ] **7. Delete dead code**:
      - [ ] `crates/tillandsias-podman/src/launch.rs::build_run_args`
            (forge / proxy / git / inference branches; keep
            `query_occupied_ports` and `allocate_port_range`).
      - [ ] `src-tauri/src/launch.rs::build_podman_args` (most of it; CLI
            mode entry point that does `podman run -it --rm` for the
            foreground TTY case stays).
      - [ ] `src-tauri/src/runner.rs::run` orchestration body — collapses
            to `Compose::up` plus readiness probe.

## Phase 3 — Hardening

- [ ] **8. Per-service spec docs**: write `README.md` in each of the four
      `services/<name>/` directories following the fixed-format contract
      in `design.md` §3:
      - [ ] `services/forge/README.md`
      - [ ] `services/proxy/README.md`
      - [ ] `services/git/README.md`
      - [ ] `services/inference/README.md`
- [ ] **9. Lint scripts**:
      - [ ] `scripts/lint-compose.sh` — asserts `cap_drop: [ALL]`,
            `security_opt: [no-new-privileges]`, `userns_mode: keep-id`,
            forge-not-on-egress, proxy-only-on-egress, `internal: true` on
            enclave network, all secrets `external: true`.
      - [ ] `scripts/check-containerfile-docs.sh` — asserts every service
            in `compose.yaml` has a `README.md` with the mandated section
            headers.
      - [ ] Hook both into `build.sh --test`.
- [ ] **10. Preflight check** — add `podman-compose >= 1.5.0` to
      `crates/tillandsias-core/src/preflight.rs` with a clear error
      message on missing/old version.
- [ ] **11. Toolbox + bootstrap**:
      - [ ] `build.sh` adds `podman-compose` to the dev toolbox install
            step.
      - [ ] README documents `rpm-ostree install podman-compose` for
            host installation on Fedora Silverblue.
- [ ] **12. Integration tests** in `crates/tillandsias-compose/tests/`:
      - [ ] `prod_smoke` — `up`, all four services reach healthy,
            `down -v`, cleanup.
      - [ ] `forge_offline` — from inside forge, `curl 1.1.1.1` fails
            (network unreachable), confirming `internal: true` is wired.
      - [ ] `secret_mount` — pre-create a known secret, mount into forge,
            assert readable at `/run/secrets/...`, assert not in
            `podman inspect` output.
      - [ ] `local_profile` — `compose.local.yaml` overlay brings up only
            forge with default rootless network and host bind-mount.
- [ ] **13. Migration of `run-forge-standalone.sh`** (optional, separately
      landable) — convert to a thin wrapper around
      `podman-compose -f compose.yaml -f compose.local.yaml -p <proj>-local up forge`.
      Keep the same CLI surface so users don't notice.
- [ ] **14. Cleanup pass** on the bespoke per-service test scripts
      (`test-forge.sh`, `test-proxy.sh`, `test-git-mirror.sh`,
      `test-inference.sh`) — either delete or convert to thin shims that
      `exec compose::exec`.

## Verification

- [ ] `./build.sh --check` — type-check passes.
- [ ] `./build.sh --test` — all tests (including new `lint-compose.sh`
      and `check-containerfile-docs.sh` invocations) pass.
- [ ] Manual: launch the tray on a known project; verify enclave brings
      up cleanly via Compose; verify `podman events` stream still drives
      tray state transitions; verify `down` is clean (no leaked
      containers, networks, or secrets).
- [ ] README's `FOR ROBOTS` block updated with the new
      `spec:enclave-compose-migration` trace anchor.
- [ ] Version bumped per `methodology/versioning.yaml`.

## Out of scope (tracked separately)

- Migration to `quadlet` for systemd-managed lifecycle.
- Switching `inference` to a non-ollama backend.
- AppImage runtime distribution of `podman-compose` (bundled vs
  user-installed).
