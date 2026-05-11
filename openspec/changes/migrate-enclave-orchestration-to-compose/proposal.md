# Proposal: Migrate Enclave Orchestration to Podman Compose

@trace spec:enclave-compose-migration

## Executive Summary

Replace the bespoke per-container `podman run` argument construction currently
spread across `crates/tillandsias-podman/src/launch.rs`, `src-tauri/src/launch.rs`,
`src-tauri/src/runner.rs`, and `src-tauri/src/handlers.rs` with a single
declarative **Podman Compose** definition. The four-service enclave (forge,
proxy, git, inference) is described in one `compose.yaml`; per-service
Containerfiles are kept as separate, fully-documented artifacts and embedded
into the tray binary via `rust-embed`; lifecycle is driven from a new
`crates/tillandsias-compose/` crate that shells out to `podman-compose`.

This is a refactor of the orchestration layer only. It does **not** change:

- the Nix-based reproducible image build (`flake.nix`, `scripts/build-image.sh`);
- the secrets architecture (ephemeral podman secrets created by
  `scripts/create-secrets.sh`);
- the event-driven state machine fed by `podman events`;
- the keyring / D-Bus credential flow.

## Problem

### Current state

Enclave bring-up today is several hundred lines of imperative Rust:

- `crates/tillandsias-podman/src/launch.rs::build_run_args` — ~150 lines
  constructing flag vectors for one container at a time.
- `src-tauri/src/launch.rs::build_podman_args` — ~400 lines wiring
  per-service flag sets, port allocation, mount strings, secret references.
- `src-tauri/src/runner.rs::run` — ~200 lines of sequencing logic that
  starts proxy, waits for health, starts git, waits, starts inference, waits,
  starts forge.
- `src-tauri/src/handlers.rs` — orchestration entry points calling into the
  above.

Security guarantees (`--cap-drop=ALL`, `--security-opt=no-new-privileges`,
`--userns=keep-id`, `--rm`, internal-only network attachment, secret mounts,
read-only rootfs where applicable) are re-asserted independently per service.
A reviewer who wants to answer "is the forge truly offline?" must trace four
Rust files and reconstruct the effective `podman run` command in their head.

### Why this hurts

1. **Reviewability** — security posture is reasserted per-call-site instead of
   declared in one place. A regression where one service silently loses
   `--cap-drop=ALL` would not show up in any diff that's easy to read.
2. **Onboarding** — every contributor must learn Tillandsias' bespoke
   argument-builder DSL. Compose YAML is the lingua franca; contributors and
   security reviewers already read it.
3. **Extension cost** — adding a fifth service (e.g. an observability sidecar,
   a different inference backend) requires touching 3–4 Rust files.
   Declaratively it is one YAML block plus one Containerfile.
4. **Drift between scripts and Rust** — `scripts/orchestrate-enclave.sh`,
   `scripts/test-forge.sh`, `scripts/test-proxy.sh`,
   `scripts/test-git-mirror.sh`, `scripts/test-inference.sh` each carry their
   own (subtly different) flag set. Compose collapses them onto the same
   source of truth.

## Solution

### Architectural commitments

1. **One `compose.yaml`** describes the four-service enclave plus the
   two networks (`enclave` internal-only, `egress` external) and the
   `external: true` secret references.

2. **Four Containerfiles**, one per service, each a separately documented
   artifact. We deliberately reject the alternative of a single multi-stage
   Containerfile (see `design.md` §1 for justification).

3. **Embedded artifacts** — the YAML, the Containerfiles, and per-service
   support files (entrypoints, conf templates) are baked into the tray binary
   via `rust-embed`. At runtime they are materialized to
   `$XDG_RUNTIME_DIR/tillandsias/compose/<project>/` and orchestrated from
   there. Debug builds get filesystem passthrough so editing a Containerfile
   does not require a rebuild.

4. **`podman-compose` (Python, ≥ 1.5.0)** is the chosen Compose provider. We
   pin a minimum version in preflight. We deliberately reject `podman compose`
   (the v5 native subcommand) — it re-execs `podman-compose` or
   `docker-compose` anyway, while introducing `containers.conf` provider
   resolution as a hidden failure mode.

5. **Multi-environment story** is first-class. Three named environments,
   each documented and exercised:

   | Env | Compose files | Purpose |
   |---|---|---|
   | `prod` | `compose.yaml` (profile: prod) | Default tray operation. Image tags from Nix. Forge offline. Secrets external. |
   | `dev` | `compose.yaml` + `compose.dev.yaml` | Live source bind-mounts, faster rebuild loop, allows transient `nix build` cache passthrough. |
   | `local` | `compose.yaml` + `compose.local.yaml` | Single-forge "scratchpad" mode mirroring `run-forge-standalone.sh`. No proxy / git / inference. Default rootless network. For tuning the forge image itself. |

   Future migration of `run-forge-standalone.sh` to invoke
   `podman-compose --profile local up forge` is a possibility but **not**
   in scope for this change — see Non-goals.

6. **Lifecycle drives from `crates/tillandsias-compose/`**: a new crate
   shelling out to `podman-compose`. Existing `podman events` consumer in
   `crates/tillandsias-podman/src/events.rs` is unchanged; Compose does not
   replace the events stream.

7. **Health-gating stays Rust-side**. `depends_on: condition: service_healthy`
   has open reliability bugs in `podman-compose` (issues #866, #1119, #1129);
   the existing readiness-probe loop in `handlers.rs` remains the source of
   truth for "service X is ready". Compose handles `up -d` of the whole stack;
   Rust handles ordering and observability.

8. **Spec discipline for Containerfiles**. Every `services/<name>/` directory
   carries a `README.md` with a fixed-format header (see `design.md` §3) and
   is validated by `scripts/check-containerfile-docs.sh` on `build.sh --test`.
   No Containerfile may merge without a corresponding spec block.

## Non-goals

- **Replacing the Nix image build.** `flake.nix` remains canonical for
  reproducible release images; Containerfiles are reference docs + a
  `podman-compose build` dev fallback.
- **Migrating `run-forge-standalone.sh`.** Stays as a standalone shell script
  for now; can fold into the `local` profile in a follow-up change.
- **Replacing `podman events`** as the lifecycle event source.
- **Replacing host-side ollama model pulls** (see CLAUDE.md "Lazy Model
  Pulling" — that path is independent of orchestration).
- **Switching to a Compose REST/Docker-API client** (`bollard`, `podman-api`,
  `podtender`). They do not implement Compose semantics and require enabling
  the Podman socket service. Shelling out to `podman-compose` is cleaner.
- **Removing the bespoke per-service test scripts** (`test-forge.sh`,
  `test-proxy.sh`, …). They get a follow-up cleanup pass.

## Out-of-scope risks acknowledged but not addressed here

- Migration to `quadlet` (systemd-managed containers). Different layer.
- AppImage runtime dependency on `podman-compose`. Bootstrap is documented;
  end-user impact is small (Fedora Silverblue users can `rpm-ostree install
  podman-compose` or run inside the existing toolbox).
