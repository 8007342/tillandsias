# Design: Migrate Enclave Orchestration to Podman Compose

@trace spec:enclave-compose-migration

## Context

Tillandsias today launches its four-service enclave (forge, proxy, git,
inference) by constructing `podman run` argument vectors in Rust. The
maintainer's intent is to express the enclave declaratively as a Compose
definition, keep per-service Containerfiles as thoroughly-documented
artifacts, and drive lifecycle from idiomatic Rust by shelling out to the
Compose CLI.

Background research (full report archived in PR description; key citations
inline below) compared `podman-compose` (Python, containers/podman-compose)
with `podman compose` (the Podman 5.x native subcommand). The native
subcommand is a Go wrapper that delegates to the same external Compose
provider — by default `docker-compose` if installed, otherwise
`podman-compose` — and forwards flags through. See
[containers/podman cmd/podman/compose.go](https://github.com/containers/podman/blob/main/cmd/podman/compose.go),
[Podman 5.x docs — podman-compose(1)](https://docs.podman.io/en/latest/markdown/podman-compose.1.html),
[Red Hat — Podman Compose or Docker Compose](https://www.redhat.com/en/blog/podman-compose-docker-compose).

## Goals / Non-Goals

**Goals**

- Single declarative description of the enclave topology, security flags,
  networks, and secret mounts.
- Per-service Containerfile as a separately-reviewable, fully-documented
  artifact.
- Multi-environment story (prod / dev / local) with explicit documentation
  and exercised lifecycle paths.
- Idiomatic Rust API (`Compose::{materialize, up, down, restart, logs, ps,
  exec}`) replacing 600+ lines of bespoke argument-builder code.
- CI guards (`scripts/lint-compose.sh`, `scripts/check-containerfile-docs.sh`)
  preventing silent regressions of security posture or documentation drift.

**Non-Goals** — see `proposal.md`.

## Decisions

### 1. Four Containerfiles, not one multi-stage build

We choose **(b) four Containerfiles, one per service, all referenced from a
single `compose.yaml`**. Rejected: (a) a single multi-stage Containerfile
with per-service targets.

Justifications:

- Each service has a fundamentally different base. Forge is a Nix-built layered
  image (`tillandsias-forge:v<VERSION>`). Proxy is Squid on Fedora minimal.
  Git is a small openssh + git-daemon Alpine. Inference is the upstream ollama
  image with a thin entrypoint wrapper. Forcing them into a shared multi-stage
  build collapses four independent supply chains into one and produces an
  unreadable monolith.
- Multi-stage targets share a build context, which means a change in any
  service's source files invalidates cache for the others.
- Per-service Containerfiles map 1:1 onto the existing
  `images/{default,proxy,git,inference}/` layout — minimal disruption.
- The Nix build path (`flake.nix`) continues to be the canonical reproducible
  build for production. The Containerfiles serve as **documented reference
  specs** and a `podman-compose build` dev fallback when iterating on a single
  service without invoking Nix.

### 2. `podman-compose` (Python), not `podman compose` (native)

Pin **`podman-compose >= 1.5.0`** as a hard dependency. Reject `podman compose`.

- `podman compose` re-execs `podman-compose` (or `docker-compose` if present)
  anyway; we'd just be paying for an extra exec hop and a layer of
  provider-resolution ambiguity controlled by `containers.conf`.
- `podman-compose` is daemonless. `podman compose` going through
  `docker-compose` would require enabling the Podman API socket service
  (`systemctl --user enable --now podman.socket`).
- The dev toolbox bootstrap (`build.sh`) already provisions the dev
  environment; adding `podman-compose` is one line of `dnf install`.

Preflight (`crates/tillandsias-core/src/preflight.rs`) refuses to start if
`podman-compose --version` is missing or reports `< 1.5.0`, with a clear hint
pointing at the installation step in README.

### 3. Embedded artifact pattern: `rust-embed`

The compose YAML(s) and the Containerfiles live in
`src-tauri/assets/compose/` and are embedded via `rust-embed`. Rationale:

- `rust-embed` provides debug-mode filesystem passthrough; in debug builds,
  editing `services/forge/Containerfile` is reflected on the next
  `Compose::materialize()` without recompiling.
- Release builds embed everything into the binary, preserving the
  "single-binary distributable" property of the existing AppImage.
- `include_dir` works but lacks the debug passthrough.
- Plain `include_str!` becomes verbose across the ~16 embedded files.

Layout:

```
src-tauri/assets/compose/
    compose.yaml                       # Canonical topology; profile: prod
    compose.dev.yaml                   # Overlay: source bind-mounts, faster loop
    compose.local.yaml                 # Overlay: single-forge scratchpad
    README.md                          # Multi-env contract (this layer)
    services/
        forge/
            Containerfile
            entrypoint-forge-claude.sh
            entrypoint-forge-codex.sh
            entrypoint-forge-opencode.sh
            entrypoint-forge.sh
            ...                        # support files for the forge image
            README.md                  # Spec-mandated per-service doc
        proxy/
            Containerfile
            entrypoint.sh
            squid.conf.template
            README.md
        git/
            Containerfile
            entrypoint.sh
            README.md
        inference/
            Containerfile
            entrypoint.sh
            README.md
```

Materialization target: `$XDG_RUNTIME_DIR/tillandsias/compose/<project>/`.
The runtime dir is `tmpfs` on systemd systems, so materialized assets do not
hit disk. Variables (`${TILLANDSIAS_VERSION}`, `${PROJECT_ID}`,
`${PORT_RANGE_START}`, …) are expanded via the standard Compose env
interpolation; no template engine is introduced.

### 4. Multi-environment overlays

Each environment is documented in `src-tauri/assets/compose/README.md` and
exercised by a smoke test under `crates/tillandsias-compose/tests/`.

| Env | Compose invocation | Forge network | Source mount | Secrets |
|---|---|---|---|---|
| `prod` | `podman-compose -f compose.yaml -p <proj> up -d` | `enclave` only (internal: true) | named volume `<proj>_workdir` (cloned from git mirror) | external |
| `dev` | `podman-compose -f compose.yaml -f compose.dev.yaml -p <proj> up -d` | `enclave` only | bind-mount host source RW; live `cargo build` cache passthrough | external |
| `local` | `podman-compose -f compose.yaml -f compose.local.yaml -p <proj>-local up -d forge` | default rootless network | bind-mount host source RW into `/home/forge/src/<project>` | none mounted |

The `local` overlay strips the proxy/git/inference services and switches the
forge to the default rootless network. This intentionally mirrors what
`./run-forge-standalone.sh` does today; the shell script remains the
hand-tuned entry point for now, with a future migration tracked in
`tasks.md` task 11.

### 5. Networks

Two named networks:

```yaml
networks:
  enclave:
    driver: bridge
    internal: true                # Hard: no external egress
  egress:
    driver: bridge
    internal: false               # Only the proxy is on this network
```

Sources:
[oneuptime — Compose networks with Podman](https://oneuptime.com/blog/post/2026-03-17-use-compose-networks-podman/view),
[podman-compose #288](https://github.com/containers/podman-compose/issues/288).
The `internal: true` flag is verified by `scripts/lint-compose.sh` and by a
runtime integration test that `curl`s an external host from inside the forge
and asserts network unreachable.

### 6. Secrets

Continue the existing ephemeral-podman-secrets pattern verbatim:

- Tray startup runs `scripts/create-secrets.sh` to read tokens / certs from
  the host keyring and create `--driver=file` podman secrets.
- Compose YAML references them with `external: true`:

```yaml
secrets:
  tillandsias-github-token:
    external: true
  tillandsias-ca-cert:
    external: true
  tillandsias-ca-key:
    external: true
```

Service blocks attach them with the `secrets: [tillandsias-ca-cert]` form,
which Compose translates to `--secret tillandsias-ca-cert` on `podman run`.

Known sharp edge: `external` secrets sometimes mis-handle on
`podman compose`'s docker-compose path
([podman #25930](https://github.com/containers/podman/issues/25930),
[podman-compose #760](https://github.com/containers/podman-compose/issues/760)).
Mitigated by pinning `podman-compose` (Python) as the provider; integration
test mounts a known secret and reads it from inside the forge to confirm.

### 7. Health-gating and ordering

`depends_on` with `condition: service_healthy` is unreliable in
`podman-compose`
([#866](https://github.com/containers/podman-compose/issues/866),
[#1119](https://github.com/containers/podman-compose/issues/1119),
[#1129](https://github.com/containers/podman-compose/issues/1129)). The
existing Rust-side readiness-probe loop in `handlers.rs` (currently:
proxy → git → inference → forge) remains the gating mechanism. Compose
handles the parallel `up -d`; Rust handles the ordered "ready" signal that
unlocks tray UX.

### 8. Rust API

New crate `crates/tillandsias-compose/`:

```rust
pub struct Compose {
    project: String,          // "tillandsias-<slug>"
    profile: ComposeProfile,  // Prod | Dev | Local
    workdir: PathBuf,         // materialized YAML location
}

pub enum ComposeProfile { Prod, Dev, Local }

impl Compose {
    pub fn materialize(project: &str, profile: ComposeProfile)
        -> Result<Self, ComposeError>;
    pub async fn up(&self) -> Result<(), ComposeError>;
    pub async fn down(&self, volumes: bool) -> Result<(), ComposeError>;
    pub async fn restart(&self, service: &str) -> Result<(), ComposeError>;
    pub fn logs(&self, service: &str) -> tokio::process::Child;
    pub async fn ps(&self) -> Result<Vec<ServiceState>, ComposeError>;
    pub async fn exec(&self, service: &str, cmd: &[&str])
        -> Result<ExitStatus, ComposeError>;
}
```

All methods build `podman-compose -f <workdir>/compose.yaml [-f <overlay>] -p
<project> ...` argv arrays and shell out via `tokio::process::Command`.

### 9. Lint contract

`scripts/lint-compose.sh` parses `compose.yaml` (via `yq`) and asserts:

- Every service has `cap_drop: [ALL]`.
- Every service has `security_opt` including `no-new-privileges`.
- Every service has `userns_mode: keep-id` (or the `keep-id:uid=,gid=` form).
- Forge service is attached to `enclave` only — `egress` is not in its
  network list.
- Proxy service is the only service attached to `egress`.
- `networks.enclave.internal` is literally `true`.
- All `secrets:` blocks are `external: true`.

CI invocation: hooked into `build.sh --test`.

`scripts/check-containerfile-docs.sh` parses `compose.yaml` for all
`build.context` paths, asserts each has a `README.md` with the mandated
section headers (see "Per-Containerfile spec contract" below), and rejects
any service in `compose.yaml` lacking one.

## Per-Containerfile spec contract

Every `services/<name>/README.md` follows this exact structure. The
section headers are matched literally by `check-containerfile-docs.sh`:

```markdown
# <service> Containerfile spec

@trace spec:enclave-compose-migration

## Purpose
One-paragraph description: what the service does, why it exists in the
enclave, what failure modes it owns.

## Base image
- Image: <e.g. registry.fedoraproject.org/fedora-minimal:41>
- Justification: <why this base, security posture, update cadence>
- Provenance: <built by Nix / pulled from registry / built from this
  Containerfile>

## Build args
| Arg | Default | Purpose |
|---|---|---|
| TILLANDSIAS_VERSION | (computed) | image tag suffix |
| ... | | |

## Layers (cache-ordered, top to bottom)
1. <package install>
2. <user creation, uid 1000>
3. <config files>
4. <entrypoint>

Each layer is annotated with: cache invalidation trigger, approximate size
contribution, security implications.

## Security posture
- Runs as uid: <1000 / specific name>
- Read-only rootfs: <yes / no — justify>
- Capabilities dropped: ALL
- Capabilities added: <list, with justification per cap>
- Network attachments: <enclave | egress | both | none>
- SELinux label: <default / custom>

## Volume contract
| Path inside | Mode | Origin | Lifetime |
|---|---|---|---|
| /home/forge/work | rw | named volume `<project>_workdir` | per-project |
| /run/secrets/tillandsias-* | ro | podman secret | ephemeral |

## Env contract
| Var | Required | Default | Purpose |
|---|---|---|---|
| PROXY_URL | yes | — | egress goes through proxy |
| ... | | | |

## Healthcheck
- Command: <exact argv>
- Interval / timeout / retries: <values>
- Definition of healthy: <prose>

## Compose service block
The exact YAML stanza in `compose.yaml` that references this service, with
line-by-line annotations of every flag.

## Trace anchors
- `@trace spec:<related-spec-id>` ...
```

## Risks / Trade-offs

1. **`podman-compose` is a non-Rust runtime dependency.** Mitigation: pinned
   version, documented bootstrap in README, preflight refusal with clear
   error message if missing.
2. **`depends_on: service_healthy` is broken.** Mitigation: keep Rust-side
   readiness probe loop.
3. **`external` secrets bugs.** Mitigation: integration test reads a known
   secret from inside the forge.
4. **`internal: true` rootless network behaviour varies by Podman version.**
   Mitigation: pin minimum Podman version in preflight; runtime test asserts
   external `curl` from forge fails.
5. **Loss of fine-grained `podman run` flag control.** Mitigation:
   `scripts/lint-compose.sh` guards the security-critical flags; for any
   flag Compose cannot express, we attach via the `command:` override or
   the per-service `cap_add` / `security_opt` fields. If we ever need a
   flag Compose flat-out cannot express, we fall back to a `tillandsias-podman`
   direct call for that service only — explicitly out-of-band.
6. **AppImage size and load time** grow slightly due to embedded YAML +
   Containerfiles. Estimated < 50 KB additional. Acceptable.

## Migration Plan

See `tasks.md` for the ordered, checkbox-driven task list. High-level phases:

- **Phase 1 — Scaffolding (tasks 1–4).** New crate, asset tree, embedded
  resources, materialization. No call-site changes yet; tests in isolation.
- **Phase 2 — Cutover (tasks 5–7).** Wire `handlers.rs` to call into
  `Compose`. Delete the dead flag-builder code in `launch.rs` and
  `runner.rs`. Keep `events.rs` and `client.rs` intact.
- **Phase 3 — Hardening (tasks 8–11).** Add lint scripts, docs check, CI
  hook, integration tests, and the multi-environment exercise.

## Open Questions

- **Profiles vs overlay files.** We've committed to overlay files
  (`compose.dev.yaml`, `compose.local.yaml`) because they make
  invocation explicit. Compose profiles would put everything in one file
  with `profiles: [prod, dev, local]` tags. Defer until after a real
  draft of the YAML; revisit if the overlay version becomes unwieldy.
- **Should `tillandsias-compose` be its own crate or a module of
  `tillandsias-podman`?** Designed as a separate crate so
  `tillandsias-podman` stays focused on the lower-level CLI client and
  events stream. Revisit if cross-crate dependencies become awkward.
- **Migration of `./run-forge-standalone.sh`** into a `--profile local`
  Compose invocation — tracked as `tasks.md` task 11, but optional and
  separately landable.
