---
tags: [forge, runtime, podman, troubleshooting, containers]
languages: [bash]
since: 2026-05-12
last_verified: 2026-05-12
sources:
  - https://docs.podman.io/en/latest/markdown/podman-run.1.html
  - https://docs.podman.io/en/latest/markdown/podman-build.1.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Forge Standalone Troubleshooting

@trace spec:forge-standalone, spec:default-image, spec:forge-container

**Use when**: You want only the forge container, one mounted project tree, and
an interactive bash shell for troubleshooting or in-container development.

## What it does

- Launches `tillandsias-forge:v<VERSION>` directly.
- Mounts only `--src <path>` at `/home/forge/src/<project>`.
- Drops you into bash instead of the normal agent entrypoint.
- Leaves the rest of the enclave stack out of the picture.

## Example

```bash
./run-forge-standalone.sh --src ~/src/tillandsias
```

Inside the container, the project appears at:

```bash
/home/forge/src/tillandsias
```

## Why this exists

- Keeps the troubleshooting loop small.
- Makes the forge image itself the thing under test.
- Avoids proxy/git/inference orchestration when you only want shell access.
- Lets you build or inspect the Tillandsias app from inside the same image
  family used by the real forge runtime.

## Boundaries

- No sidecar containers.
- No tray orchestration.
- No project clone from a mirror.
- No extra host mounts beyond the requested source tree.

## Litmus Chain

Use the standalone chain to separate image, runtime, and orchestration drift:

1. `./scripts/run-litmus-test.sh forge-standalone`
1. `./scripts/run-litmus-test.sh default-image`
1. `./scripts/run-litmus-test.sh direct-podman-calls`
1. `./build.sh --ci --strict --filter forge-standalone:default-image:direct-podman-calls`
1. `./build.sh --ci-full --install --strict --filter forge-standalone:default-image:direct-podman-calls:podman-orchestration`
1. `./run-forge-standalone.sh --src ../visual-chess`

## See also

- `runtime/forge-container.md`
- `build/container-image-building.md`
- `openspec/specs/forge-standalone/spec.md`
