# Forge Containerfile spec

@trace spec:enclave-compose-migration, spec:default-image, spec:forge-offline

> **Note**: The actual `Containerfile` referenced by this spec currently
> lives at `images/default/Containerfile`. It will be relocated to
> `src-tauri/assets/compose/services/forge/Containerfile` as part of
> `tasks.md` task 3 in `openspec/changes/migrate-enclave-orchestration-to-compose/`.
> Until that move executes, this README is the documentation contract for
> the existing file in place.

## Purpose

The forge is the **untrusted coding environment**. Agents (Claude Code,
OpenCode, Codex) execute here against project source. It is the only
service in the enclave that mutates user code, and it is the only service
that hosts third-party tool execution. To compensate, it carries **zero
credentials** and has **no external network access** — code comes from
the git mirror, packages come through the proxy, inference comes from the
local ollama. If the forge is compromised, the blast radius is the
project working tree on the enclave network — no GitHub tokens, no
upstream package registries, no host filesystem.

## Base image

- **Image**: `registry.fedoraproject.org/fedora-minimal:44`
- **Justification**: glibc match with most prebuilt agent binaries
  (OpenCode, Claude Code) so they execute directly without linker
  workarounds; SELinux-ready; FHS-compliant; large CVE feed; small
  enough at ~75 MB compressed. Alpine was rejected because muslc
  breaks several prebuilt agent binaries.
- **Provenance**: production builds use Nix (`flake.nix` ::
  `forge-image`) for reproducibility; the `Containerfile` is a
  documented reference / `podman-compose build` dev fallback.
- **Update cadence**: pinned to Fedora 44 until Fedora 45 stabilises.
  Bump in a dedicated change, not in this migration.

## Build args

| Arg | Default | Purpose |
|---|---|---|
| (none) | — | Image tag is set externally to `tillandsias-forge:v<FULL_VERSION>`; no build-time args influence layer contents. |

## Layers (cache-ordered, top to bottom)

1. **Base image pull** — `FROM fedora-minimal:44`. Invalidated only by
   base bump. ~75 MB.
2. **System packages** — `microdnf install bash coreutils findutils
   grep sed gawk tar gzip xz procps-ng shadow-utils ca-certificates
   fish zsh git gh curl wget jq ripgrep nodejs npm`. Invalidated by
   package list changes. ~150 MB. **Lean by design**: terminal-UX
   tools (mc, vim, eza, bat, fd-find, fzf, htop, tree, zoxide)
   intentionally removed to save ~90 MB; users install on demand via
   the tools overlay or microdnf.
3. **User creation** — `useradd -u 1000 -m -s /bin/bash forge`.
   Fedora-style (`useradd`), NOT Alpine's `adduser -D`.
4. **Directory structure** — `/home/forge/src`,
   `/home/forge/.cache/tillandsias`, `/home/forge/.config/opencode`,
   `/tmp` (1777).
5. **Shared library** — `lib-common.sh` copied to
   `/usr/local/lib/tillandsias/`.
6. **Entrypoints** — `tillandsias-entrypoint.sh`,
   `entrypoint-forge-{opencode,opencode-web,claude,codex,terminal}.sh`
   copied to `/usr/local/bin/`, chmod +x.
7. **OpenCode config** — `opencode.json` and `tui.json` (tokyonight
   theme) copied to `/home/forge/.config/opencode/`.
8. **Shell configs** — `bashrc`, `zshrc`, `config.fish` copied to
   `/etc/skel/` and `/home/forge/.config/fish/conf.d/tillandsias.fish`.
9. **Welcome script** — `forge-welcome.sh` to
   `/usr/local/share/tillandsias/`.
10. **Locale files** — all `locales/<lang>.sh` copied to
    `/etc/tillandsias/locales/`.
11. **Ownership fix** — `chown -R 1000:1000 /home/forge`.
12. **User + WORKDIR + ENTRYPOINT** — `USER 1000:1000`,
    `WORKDIR /home/forge/src`, `ENTRYPOINT
    ["/usr/local/bin/entrypoint-forge-claude.sh"]`,
    `ENV HOME=/home/forge USER=forge`.

**No** GIT_ASKPASS helper, **no** GitHub CLI configured for auth,
**no** credentials of any kind — `@trace spec:secrets-management,
spec:forge-offline`. The git CLI is present so the agent can speak
to the enclave-internal `git://` mirror, which requires no auth.

## Security posture

- **Runs as uid**: 1000 (user `forge`)
- **Read-only rootfs**: no (forge writes to `/home/forge/.cache`,
  `/tmp`). Considered for a future hardening pass; out of scope here.
- **Capabilities dropped**: `ALL` (Compose: `cap_drop: [ALL]`)
- **Capabilities added**: **none**
- **Network attachments**: `enclave` only. Forge is **never** on
  `egress`. `scripts/lint-compose.sh` enforces this.
- **SELinux label**: disabled at run time via
  `--security-opt=label=disable` (rootless `userns=keep-id` + SELinux
  bind-mount labels do not compose cleanly on Silverblue without this).
- **No-new-privileges**: yes (`security_opt: [no-new-privileges]`)
- **Userns**: `keep-id` so file ownership in bind-mounted source
  matches the host user. See containers/podman-compose #395 for the
  `uid=`/`gid=` form on Silverblue.

## Volume contract

| Path inside container | Mode | Origin | Lifetime |
|---|---|---|---|
| `/home/forge/src/<project>` | rw | named volume `<project>_workdir` (prod) **or** host bind-mount (dev/local) | per-project |
| `/home/forge/.cache/tillandsias` | rw | named volume `<project>_cache` | per-project |
| `/home/forge/.cache/tillandsias/nix` | rw | bind from `~/.cache/tillandsias/nix` (optional, dev only) | per-host |
| `/run/secrets/*` | — | **not mounted** — forge has zero credentials | — |

## Env contract

| Var | Required | Default | Purpose |
|---|---|---|---|
| `HOME` | yes | `/home/forge` | set by `ENV` |
| `USER` | yes | `forge` | set by `ENV` |
| `HTTP_PROXY` / `HTTPS_PROXY` | prod/dev only | enclave proxy URL | injected by Compose so package managers route through Squid |
| `OLLAMA_HOST` | prod/dev only | enclave inference URL | agents talk to local ollama |
| `GIT_HTTPS_PROXY` | — | (unset) | git uses enclave git daemon directly, no proxy |
| `TILLANDSIAS_LOCALE` | no | `en` | selects which file in `/etc/tillandsias/locales/` the welcome script sources |

In the **`local` profile** (i.e. `./run-forge-standalone.sh`), proxy
and inference env vars are unset and the forge falls back to the
default rootless network for external egress.

## Healthcheck

- **Command**: `sh -c 'test -d /home/forge/src && test -f /usr/local/bin/entrypoint-forge-claude.sh'`
- **Interval / timeout / retries**: 10 s / 2 s / 3
- **Definition of healthy**: the entrypoint binary exists and the
  source mount point is present. The forge is intentionally minimal in
  what it asserts here — agent readiness is a Rust-side concern, not
  Compose's.

## Compose service block

```yaml
services:
  forge:
    image: tillandsias-forge:v${TILLANDSIAS_VERSION}
    build:
      context: ./services/forge
      dockerfile: Containerfile           # See containers/podman-compose #1312 — literal name
    hostname: forge
    user: "1000:1000"
    working_dir: /home/forge/src
    cap_drop: [ALL]                       # @lint
    security_opt:
      - no-new-privileges                 # @lint
      - label=disable
    userns_mode: keep-id                  # @lint
    networks: [enclave]                   # @lint — must NOT include egress
    environment:
      HTTP_PROXY: http://proxy:3128
      HTTPS_PROXY: http://proxy:3128
      OLLAMA_HOST: http://inference:11434
    volumes:
      - workdir:/home/forge/src/${PROJECT_ID}:rw
      - cache:/home/forge/.cache/tillandsias:rw
    healthcheck:
      test: ["CMD-SHELL", "test -d /home/forge/src && test -f /usr/local/bin/entrypoint-forge-claude.sh"]
      interval: 10s
      timeout: 2s
      retries: 3
```

Lines marked `@lint` are asserted by `scripts/lint-compose.sh`.

## Trace anchors

- `@trace spec:default-image` — the forge image itself
- `@trace spec:forge-offline` — zero credentials, no external network
- `@trace spec:enclave-network` — internal-only network attachment
- `@trace spec:enclave-compose-migration` — this spec
- `@trace spec:secrets-management` — why GIT_ASKPASS is intentionally absent
- `@trace spec:forge-shell-tools` — bash/zsh/fish + npm + ripgrep + jq baseline
