# Git Containerfile spec

@trace spec:enclave-compose-migration, spec:git-mirror-service

> **Note**: The actual `Containerfile` referenced by this spec currently
> lives at `images/git/Containerfile`. It will be relocated to
> `src-tauri/assets/compose/services/git/Containerfile` as part of
> `tasks.md` task 3 in `openspec/changes/migrate-enclave-orchestration-to-compose/`.

## Purpose

The git service is the **credentialed mirror** between the enclave and
GitHub. The forge clones and pushes over an unauthenticated
enclave-internal `git://` URL; this container holds the actual GitHub
OAuth token (read from podman secret), translates between the
internal mirror and the external GitHub remote over HTTPS, and runs
the `post-receive` hook that auto-pushes upstream after every
forge-side commit. **This is the only service that ever speaks to
GitHub.** All credentials are scoped to it.

## Base image

- **Image**: `docker.io/library/alpine:3.20`
- **Justification**: footprint ~15 MB, includes `git-daemon` for the
  internal `git://` server, includes `github-cli` (gh) for token-based
  HTTPS auth, includes `openssh-client` for SSH-key auth on remotes
  that demand it. The forge image deliberately does **not** include
  `gh` to prevent any chance of token exposure on the untrusted side.
- **Provenance**: built from this `Containerfile` by
  `scripts/build-image.sh git`.
- **Update cadence**: pin to Alpine 3.20 until git or gh upstream
  forces a bump.

## Build args

| Arg | Default | Purpose |
|---|---|---|
| (none) | — | Runtime configuration only. |

## Layers (cache-ordered, top to bottom)

1. **Base image pull** — `FROM alpine:3.20`. ~7 MB.
2. **Package install** — `apk add --no-cache git git-daemon bash
   openssh-client github-cli`. `bash` because the entrypoint script
   is bash-only; `openssh-client` for SSH remotes; `github-cli` for
   token-authenticated HTTPS pushes.
3. **User + dirs** — `adduser -D -u 1000 -s /bin/bash git`, create
   `/srv/git` (bare mirrors live here), `/var/log/git-service`,
   `/strategic` (intentionally separated workspace for strategic-mirror
   operations), chown to `git:git`.
4. **Entrypoint** — `entrypoint.sh` to `/usr/local/bin/`.
5. **post-receive hook** — `post-receive-hook.sh` to
   `/usr/local/share/git-service/` (installed by entrypoint into each
   bare mirror's `hooks/post-receive`).
6. **GIT_ASKPASS helper** — `git-askpass-tillandsias.sh` to
   `/usr/local/bin/`. Reads `/run/secrets/tillandsias-github-token`
   and writes it to stdout when git prompts for HTTPS credentials.
   **This file's existence in the forge image would be a credential
   leak vector**; it lives here only.
7. **external-logs manifest** — `external-logs.yaml` to
   `/etc/tillandsias/`.
8. **Chmod +x** on all three scripts above.
9. **User switch + expose** — `USER git`, `EXPOSE 9418` (git
   protocol), `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`.

## Security posture

- **Runs as uid**: 1000 (user `git`)
- **Read-only rootfs**: no (writes to `/srv/git/*`, `/var/log/git-service`)
- **Capabilities dropped**: `ALL`
- **Capabilities added**: **none** — git daemon binds to 9418, no
  privileged ports.
- **Network attachments**: `enclave` only. The git service must
  reach GitHub for the `post-receive` push; egress flows through the
  proxy (proxy is on both networks, git is on enclave only, git
  sees the proxy hostname on the shared enclave network and uses it
  via `HTTPS_PROXY`).
- **SELinux label**: disabled
- **No-new-privileges**: yes
- **Userns**: `keep-id`

## Volume contract

| Path inside | Mode | Origin | Lifetime |
|---|---|---|---|
| `/srv/git` | rw | named volume `<project>_git_mirrors` | per-project, persisted (bare mirror lives here) |
| `/strategic` | rw | named volume `<project>_strategic` | per-project, for strategic-mirror operations |
| `/run/secrets/tillandsias-github-token` | ro | podman secret | ephemeral, recreated per tray session |

## Env contract

| Var | Required | Default | Purpose |
|---|---|---|---|
| `GIT_ASKPASS` | yes (set by entrypoint) | `/usr/local/bin/git-askpass-tillandsias.sh` | redirects git's credential prompt to the secret-reading helper |
| `HTTPS_PROXY` | yes | `http://proxy:3128` | egress to GitHub flows through the enclave proxy |
| `HTTP_PROXY` | yes | `http://proxy:3128` | same |
| `NO_PROXY` | yes | `localhost,127.0.0.1,proxy,inference,forge` | bypass proxy for enclave-internal traffic |
| `PROJECT_GITHUB_OWNER` | per-project | (unset) | injected by tray from project config; used by entrypoint to construct the GitHub remote URL |
| `PROJECT_GITHUB_REPO` | per-project | (unset) | same |

## Healthcheck

- **Command**: `nc -z 127.0.0.1 9418` (busybox netcat — Alpine has no
  bash `/dev/tcp` redirection)
- **Interval / timeout / retries**: 10 s / 2 s / 3
- **Definition of healthy**: git-daemon is accepting connections on
  9418. Note: this does **not** validate that the GitHub remote is
  reachable; Rust-side readiness probes do that with a token-scoped
  `gh auth status` invocation.

## Compose service block

```yaml
services:
  git:
    image: tillandsias-git:v${TILLANDSIAS_VERSION}
    build:
      context: ./services/git
      dockerfile: Containerfile
    hostname: git
    user: "1000:1000"
    cap_drop: [ALL]                       # @lint
    security_opt:
      - no-new-privileges                 # @lint
      - label=disable
    userns_mode: keep-id                  # @lint
    networks: [enclave]                   # @lint — must NOT include egress
    secrets:
      - tillandsias-github-token
    environment:
      HTTPS_PROXY: http://proxy:3128
      HTTP_PROXY: http://proxy:3128
      NO_PROXY: localhost,127.0.0.1,proxy,inference,forge,git
      GIT_ASKPASS: /usr/local/bin/git-askpass-tillandsias.sh
    volumes:
      - git_mirrors:/srv/git:rw
      - strategic:/strategic:rw
    expose: ["9418"]
    healthcheck:
      test: ["CMD-SHELL", "nc -z 127.0.0.1 9418"]
      interval: 10s
      timeout: 2s
      retries: 3
```

## Trace anchors

- `@trace spec:git-mirror-service` — the service role
- `@trace spec:enclave-compose-migration` — this spec
- `@trace spec:secrets-management` — token + askpass flow
- `@trace spec:native-secrets-store` — D-Bus → podman secret bridge
- `@trace spec:external-logs-layer` — `external-logs.yaml` manifest
