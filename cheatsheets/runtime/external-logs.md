---
tags: [external-logs, observability, logs, forge, runtime, producers, consumers]
languages: []
since: 2026-04-26
last_verified: 2026-05-02
sources:
  - https://docs.podman.io/en/stable/markdown/podman-cp.1.html
  - https://docs.podman.io/en/stable/markdown/podman-run.1.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# External logs — cross-container observability

@trace spec:external-logs-layer
@cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md

**Use when**: you are an agent (or operator) inside a forge container and need to inspect curated log output from a sibling service container (git-service, proxy, router, inference) — without drowning in internal debug noise.

## Provenance

- Rust `include_str!()` macro (compile-time file embedding): <https://doc.rust-lang.org/std/macro.include_str.html>
- Containerfile/Dockerfile COPY instruction (build context semantics): <https://docs.podman.io/en/latest/markdown/podman-build.1.html#copy>
- rsyslog configuration and local facility semantics: <https://www.rsyslog.com/doc/master/concepts/index.html>
- Podman cp reference (streaming container files to stdout as tar, used by the tray-side auditor): <https://docs.podman.io/en/stable/markdown/podman-cp.1.html>
- Podman run reference (bind-mount semantics: `:rw`/`:ro`, the mount modes that make producer vs consumer roles possible): <https://docs.podman.io/en/stable/markdown/podman-run.1.html>
- **Last updated:** 2026-05-02

## Lifecycle: binary → tmpfs → container image

The `external-logs.yaml` manifest file for each service container follows a deterministic lifecycle:

@trace spec:cli-diagnostics, spec:default-image

1. **Compile time (embedded.rs)**: Each service's manifest is embedded as a compile-time string constant:
   - `GIT_EXTERNAL_LOGS` (git service syslog config)
   - `PROXY_EXTERNAL_LOGS` (proxy service syslog config)
   - `ROUTER_EXTERNAL_LOGS` (router service syslog config)
   - `INFERENCE_EXTERNAL_LOGS` (inference service syslog config)
   - `FORGE_EXTERNAL_LOGS` (forge container cheatsheet-telemetry producer)

2. **Runtime: extraction to tmpfs** (`write_image_sources()`):
   - At tray startup or `--init`, the binary calls `write_image_sources()`
   - Each service's tmpdir (e.g., `$XDG_RUNTIME_DIR/tillandsias/images/<service>/`) is populated
   - `external-logs.yaml` is written to tmpfs (RAM-backed, per-session) with LF normalization

3. **Build time: Containerfile COPY**:
   - When `podman build` executes the service's Containerfile:
   - `COPY external-logs.yaml /etc/tillandsias/external-logs.yaml` pulls from tmpfs → image layer
   - Critical: the file MUST exist in tmpfs; if not, the build fails immediately

4. **Container runtime: syslog integration**:
   - Service entrypoint reads `/etc/tillandsias/external-logs.yaml` (read-only from image layer)
   - Configures syslog output for each declared log file
   - Parent tray listens on syslog socket (`local1` facility) and streams to host

**Consequence**: The manifest file is never mutable and never touches disk — it lives on RAM only during the build window and on the read-only image layer thereafter. Restart a service container → same manifest (from layer). Rebuild with a new VERSION → new manifest (re-embedded, re-extracted, re-baked into image).

## The two log tiers

| Tier | What it is | Mount at producer | Mount at consumer | Queryable via |
|---|---|---|---|---|
| **INTERNAL** | All stdout/stderr + per-container `/var/log/tillandsias/` (existing) | RW at `/var/log/tillandsias/` | NOT mounted in siblings | `podman logs -f <container>` from host |
| **EXTERNAL** | Hand-curated files declared in producer's `external-logs.yaml` manifest | RW at `/var/log/tillandsias/external/` | RO at `/var/log/tillandsias/external/` (parent dir) | `tillandsias-logs ls/tail/combine` from inside forge |

**INTERNAL is read-only from forge** — the existing per-container dir is NOT mounted in forge containers. Only the producer owns it.

## Host-side layout

```
~/.local/state/tillandsias/
├── containers/<container>/logs/    # INTERNAL (per-container, RW, rotated 10 MB)
└── external-logs/                  # EXTERNAL (all producers, role-scoped)
    ├── git-service/
    │   └── git-push.log
    ├── proxy/
    │   ├── access.log
    │   └── denied.log
    ├── router/
    │   └── caddy-access.log
    └── inference/
        └── model-load.log
```

**External log identity is the service ROLE, not the ephemeral container name.** Logs survive container restarts (same host path, different container ID).

## Inside the forge container

```
/var/log/tillandsias/external/    # RO parent mount — one subdir per producer
├── git-service/
│   └── git-push.log
├── proxy/
│   ├── access.log
│   └── denied.log
├── router/
│   └── caddy-access.log
└── inference/
    └── model-load.log
```

Env var: `$TILLANDSIAS_EXTERNAL_LOGS=/var/log/tillandsias/external` (set by `lib-common.sh`).

## Quick reference

| Command | Effect |
|---|---|
| `tillandsias-logs ls` | List all roles + files with size/lines/last-write age |
| `tillandsias-logs tail git-service git-push.log` | `tail -f` with `[git-service/git-push.log]` prefix |
| `tillandsias-logs combine` | Interleave forge internal + all external logs, sorted by mtime |
| `cat $TILLANDSIAS_EXTERNAL_LOGS/git-service/git-push.log` | Direct read |
| `cat /etc/tillandsias/external-logs.yaml` | Read the producer's manifest (inside the producer container only) |

## Common patterns

### Pattern 1 — discover what's available

```bash
tillandsias-logs ls
# git-service : git-push.log (4.2K, 12 lines, last write 2s ago)
# proxy       : access.log (87K, 1240 lines, <1s ago)
#               denied.log (0B, 0 lines, never written)
```

Use this first to see which roles have published files and whether they've written recently.

### Pattern 2 — follow a specific log live

```bash
tillandsias-logs tail proxy access.log
# [proxy/access.log] 2026-04-26T10:13:01Z 12 proxy:3128/200 GET https://api.example.com/v1
```

The prefix `[role/file]` makes multi-file tailing readable. Uses `tail -f` internally, so new lines appear as the producer writes them.

### Pattern 3 — interleave everything for holistic debugging

```bash
tillandsias-logs combine
# Prefixes each line with [role/file] and sorts by modification time.
# Useful when you need to correlate a push attempt (git-service)
# with the proxy access (proxy) and the Caddy route (router) in sequence.
```

### Pattern 4 — read from the host (operator, no forge needed)

```bash
# From the host, log files are plain files:
tail -f ~/.local/state/tillandsias/external-logs/git-service/git-push.log
cat ~/.local/state/tillandsias/external-logs/proxy/denied.log
```

### Pattern 5 — confirm the manifest for a producer

```bash
# From inside the producer container (e.g., git-service):
cat /etc/tillandsias/external-logs.yaml
# Shows role name + every file the producer is permitted to write.
# Any on-disk file NOT listed here triggers a tray LEAK alarm within 60 s.

# From the host via podman cp:
podman cp tillandsias-git-myproject:/etc/tillandsias/external-logs.yaml -
# Output is a tar stream; pipe through `tar -xO` to get plain text.
```

## Auditor invariants (enforced by tray every 60 s)

| Check | What triggers | Action |
|---|---|---|
| **Manifest match** | File in role dir NOT listed in `external-logs.yaml` | WARN + accountability `[external-logs] LEAK: <role> wrote <file>` |
| **Size cap** | File > `rotate_at_mb` MB (default 10 MB) | Truncate oldest 50% in place; INFO accountability event |
| **Growth-rate** | > 1 MB/min sustained for 5 min (5 ticks) | WARN accountability `[external-logs] WARN: <role> <file> growing X MB/min` |
| **Reverse-breach** | Profile has BOTH `external_logs_role` AND `external_logs_consumer: true` | RELAXED by `cheatsheets-license-tiered`: dual-role permitted because the role-scoped RW mount sits strictly under the consumer's parent RO mount — no shadowing. Forge containers exercise this dual role (consumer of every role + producer of `cheatsheet-telemetry`). |

## Extending a producer — add a new external file

1. Add the file to the producer image's `images/<service>/external-logs.yaml`:
   ```yaml
   - name: slow-query.log
     purpose: |
       One line per query exceeding 100ms threshold.
     format: text
     rotate_at_mb: 10
     written_by: query middleware
   ```
2. Update the producer's entrypoint or middleware to write to `/var/log/tillandsias/external/<filename>`.
3. Update `cheatsheets/runtime/external-logs.md` (this file) — add the row.
4. Rebuild and redeploy the producer image. The tray auditor picks up the new manifest within 60 s.

## Common pitfalls

- **Writing a file not in the manifest** → tray chip turns yellow with LEAK alarm within 60 s. Fix: add the file to `external-logs.yaml` and redeploy.
- **File > 10 MB** → auditor silently truncates the oldest 50%. Fix: tune `rotate_at_mb` in the manifest OR write less.
- **Trying to write from the forge into an external-log dir** → the consumer mount is `:ro`. Writes fail with EROFS. Only the producer container has a writable mount.
- **Assuming the dir exists before the first producer starts** → `$TILLANDSIAS_EXTERNAL_LOGS` exists (always created at tray startup) but a role subdir only exists after the producer has been launched at least once. `tillandsias-logs ls` handles empty gracefully.
- **Adding a producer code change without updating the manifest** → the first write triggers a LEAK alarm. Always update the manifest first.

## See also

- `runtime/forge-paths-ephemeral-vs-persistent.md` — the full path taxonomy including external-logs as the fifth row
- `runtime/forge-container.md` — runtime contract; references this env var and CLI
- `runtime/local-inference.md` — inference service details
- `runtime/networking.md` — enclave network topology (proxy, git, inference)

## Producer: cheatsheet-telemetry

@trace spec:cheatsheets-license-tiered, spec:project-bootstrap-readme

`/var/log/tillandsias/external/cheatsheet-telemetry/lookups.jsonl` — one event per cheatsheet consultation by an in-forge agent (claude / opencode / opsx). The forge container is the producer; the host-side analytics in `cheatsheet-telemetry-analytics` (v2) consume the events to drive cheatsheet refresh priority.

**Forge containers are dual-role**: producer of `cheatsheet-telemetry` AND consumer of every other role. The launcher composes the two mounts so the parent RO mount lands first and the role-scoped RW mount overlays the producer's own subdirectory — the forge sees its own role at `/var/log/tillandsias/external/cheatsheet-telemetry/` RW and every other role RO at sibling paths under `/var/log/tillandsias/external/`.

| Field | Type | Meaning |
|---|---|---|
| `ts` | ISO 8601 string | Event timestamp (UTC) |
| `project` | string | Project name (matches the forge container's project) |
| `cheatsheet` | string | Relative path under `/opt/cheatsheets/` (e.g., `languages/python.md`) |
| `query` | string | What the agent looked for |
| `resolved_via` | enum | `bundled` / `distro-packaged` / `pulled` / `live-api` / `miss` |
| `pulled_url` | string \| null | Upstream URL pulled (only for `pulled` and `live-api`) |
| `chars_consumed` | int | Bytes of content the agent consumed |
| `event_type` | enum | `lookup` (default), `startup_routing`, `readme_regen`, `readme_requires_pull`, `structural_drift`, `license_drift` |
| `spec` | string | Always `"cheatsheets-license-tiered"` or `"project-bootstrap-readme"` depending on event_type |
| `accountability` | bool | Always `true` |

Example events, one per `resolved_via` value:

```json
{"ts":"2026-04-27T16:23:11Z","project":"my-app","cheatsheet":"languages/python.md","query":"asyncio cancellation semantics","resolved_via":"bundled","pulled_url":null,"chars_consumed":4823,"spec":"cheatsheets-license-tiered","accountability":true}
{"ts":"2026-04-27T16:24:02Z","project":"my-app","cheatsheet":"languages/jdk-api.md","query":"VirtualThread join","resolved_via":"distro-packaged","pulled_url":null,"chars_consumed":1280,"spec":"cheatsheets-license-tiered","accountability":true}
{"ts":"2026-04-27T16:25:18Z","project":"my-app","cheatsheet":"web/nginx.md","query":"reverse-proxy WS upgrade","resolved_via":"pulled","pulled_url":"https://nginx.org/en/docs/http/websocket.html","chars_consumed":12480,"spec":"cheatsheets-license-tiered","accountability":true}
{"ts":"2026-04-27T16:26:00Z","project":"my-app","cheatsheet":"runtime/llm-agent-protocols.md","query":"current MCP transport","resolved_via":"live-api","pulled_url":"https://modelcontextprotocol.io/spec","chars_consumed":3050,"spec":"cheatsheets-license-tiered","accountability":true}
{"ts":"2026-04-27T16:27:33Z","project":"my-app","cheatsheet":"languages/python.md","query":"asyncio.TaskGroup exception aggregation","resolved_via":"miss","pulled_url":null,"chars_consumed":4823,"spec":"cheatsheets-license-tiered","accountability":true}
```

`resolved_via = miss` is the load-bearing case: it means the agent looked at the cheatsheet, did not find what it needed, and either pulled a deeper source or queried a live API. v1 emits these events; v2 (`cheatsheet-telemetry-analytics`) aggregates them by `(cheatsheet, query)` to surface top-N misses per cheatsheet for refresh prioritisation.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — host-side path taxonomy
- `images/git/external-logs.yaml` — canonical manifest example (git-service)
- `images/default/external-logs.yaml` — forge cheatsheet-telemetry manifest
- `openspec/changes/external-logs-layer/specs/external-logs-layer/spec.md` — capability spec
- `openspec/changes/cheatsheets-license-tiered/specs/cheatsheets-license-tiered/spec.md` — cheatsheet-telemetry producer requirement
