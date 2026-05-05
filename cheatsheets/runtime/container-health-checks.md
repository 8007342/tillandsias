---
tags: [container, health-check, liveness, readiness, podman, docker, supervision]
languages: [bash]
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://docs.podman.io/en/latest/markdown/podman-run.1.html
  - https://docs.docker.com/reference/dockerfile/#healthcheck
  - https://github.com/containers/podman/blob/main/docs/tutorials/healthchecks.md
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Container health checks

@trace spec:container-health, spec:wsl-daemon-orchestration
@cheatsheet runtime/event-driven-monitoring.md

**Version baseline**: Podman 4.0+, Docker 1.13+
**Use when**: implementing liveness or readiness probes in container images (Dockerfile HEALTHCHECK); detecting stuck containers; restarting unhealthy services automatically.

## Provenance

- Podman run reference (--healthcheck flag, health-check override semantics): <https://docs.podman.io/en/latest/markdown/podman-run.1.html>
- Docker HEALTHCHECK instruction (exit code semantics, interval/timeout/retries): <https://docs.docker.com/reference/dockerfile/#healthcheck>
- Podman healthchecks tutorial (lifecycle, system vs. image-defined checks, practical examples): <https://github.com/containers/podman/blob/main/docs/tutorials/healthchecks.md>
- **Last updated:** 2026-04-27

## Quick reference

| Aspect | Details |
|---|---|
| **Image-defined** | `HEALTHCHECK CMD <command>` in Dockerfile; set interval/timeout/retries as flags |
| **Runtime override** | `podman run --healthcheck-cmd='curl http://localhost:3000/health'` (overrides image) |
| **Query status** | `podman inspect <container> \| jq .State.Health` → `{Status, FailingStreak, Log}` |
| **Exit codes** | 0=healthy, 1=unhealthy, 124=command timeout (after `--healthcheck-timeout`), other=system error |
| **Probe frequency** | `--healthcheck-interval=30s` (default), minimum 1ms, maximum 1h |
| **Failure threshold** | `--healthcheck-retries=3` (default; failures needed to mark unhealthy) |
| **Timeout** | `--healthcheck-timeout=10s` (default; how long to wait for probe to return) |

## Common patterns

### Pattern 1 — Dockerfile HEALTHCHECK (HTTP)

```dockerfile
FROM fedora:44
RUN microdnf install -y curl
COPY myapp /opt/myapp
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD curl --fail http://localhost:3000/health || exit 1
```

The `--start-period=10s` flag delays health checks for 10s after container start (allows slow startup). Exit code 0 = healthy, 1 = unhealthy, 124 = timeout.

### Pattern 2 — Runtime override (different probe)

```bash
podman run -d \
  --name my-app \
  --healthcheck-cmd='bash -c "curl http://localhost:3000/metrics | grep processed"' \
  --healthcheck-interval=20s \
  --healthcheck-timeout=3s \
  --healthcheck-retries=2 \
  my-app:latest
```

Overrides any Dockerfile HEALTHCHECK. Useful for testing different probes without rebuilding the image.

### Pattern 3 — Disable health checks

```bash
podman run -d \
  --name my-app \
  --healthcheck=none \
  my-app:latest
```

Explicitly disables health checking even if the image declares a HEALTHCHECK.

### Pattern 4 — TCP socket check (no curl needed)

```dockerfile
FROM fedora:44

# In Podman 4.1+, use `podman exec` with nc/bash to test TCP without curl:
HEALTHCHECK --interval=10s --timeout=2s --retries=3 \
  CMD bash -c "timeout 1 bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/8080'" || exit 1
```

Avoids curl dependency; works for any TCP port. `<` redirect forces bash to attempt connection.

### Pattern 5 — Composite health check (multiple probes)

```dockerfile
FROM fedora:44
RUN microdnf install -y curl
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl --fail http://localhost:3000/health \
      && curl --fail http://localhost:3000/db-connection \
      && echo "OK" \
      || exit 1
```

Multiple curl commands chained with `&&`; if ANY fails, the overall exit code is 1.

## Common pitfalls

- **Infinite timeout** — if `--healthcheck-timeout` is not set in Dockerfile but the probe hangs, it blocks that check cycle. Always set a timeout less than the interval (e.g., interval=30s, timeout=5s).
- **`--start-period` not applied** — Podman doesn't recognize `--start-period` as a run-time flag; it only works in the Dockerfile HEALTHCHECK instruction. If you need a grace period, run a startup script that waits before starting the main daemon.
- **Exit code 124 not caught** — if the probe command times out (exit code 124), it counts as unhealthy immediately. Ensure probes return within the timeout window.
- **Dependent services not ready** — if a probe tries to connect to a database or API that's not yet running, the container will be marked unhealthy before dependent services start. Use `--start-period` or sleep in the startup script.
- **Probe logs not visible** — `podman inspect <container> | jq .State.Health.Log` shows the last few probe invocations with their exit codes and stderr. Check this when debugging health issues (not `podman logs`).
- **No environment variables in HEALTHCHECK** — the CMD does NOT expand `$` vars from ENV. Use `bash -c` if you need to reference env vars: `CMD bash -c 'curl http://$HOST:$PORT/health'`.
- **Health check doesn't restart the container** — Podman's health status is reported via `inspect`, but Podman doesn't auto-restart. Use `podman run --restart=always` separately. For orchestrators (k8s, compose), the orchestrator decides restart policy based on health.

## Querying health status

```bash
# Raw health state
podman inspect my-app --format '{{json .State.Health}}'

# Pretty print
podman inspect my-app | jq '.State.Health'

# Follow health logs (tail -f equivalent)
podman inspect -l --format '{{.State.Health.Log | json}}'

# Check if container is healthy
podman inspect my-app --format '{{.State.Health.Status}}'  # "healthy", "unhealthy", "starting"
```

## See also

- `runtime/event-driven-monitoring.md` — podman events API, subscribing to health-check state changes
- `runtime/systemd-socket-activation.md` — systemd readiness gates (Type=notify) as alternative to in-container health checks
- `runtime/forge-container.md` — running code inside the Tillandsias forge (no healthcheck in forge, monitored by host)
- `languages/bash.md` — bash script patterns for probe commands

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream docs exceed image size targets; health check concepts are stable across versions.
> See `cheatsheets/license-allowlist.toml` for per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

### Source

- **Upstream URL(s):**
  - `https://docs.podman.io/en/latest/markdown/podman-run.1.html`
  - `https://docs.docker.com/reference/dockerfile/#healthcheck`
  - `https://github.com/containers/podman/blob/main/docs/tutorials/healthchecks.md`
- **Archive type:** `single-html + github markdown`
- **Expected size:** `~3 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/podman-docker-healthcheck-docs/`
- **License:** Podman (Apache 2.0), Docker (CC-BY-SA), GitHub (CC-BY-SA)
- **License URL:** https://github.com/containers/podman/blob/main/LICENSE

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET_DIR="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/podman-docker-healthcheck-docs"
mkdir -p "$TARGET_DIR"
curl --fail --silent --show-error \
  "https://docs.podman.io/en/latest/markdown/podman-run.1.html" \
  -o "$TARGET_DIR/podman-run.html"
curl --fail --silent --show-error \
  "https://docs.docker.com/reference/dockerfile/#healthcheck" \
  -o "$TARGET_DIR/dockerfile-healthcheck.html"
curl --fail --silent --show-error \
  "https://raw.githubusercontent.com/containers/podman/main/docs/tutorials/healthchecks.md" \
  -o "$TARGET_DIR/healthchecks-tutorial.md"
echo "Cached to $TARGET_DIR"
```

### Generation guidelines (after pull)

1. Read the pulled files to understand Dockerfile HEALTHCHECK syntax, Podman/Docker runtime flags, and health state semantics.
2. If your project uses container health checks extensively, generate a project-contextual cheatsheet at `<project>/.tillandsias/cheatsheets/runtime/container-health-checks.md` using `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter: `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`, `committed_for_project: true`.
4. Cite the pulled sources under `## Provenance` with `local: <cache target above>`.
