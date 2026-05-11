# Inference Containerfile spec

@trace spec:enclave-compose-migration, spec:inference-container

> **Note**: The actual `Containerfile` referenced by this spec currently
> lives at `images/inference/Containerfile`. It will be relocated to
> `src-tauri/assets/compose/services/inference/Containerfile` as part of
> `tasks.md` task 3 in `openspec/changes/migrate-enclave-orchestration-to-compose/`.

## Purpose

The inference container runs **ollama** as the enclave's local LLM
endpoint. Forge agents call this service (not OpenAI, not Anthropic,
not any external inference API) for all model traffic that does not
specifically require a frontier model. Two small tool-capable models
are **baked into the image** (T0: `qwen2.5:0.5b`, T1: `llama3.2:3b`)
so the inference is functional with zero pulls. Larger models
(T2–T5: `qwen2.5-coder:{7b,14b,32b}`) are **lazy-pulled host-side** by
the tray after the inference container reports healthy — see
CLAUDE.md "Inference Container — Lazy Model Pulling" for the GPU-tier
mapping.

## Base image

- **Image**: `registry.fedoraproject.org/fedora-minimal:44`
- **Justification**: glibc match with the ollama upstream binary
  (the prebuilt CPU runner is glibc-linked); same base as the forge
  for SBOM consistency; `lspci` (in `pciutils`) available for the
  entrypoint's GPU detection logic.
- **Provenance**: built from this `Containerfile`; the ollama binary
  is downloaded from the upstream GitHub release at build time. We
  download only `bin/ollama` (~200 MB), skipping `lib/ollama/`
  (~1.8 GB of CUDA/ROCm GPU runners) — GPU users can volume-mount
  runner libs at runtime if needed.
- **Update cadence**: bump base image with the forge bump. Ollama
  binary is tracked by `latest` at build time; we record the resolved
  release tag in `flake.nix` for reproducibility.

## Build args

| Arg | Default | Purpose |
|---|---|---|
| (none) | — | Ollama release is fetched via `latest`; pin in `flake.nix`. |

## Layers (cache-ordered, top to bottom)

1. **Base image pull** — `FROM fedora-minimal:44`. ~75 MB.
2. **System packages** — `microdnf install bash curl ca-certificates
   zstd tar gzip pciutils`. `curl` (not wget) is the contract for
   ollama-related HTTP — Rust health checks in `handlers.rs` use
   `curl`. `zstd` decompresses the ollama release tarball.
3. **Ollama binary** — download `ollama-linux-amd64.tar.zst` from
   the upstream GitHub release, extract only `bin/ollama` to
   `/usr/local/bin/`. Verify `test -x`.
4. **User creation** — `useradd -u 1000 -m -s /bin/bash ollama`.
   Fedora-style.
5. **Model cache** — `mkdir -p /home/ollama/.ollama/models`, chown
   to 1000:1000. This is **shadowed** at runtime by a bind-mount
   from `~/.cache/tillandsias/models`, so anything baked here would
   be invisible to runtime — see layer 6.
6. **Baked models in /opt/baked-models** — pull `qwen2.5:0.5b`
   (T0, ~400 MB) and `llama3.2:3b` (T1, ~2 GB) at build time via
   `ollama serve` in the background. Stashed under
   `/opt/baked-models` NOT `/home/ollama/.ollama/models` to survive
   the runtime bind-mount. The entrypoint rsyncs from
   `/opt/baked-models` into the runtime cache on first start when
   manifests are missing. **Why baked, not pulled at runtime?**
   Squid 6.x manifests EOF hard on the large multi-MB ollama pull
   streams — see `cheatsheets/utils/project_squid_ollama_eof.md`.
   Baking at build time bypasses the proxy entirely. Larger T2–T5
   models are pulled host-side post-startup for the same reason.
7. **Entrypoint + external-logs** — `entrypoint.sh` to
   `/usr/local/bin/`; `external-logs.yaml` to `/etc/tillandsias/`.
8. **User switch + expose** — `USER 1000:1000`, `EXPOSE 11434`,
   `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`,
   `ENV HOME=/home/ollama USER=ollama`.

## Security posture

- **Runs as uid**: 1000 (user `ollama`)
- **Read-only rootfs**: no (ollama writes to
  `/home/ollama/.ollama/models` for runtime model cache; `/tmp` for
  scratch)
- **Capabilities dropped**: `ALL`
- **Capabilities added**: **none** — ollama binds to 11434
- **Network attachments**: `enclave` only. Inference makes **no**
  outbound calls in normal operation; the model pulls that DO happen
  are driven host-side by the tray (`ollama pull` via the host
  binary, bypassing the enclave entirely).
- **GPU access**: optional — when present, `--device /dev/nvidia*`
  and `--device /dev/dri/*` are passed via Compose `devices:` if
  `gpu::detect_gpu_tier()` (in tillandsias-core) returns a usable
  tier. CPU-only is the safe default.
- **SELinux label**: disabled
- **No-new-privileges**: yes
- **Userns**: `keep-id`

## Volume contract

| Path inside | Mode | Origin | Lifetime |
|---|---|---|---|
| `/home/ollama/.ollama/models` | rw | bind from `~/.cache/tillandsias/models` | per-host, persisted across all projects and tray sessions |
| `/run/secrets/tillandsias-ca-cert` | ro | podman secret | ephemeral (for HTTPS verification of the host-side pull stream when re-fetching) |

## Env contract

| Var | Required | Default | Purpose |
|---|---|---|---|
| `HOME` | yes | `/home/ollama` | set by `ENV` |
| `USER` | yes | `ollama` | set by `ENV` |
| `OLLAMA_HOST` | yes (entrypoint) | `0.0.0.0:11434` | bind address; 0.0.0.0 because the enclave is the only reachable network |
| `OLLAMA_MODELS` | no | `/home/ollama/.ollama/models` | model cache root |
| `OLLAMA_KEEP_ALIVE` | no | `5m` | how long a model stays warm in RAM after last request |
| `OLLAMA_NUM_PARALLEL` | no | `1` | concurrent model requests; bump per GPU tier |

## Healthcheck

- **Command**: `curl -fsS http://127.0.0.1:11434/api/tags || exit 1`
  (curl, not wget — see DISTRO note in Containerfile header)
- **Interval / timeout / retries**: 15 s / 3 s / 4 (slower than
  other services because the ollama server takes a few seconds to
  load the runtime if it just came up)
- **Definition of healthy**: ollama responds with a tag list (which
  is what unlocks the host-side lazy-pull task in the tray).

## Compose service block

```yaml
services:
  inference:
    image: tillandsias-inference:v${TILLANDSIAS_VERSION}
    build:
      context: ./services/inference
      dockerfile: Containerfile
    hostname: inference
    user: "1000:1000"
    cap_drop: [ALL]                       # @lint
    security_opt:
      - no-new-privileges                 # @lint
      - label=disable
    userns_mode: keep-id                  # @lint
    networks: [enclave]                   # @lint — must NOT include egress
    secrets:
      - tillandsias-ca-cert
    environment:
      OLLAMA_HOST: 0.0.0.0:11434
    volumes:
      - type: bind
        source: ${HOME}/.cache/tillandsias/models
        target: /home/ollama/.ollama/models
    expose: ["11434"]
    # GPU access (optional, gated by host detection)
    # devices:
    #   - /dev/dri/renderD128
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:11434/api/tags || exit 1"]
      interval: 15s
      timeout: 3s
      retries: 4
```

## Trace anchors

- `@trace spec:inference-container` — the service role
- `@trace spec:enclave-compose-migration` — this spec
- `@trace spec:inference-host-side-pull` — the T2–T5 lazy-pull design
- `@trace spec:zen-default-with-ollama-analysis-pool` — analysis pool integration
- `@trace spec:external-logs-layer` — `external-logs.yaml` manifest
