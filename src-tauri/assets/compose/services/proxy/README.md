# Proxy Containerfile spec

@trace spec:enclave-compose-migration, spec:proxy-container, spec:reverse-proxy-internal

> **Note**: The actual `Containerfile` referenced by this spec currently
> lives at `images/proxy/Containerfile`. It will be relocated to
> `src-tauri/assets/compose/services/proxy/Containerfile` as part of
> `tasks.md` task 3 in `openspec/changes/migrate-enclave-orchestration-to-compose/`.

## Purpose

The proxy is the **sole egress point** for the enclave. Forge, git, and
inference containers have no route to the public internet; they reach
external services exclusively through this Squid MITM caching forward
proxy. It enforces an **allowlist** (`allowlist.txt`) of acceptable
upstream hosts and **caches** package-manager artifacts so a re-clone
of a project doesn't re-download identical artifacts. SSL-bump
intercepts HTTPS using the per-host CA loaded from podman secrets so
the allowlist applies to TLS traffic too.

## Base image

- **Image**: `docker.io/library/alpine:3.20`
- **Justification**: Alpine ships Squid with `--enable-ssl-crtd`
  baked in (no separate `squid-openssl` package on 3.20), and the
  total image footprint stays ~15–20 MB. The proxy does not run
  user code, so muslc has no compatibility implications here.
- **Provenance**: built from this `Containerfile` (Nix is overkill
  for a one-binary daemon); pulled at build time by
  `scripts/build-image.sh proxy`.
- **Update cadence**: pinned to Alpine 3.20; bump on the same
  cadence as upstream Squid CVE advisories.

## Build args

| Arg | Default | Purpose |
|---|---|---|
| (none) | — | All configuration is runtime via the mounted `squid.conf` template and secrets. |

## Layers (cache-ordered, top to bottom)

1. **Base image pull** — `FROM alpine:3.20`. ~7 MB.
2. **Package install** — `apk add --no-cache squid openssl bash ca-certificates`.
   `squid` includes SSL bump support; `bash` because the entrypoint
   uses `#!/bin/bash` explicitly (busybox sh would work but bash is
   the contract).
3. **User + dirs** — `adduser -D -u 1000 -s /sbin/nologin proxy`,
   create `/var/spool/squid /var/log/squid /var/run/squid /var/lib/squid /etc/squid/certs`,
   chown to `proxy:proxy`.
4. **Config templates** — `squid.conf` and `allowlist.txt` copied
   to `/etc/squid/`.
5. **Entrypoint + external-logs manifest** — `entrypoint.sh` to
   `/usr/local/bin/`; `external-logs.yaml` to `/etc/tillandsias/`.
6. **User switch + expose** — `USER proxy`, `EXPOSE 3128 3129`,
   `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`.

## Security posture

- **Runs as uid**: 1000 (user `proxy`, `/sbin/nologin` shell)
- **Read-only rootfs**: no (Squid writes to `/var/spool/squid` cache,
  `/var/log/squid`, `/var/run/squid`)
- **Capabilities dropped**: `ALL`
- **Capabilities added**: **none** — Squid binds to high ports (3128,
  3129) so it does not need `NET_BIND_SERVICE`
- **Network attachments**: `enclave` AND `egress`. **Only service**
  attached to `egress`. `scripts/lint-compose.sh` enforces this
  inversely (forge/git/inference must NOT be on egress; proxy MUST be).
- **SELinux label**: disabled (`--security-opt=label=disable`)
- **No-new-privileges**: yes
- **Userns**: `keep-id`

## Volume contract

| Path inside | Mode | Origin | Lifetime |
|---|---|---|---|
| `/var/spool/squid` | rw | named volume `<project>_proxy_cache` | per-project, persisted across restarts for HTTP cache continuity |
| `/run/secrets/tillandsias-ca-cert` | ro | podman secret | ephemeral, recreated per tray session |
| `/run/secrets/tillandsias-ca-key` | ro | podman secret | ephemeral |

## Env contract

| Var | Required | Default | Purpose |
|---|---|---|---|
| `SQUID_CACHE_DIR` | no | `/var/spool/squid` | overrides the conf-file value if set |
| `SQUID_LOG_LEVEL` | no | `1` | 0–9; default 1 keeps INFO-level access logging |
| `ALLOWLIST_PATH` | no | `/etc/squid/allowlist.txt` | absolute path to the line-delimited host allowlist |

## Healthcheck

- **Command**: `wget -q --spider http://127.0.0.1:3128/ || exit 1`
  (Alpine: busybox `wget`, not `curl`)
- **Interval / timeout / retries**: 10 s / 2 s / 3
- **Definition of healthy**: Squid accepts a connection on 3128.

## Compose service block

```yaml
services:
  proxy:
    image: tillandsias-proxy:v${TILLANDSIAS_VERSION}
    build:
      context: ./services/proxy
      dockerfile: Containerfile
    hostname: proxy
    user: "1000:1000"
    cap_drop: [ALL]                       # @lint
    security_opt:
      - no-new-privileges                 # @lint
      - label=disable
    userns_mode: keep-id                  # @lint
    networks: [enclave, egress]           # @lint — proxy ONLY may have egress
    secrets:
      - tillandsias-ca-cert
      - tillandsias-ca-key
    volumes:
      - proxy_cache:/var/spool/squid:rw
    expose: ["3128", "3129"]
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://127.0.0.1:3128/ || exit 1"]
      interval: 10s
      timeout: 2s
      retries: 3
```

## Trace anchors

- `@trace spec:proxy-container` — Squid as enclave egress
- `@trace spec:reverse-proxy-internal` — same network role, different naming era
- `@trace spec:enclave-compose-migration` — this spec
- `@trace spec:external-logs-layer` — `external-logs.yaml` manifest
- `@trace spec:secrets-management` — CA cert/key flow
