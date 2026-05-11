# Compose: Multi-Environment Contract

@trace spec:enclave-compose-migration

This directory is the **future home** of the Tillandsias Podman Compose
definition. It is currently scaffolded with per-service spec
`README.md` files; the actual `compose.yaml`, `compose.dev.yaml`,
`compose.local.yaml`, and the relocated `Containerfile`s land under
tasks 2–4 of `openspec/changes/migrate-enclave-orchestration-to-compose/`.

This file documents the **three target environments** the migration
will support and the exact invocations each one uses. Each environment
must be exercised by a smoke test under
`crates/tillandsias-compose/tests/` once that crate exists.

## Environments at a glance

| Env | Files | Forge network | Source mount | Secrets | Purpose |
|---|---|---|---|---|---|
| **prod** | `compose.yaml` | `enclave` (`internal: true`) | named volume `<project>_workdir`, cloned from git mirror | external podman secrets | Default tray operation. What end users run. |
| **dev** | `compose.yaml` + `compose.dev.yaml` | `enclave` (`internal: true`) | host bind-mount RW, plus optional Nix-cache bind | external podman secrets | Day-to-day Tillandsias maintenance. Faster rebuild loop. |
| **local** | `compose.yaml` + `compose.local.yaml` | **default rootless network** (external egress) | host bind-mount RW into `/home/forge/src/<project>` | **none** | Tuning the forge image itself in isolation. Mirror of `./run-forge-standalone.sh`. |

## Invocation reference

```bash
# Prod
podman-compose -f compose.yaml \
    -p tillandsias-<project-slug> up -d

# Dev
podman-compose -f compose.yaml \
    -f compose.dev.yaml \
    -p tillandsias-<project-slug>-dev up -d

# Local (only the forge — no proxy/git/inference)
podman-compose -f compose.yaml \
    -f compose.local.yaml \
    -p tillandsias-<project-slug>-local \
    up -d forge
```

The `-p` project name namespaces all containers, networks, and volumes.
Cross-environment isolation is achieved by varying the `-p` suffix
(`-dev`, `-local`); a single host can run all three concurrently for
the same project.

## Behavioural diffs

### Prod baseline (`compose.yaml`)

- Four services: `forge`, `proxy`, `git`, `inference`.
- Two networks: `enclave` (`internal: true`) and `egress`.
- Proxy is the only service on `egress`. Forge / git / inference are
  on `enclave` only.
- Forge has **zero** secret mounts and **zero** external network
  access. Code comes from the git mirror; packages through the proxy;
  inference from the local ollama.
- All secrets (`tillandsias-github-token`, `tillandsias-ca-cert`,
  `tillandsias-ca-key`) are `external: true` and pre-created by
  `scripts/create-secrets.sh` at tray startup.
- Image tags resolve to `tillandsias-<service>:v<FULL_VERSION>` —
  produced by the Nix pipeline (`flake.nix` + `scripts/build-image.sh`).
  No `build:` step executes by default.

### `compose.dev.yaml` overlay

Layered on top of `compose.yaml`. Overrides:

- **Forge**: bind-mount the host's working copy into
  `/home/forge/src/<project>` instead of using the named volume. Also
  bind-mount `~/.cache/tillandsias/nix` for fast Nix-driven dev
  iteration.
- **Build**: each service's `build:` block becomes active so a
  `podman-compose -f … -f compose.dev.yaml build <service>` rebuilds
  from the local `services/<name>/Containerfile`. Useful when iterating
  on a single Containerfile without involving Nix.
- **Cache passthrough**: extra writable bind for the cargo / npm /
  nix caches.
- **Logging**: services get `STDOUT_VERBOSE=1`.
- Networks **unchanged** — dev is still enclave-isolated. Use the
  `local` overlay if you need external egress from the forge.

### `compose.local.yaml` overlay

Layered on top of `compose.yaml`, but **strips** the proxy / git /
inference services via the `services.X.profiles: [enclave]` mechanism
(those services declare `profiles: [enclave]`; the `local` overlay
launches only the `forge` service which does not declare a profile).

- **Forge**: switches to `network_mode: bridge` (default rootless
  network) — gets external egress directly.
- **Source mount**: identical to dev — host bind-mount RW into
  `/home/forge/src/<project>`.
- **Secrets**: forge declares `secrets: []` in the overlay so no
  podman secrets are referenced. Tray's `scripts/create-secrets.sh` is
  not required.
- **Healthcheck**: same as prod.

This overlay is the **declarative equivalent of
`./run-forge-standalone.sh`**. The shell script remains the hand-tuned
entry point until the migration's task 11 collapses it into:

```bash
exec podman-compose \
    -f src-tauri/assets/compose/compose.yaml \
    -f src-tauri/assets/compose/compose.local.yaml \
    -p "tillandsias-${PROJECT}-local" \
    up forge
```

## Why three envs and not profiles

The Compose Spec supports `profiles:` for conditional services. We
deliberately use **overlay files** (`-f a.yaml -f b.yaml`) instead of
profiles because:

1. Overlay invocation is explicit at the shell — readers can see
   which environment is active by reading the command, without
   chasing a `--profile` flag.
2. `compose.dev.yaml` needs to override bind-mount **paths**, not
   just enable/disable services — profiles cannot do that.
3. `podman-compose` profile support has historically lagged the
   spec; overlays work consistently across versions ≥ 1.5.0.

The `enclave` profile annotation is still used inside `compose.yaml`
to gate which services start in the `local` overlay. That is the one
place profiles earn their keep.

## Per-service specs

See the spec READMEs under `services/<name>/README.md`:

- [`services/forge/README.md`](services/forge/README.md) — coding
  environment, zero credentials, no external network
- [`services/proxy/README.md`](services/proxy/README.md) — Squid MITM
  egress proxy, the only service on `egress`
- [`services/git/README.md`](services/git/README.md) — git mirror +
  credentialed GitHub bridge
- [`services/inference/README.md`](services/inference/README.md) —
  ollama with baked T0/T1 + host-side lazy pull for T2–T5

Each follows the spec contract laid out in
`openspec/changes/migrate-enclave-orchestration-to-compose/design.md`
§3 ("Per-Containerfile spec contract"). The validator
`scripts/check-containerfile-docs.sh` enforces the section headers.

## Trace anchors

- `@trace spec:enclave-compose-migration` — this layer
- `@trace spec:enclave-network` — the `internal: true` topology
- `@trace spec:forge-offline` — why the forge is on `enclave` only
- `@trace spec:secrets-management` — external secrets contract
- `@trace spec:nix-builder` — Nix image build pipeline that produces
  the `tillandsias-*:v<VERSION>` tags Compose references
