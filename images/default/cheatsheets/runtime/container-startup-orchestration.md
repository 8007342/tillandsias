---
tags: [container-startup, orchestration, dependency-ordering, readiness, podman-compose, kubernetes, systemd, ansible]
languages: [yaml, ini]
since: 2026-11-07
last_verified: 2026-11-07
sources:
  - https://docs.docker.com/compose/how-tos/startup-order/
  - https://docs.docker.com/reference/cli/docker/compose/up/
  - https://github.com/containers/podman-compose/blob/main/docs/Mappings.md
  - https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
  - https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
  - https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
  - https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
  - https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
  - https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
  - https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#deployment-and-scaling-guarantees
  - https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
  - https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_strategies.html
authority: high
status: current
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
pull_recipe: see-section-pull-on-demand
---

# Container startup orchestration: how the big tools start many containers

**See also:** `enclave-startup-sequencing.md` (our current order), `container-health-checks.md`.

**Use when:** deciding how the enclave (proxy, vault, router, git, inference,
forge) is brought up on a small host, a QLC NVMe, or a VZ guest; replacing a
fixed sleep with a readiness check; choosing a concurrency limit.

## The shared pattern

Every mature tool separates two questions, and the defaults are rarely what a
small host needs:

1. **Ordering** (A starts after B) is not **readiness** (B can serve). An order
   edge alone starts A the moment B's process exists.
2. **Concurrency** defaults to "as much as possible". Serialisation is opt-in
   everywhere except image pulls in Kubernetes.

| Tool | Ordering | Readiness gate | Concurrency default | Knob |
|---|---|---|---|---|
| docker compose | `depends_on` | `condition: service_healthy` (HEALTHCHECK) / `service_completed_successfully` | unlimited parallel | `--parallel N` / `COMPOSE_PARALLEL_LIMIT` |
| podman-compose | `depends_on` | `service_healthy` supported in recent releases; older ones order only | sequential-ish per dependency layer | none documented |
| Quadlet / systemd | `After=` + `Requires=`/`Wants=` | `Notify=healthy` (unit is up when the HEALTHCHECK passes), `Type=notify` | parallel once ordering allows | `StartupIOWeight=`, `IODeviceLatencyTargetSec=`, `RestartSteps=`/`RestartMaxDelaySec=` |
| Kubernetes | init containers run strictly one after another; StatefulSet `OrderedReady` | `startupProbe` gates liveness/readiness; `minReadySeconds` settle | pods parallel; **image pulls serial** | `serializeImagePulls: true` (default), `maxParallelImagePulls`, eviction thresholds |
| Ansible | task order | `wait_for` / `until:` retries | `forks: 5` | `serial:` waves, `throttle:` per task |

## What each one teaches

- **Readiness is a check, not a sleep.** Compose, Quadlet and Kubernetes all
  gate on a probe. A fixed sleep is either too short under load (the dependent
  races the dependency) or too long when idle.
- **Order edges and requirement edges are different** (systemd): `After=`
  orders; `Requires=` propagates failure; `Wants=` is a soft dependency whose
  failure does not stop the dependent. An optional service (local inference)
  belongs on a soft edge.
- **Heavy I/O is serialised by default where it hurts most**: kubelet pulls
  one image at a time unless told otherwise; the containers/storage layer lock
  already serialises layer commits within one store.
- **Settle before declaring ready**: `minReadySeconds` (k8s) and a startup
  probe's `initialDelaySeconds`/`failureThreshold` give a fresh service time
  without counting it healthy at the first answer.
- **Waves, not a flood** (Ansible `serial`, StatefulSet `OrderedReady`): the
  next unit starts after the previous wave is ready.
- **Backoff on restart** (systemd `RestartSteps`, k8s CrashLoopBackOff): a
  failing start must not retry at full speed against a saturated disk.
- **Shutdown in reverse order** (systemd stops in the reverse of `After=`;
  StatefulSet terminates highest ordinal first).
- **Per-step deadlines**: probes have `timeoutSeconds` × `failureThreshold`;
  systemd has `TimeoutStartSec=`. A whole-bringup deadline hides which step hung.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: several upstream doc sites; the summary above carries the claims used here.
> See `cheatsheets/license-allowlist.toml` for per-domain authority.

### Source

- **Upstream URL(s):**
  - `https://docs.docker.com/compose/how-tos/startup-order/`
  - `https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html`
  - `https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/`
- **Archive type:** `single-html`
- **Expected size:** `~2 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/startup-orchestration-docs/`
- **License:** vendor documentation licences (see each site)
- **License URL:** see each upstream URL

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET_DIR="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/startup-orchestration-docs"
mkdir -p "$TARGET_DIR"
curl --fail --silent --show-error -L "https://docs.docker.com/compose/how-tos/startup-order/" -o "$TARGET_DIR/0.html"
curl --fail --silent --show-error -L "https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html" -o "$TARGET_DIR/1.html"
curl --fail --silent --show-error -L "https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/" -o "$TARGET_DIR/2.html"
```

### Generation guidelines (after pull)

1. Read the pulled files for the exact option names and defaults cited above.
2. If your project needs a project-specific version, generate it at `<project>/.tillandsias/cheatsheets/runtime/container-startup-orchestration.md` using `cheatsheets/TEMPLATE.md`.
3. The generated cheatsheet MUST set frontmatter: `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`, `committed_for_project: true`.
4. Cite the pulled sources under `## Provenance` with `local: <cache target above>`.

## Provenance

Retrieved 2026-11-07 by research agents at the operator's request ("let's take a
look and investigation at how podman-compose, docker-compose, and solutions
like kubernetes and ansible deal with starting a bunch of containers").
All URLs in `sources` are primary vendor/project documentation. The table's
"podman-compose" row is the weakest claim (its docs are sparse; behaviour
read from the project's mapping notes) — re-verify before relying on it.
