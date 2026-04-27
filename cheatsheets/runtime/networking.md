---
tags: [forge, networking, enclave, proxy, squid, git, ollama, dns]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://docs.podman.io/en/latest/markdown/podman-network.1.html
  - https://www.squid-cache.org/Doc/config/
  - https://github.com/8007342/tillandsias/blob/main/images/default/Containerfile
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Forge networking — enclave layout

@trace spec:agent-cheatsheets

## Provenance

- Podman network reference (enclave network model, container DNS by name): <https://docs.podman.io/en/latest/markdown/podman-network.1.html>
- Squid configuration reference (proxy env vars `HTTPS_PROXY`, `NO_PROXY`, `SSL_CERT_FILE`): <https://www.squid-cache.org/Doc/config/>
- Tillandsias forge Containerfile (entrypoint, env var exports): <https://github.com/8007342/tillandsias/blob/main/images/default/Containerfile>
- **Last updated:** 2026-04-25

**Version baseline**: Tillandsias 0.1.169.x enclave (proxy / git-service / inference / router / forge)
**Use when**: anything that wants to make a network call from inside the forge.

## Quick reference

| Destination | Address inside enclave | Auth | Notes |
|---|---|---|---|
| HTTP/S egress (proxy) | `proxy:3128` (HTTP CONNECT) | none | Squid; CA bundled in `/etc/ssl/certs/`. Domain allowlist applies. |
| Git mirror (this project) | `git://git-service/<project>` | none | Clones/pushes hit this, NOT `github.com` directly. The git service container is the one with the GitHub token. |
| Local LLM inference | `http://inference:11434` | none | Ollama. T0 + T1 models pre-baked. |
| Other containers in same enclave | `<container-name>:<port>` | per-service | One enclave network per project. |
| Direct internet | **no route** | — | Calls bypassing the proxy fail. |

| Env var | Effect | Already set? |
|---|---|---|
| `HTTPS_PROXY` | makes most clients (curl, pip, npm, gh) tunnel through Squid | yes (set by entrypoint) |
| `HTTP_PROXY` | same for plain HTTP | yes |
| `NO_PROXY` | bypass list — `localhost,127.0.0.1,inference,git-service,proxy` | yes |
| `SSL_CERT_FILE` | system CA bundle path | yes (`/etc/ssl/certs/ca-bundle.crt`) |
| `NIX_SSL_CERT_FILE` | same, for Nix-built tools | yes |

## Common patterns

### Pattern 1 — clone or push to your project's git

```bash
# Already configured by entrypoint — git remote 'origin' points at the mirror.
git push                                   # → git-service → GitHub (token lives there, not here)
git pull
git clone git://git-service/<other-project>  # other projects in this tray session, if any
```

The mirror is THE only git endpoint the forge can reach. `github.com` over https is reachable via the proxy too (for `gh api` etc.) but NOT for git operations on this project.

### Pattern 2 — fetch something via HTTPS through the proxy

```bash
# curl, wget, gh, pip, npm — all already proxy-aware via env vars.
curl -fsSL https://example.com/data.json -o /tmp/data.json
gh api /repos/owner/repo                 # uses HTTPS_PROXY automatically
pip install --no-deps requests           # if you've already created a per-project venv
```

If a tool isn't picking up `HTTPS_PROXY`, it usually has its own knob — `npm config set proxy`, `cargo` reads `$http_proxy`, `git` reads `http.proxy` from config (already set globally).

### Pattern 3 — call the local inference

```bash
curl -s http://inference:11434/api/tags                    # list models
curl -s http://inference:11434/api/generate -d '{
  "model": "qwen2.5:0.5b",
  "prompt": "hello",
  "stream": false
}' | jq .response
```

Inference is fully isolated — no auth, no rate limit, no internet round-trip.

### Pattern 4 — listen on a port (for an HTTP server)

```bash
# bind only to enclave-reachable interfaces; other containers can reach you by name
node server.js --host 0.0.0.0 --port 3001
```

Ports `3000–3099/tcp` are exposed in the image. Lower ports (< 1024) are blocked for unprivileged users in rootless podman.

### Pattern 5 — debug DNS / connectivity

```bash
getent hosts inference                   # should resolve
getent hosts proxy                       # should resolve
nc -zv proxy 3128                        # should succeed
echo "GET / HTTP/1.0\r\n\r\n" | nc proxy 3128  # poke the proxy directly
```

`nc` and `bind-utils` (`dig`, `host`) are baked in. Use them before assuming the network is broken.

## Common pitfalls

- **Direct calls to `github.com`** — bypass the proxy, will hang or fail. Use `gh` (env-var-aware) or pipe through `curl --proxy`.
- **Assuming the forge can reach the host** — it cannot. The host's loopback (`127.0.0.1`) is the **forge's** loopback inside the container. The host filesystem is not bind-mounted (except the project workspace).
- **Using HTTPS without `SSL_CERT_FILE`** — Squid intercepts TLS and re-signs with its own CA. Tools that hard-code `/etc/ssl/cert.pem` (macOS-style) need `SSL_CERT_FILE` pointed at `/etc/ssl/certs/ca-bundle.crt`. Already exported by the entrypoint, but project-local scripts that source isolated env may need to forward it.
- **Long-running curl through the proxy** — Squid 6 has been known to EOF long-lived streams (e.g., `ollama pull` of large models). Workaround: pre-pull on the host and let the inference container seed from `/opt/baked-models/`. See `project_squid_ollama_eof.md` (host memory).
- **`pip install` from PyPI failing** — usually a missing `--proxy` env var picked up. Verify: `env | rg -i proxy`. If the proxy is reachable but PyPI is denied, the proxy's domain allowlist rejected it — write a `RUNTIME_LIMITATIONS_NNN.md` asking for the domain to be allowlisted.
- **Calling `localhost:<port>` from another forge** — different forge containers share the enclave network but each has its own loopback. Use `<container-name>:<port>` instead.
- **Trying to use SSH to push to GitHub** — you don't have an SSH key in the forge. The git push path is the mirror, not your account's SSH access. If you need a one-off direct GitHub push (e.g., admin task), it has to happen on the host.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://docs.podman.io/en/latest/markdown/podman-network.1.html`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.podman.io/en/latest/markdown/podman-network.1.html`
- **License:** see-license-allowlist
- **License URL:** https://docs.podman.io/en/latest/markdown/podman-network.1.html

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.podman.io/en/latest/markdown/podman-network.1.html"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://docs.podman.io/en/latest/markdown/podman-network.1.html" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/runtime/networking.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `runtime/forge-container.md` — the broader runtime contract
- `utils/curl.md` — curl flags including proxy specifics
- `utils/gh.md` — GitHub CLI when you do need to call the API
