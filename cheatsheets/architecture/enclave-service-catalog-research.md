---
tags: [architecture, enclave, service-catalog, mcp, caddy, localhost, podman, sigstore, allowlist]
languages: [bash, json, toml, caddyfile]
since: 2026-07-15
last_verified: 2026-07-15
sources:
  - https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
  - https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices
  - https://www.w3.org/TR/secure-contexts/
  - https://caddyserver.com/docs/automatic-https
  - https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md
  - https://docs.sigstore.dev/cosign/verifying/verify/
  - https://kyverno.io/docs/policy-types/cluster-policy/verify-images/overview/
authority: high
status: current
tier: bundled
summary_generated_by: "claude-opus-4-8 service-catalog research"
bundled_into_image: true
committed_for_project: true
---
# Enclave Service Catalog — External Research

@trace spec:subdomain-routing-via-reverse-proxy

**Use when**: designing or reviewing the enclave service catalog milestone —
forge agents requesting hand-curated sibling containers (WEB / SCIENTIFIC /
BIOLOGY TECH / STORAGE) from the host binary, served at
`https://www.<project>.localhost` through the Caddy router on rootless Podman.

All external claims below carry a source URL, **retrieved 2026-07-15** unless
noted otherwise.

## 1. MCP server practice

### Spec status

- **Current stable protocol revision: `2025-11-25`.** Versions are `YYYY-MM-DD`
  strings bumped only on backwards-incompatible change.
  <https://modelcontextprotocol.io/specification/versioning>
- **Next revision `2026-07-28` is a Release Candidate** (not final as of
  2026-07-15): stateless core, Extensions framework, Tasks, MCP Apps,
  authorization hardening; removes the initialize handshake and protocol-level
  `Mcp-Session-Id`.
  <https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/>
- Build against 2025-11-25; track the RC but don't depend on it yet.

### Transports: stdio vs Streamable HTTP

Source: <https://modelcontextprotocol.io/specification/2025-11-25/basic/transports>

- Two standard transports: **stdio** and **Streamable HTTP**. The spec:
  "Clients **SHOULD** support stdio whenever possible."
- **Streamable HTTP replaced the legacy HTTP+SSE transport** (from revision
  `2024-11-05`) starting with revision `2025-03-26`. Do not build new HTTP+SSE
  servers.
- **Recommendation for locally-hosted tool servers: stdio.** The Security Best
  Practices "Local MCP Server Compromise" section says local servers SHOULD
  use stdio to limit access to just the MCP client; if HTTP is used, restrict
  access (auth token / unix socket), validate the `Origin` header (403 on
  invalid), and bind only to `127.0.0.1` (DNS-rebinding defence).
  <https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices>

For Tillandsias: the catalog tool surface exposed to forge agents should be a
**stdio MCP server** launched inside the forge that talks to the host binary
over the existing enclave channel — the privileged action (spawning sibling
containers) is decided host-side, never by the in-container server.

### Client configuration matrix (we must serve all four)

| Client | Config file | Top-level key | stdio shape | remote shape | Selector |
|---|---|---|---|---|---|
| OpenCode | `opencode.json` (project root) or `~/.config/opencode/opencode.json` | `mcp` | `"type":"local"`, `command` **array**, `environment` | `"type":"remote"`, `url`, `headers` | explicit `type: local\|remote` |
| Claude Code | `.mcp.json` (project scope); `~/.claude.json` (local/user scopes) | `mcpServers` | `command` + `args` + `env` (no `type` ⇒ stdio) | `"type":"http"` (alias `streamable-http`), `url`, `headers` | `type` field |
| Codex CLI | `~/.codex/config.toml` (or `.codex/config.toml`) | `[mcp_servers.<name>]` | `command`, `args`, `env` | `url`, `bearer_token_env_var` | key presence (`command` vs `url`) |
| Google Antigravity | `~/.gemini/config/mcp_config.json` (shared IDE+CLI) | `mcpServers` | `command` + `args` + `env` | **`serverUrl`** (not `url`) + `headers` | key presence |

Sources: OpenCode <https://opencode.ai/docs/mcp-servers/>; Claude Code
<https://code.claude.com/docs/en/mcp>; Codex
<https://developers.openai.com/codex/mcp>; Antigravity
<https://github.com/github/github-mcp-server/blob/main/docs/installation-guides/install-antigravity.md>
and <https://codelabs.developers.google.com/google-workspace-mcp-antigravity>.

Gotchas worth encoding in the config generator:

- Claude Code: a `url` entry with **no `type`** is treated as stdio and
  skipped with an error — always emit `"type": "http"`.
  <https://code.claude.com/docs/en/mcp>
- Claude Code project-scoped `.mcp.json` servers require a one-time user
  approval prompt.
- OpenCode's `command` is an **array**; the env map is `environment`, not
  `env`.
- Antigravity's remote key is `serverUrl` — corroborated by GitHub's official
  install guide but not re-verified against first-party Google docs; verify
  against the live app before shipping (flagged 2026-07-15).

### Security for privileged host actions

Source: <https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices>

- **Confused deputy**: MCP proxies with a static downstream client ID + dynamic
  client registration let attackers ride cached consent. Mitigation (MUST):
  per-client consent on the trusted side before any downstream action; exact
  `redirect_uri` matching; single-use `state`.
- **Token passthrough is forbidden**: "MCP servers MUST NOT accept any tokens
  that were not explicitly issued for the MCP server." Applied here: the forge
  never presents credentials that the host would forward; the host authorizes
  by *which enclave* is asking, not by anything the agent supplies.
- **Allowlist on the trusted side / least privilege**: never treat
  agent-claimed scope as sufficient; server-side (host-side) authorization
  logic decides. Minimal scopes, no omnibus scopes.
- **Human-in-the-loop for dangerous local actions**: clients MUST show the
  exact command and require explicit approval before executing dangerous
  operations; servers should be sandboxed with least privilege.
- Fit with existing repo posture: this is the same shape as the enclave proxy
  exemption pattern (orders 116/118/119) — every privileged path explicitly
  authorized host-side; the agent only sends an intent ("give me `WEB`"),
  never a mechanism.

## 2. HTTPS for `*.localhost` dev domains

### Resolution and secure-context semantics

- **RFC 6761**: resolvers SHOULD treat `localhost` names as special, always
  return loopback, and never forward them to DNS.
  <https://datatracker.ietf.org/doc/html/rfc6761>
- **Chrome/Chromium**: resolves `localhost` and any `*.localhost` subdomain to
  loopback with **no /etc/hosts entry**, hardcoded (even overriding hosts-file
  entries — tracker-level claim). <https://issues.chromium.org/issues/41175806>
- **Firefox**: hardcodes `localhost` and `*.localhost` to loopback **since
  Firefox 84** (bug 1220810, "let-localhost-be-localhost"); no pref needed.
  Pre-84 Firefox sent `foo.localhost` to the OS resolver — the historical
  gotcha. <https://bugzilla.mozilla.org/show_bug.cgi?id=1220810>
- **Secure context over plain HTTP**: the W3C Secure Contexts algorithm marks
  `localhost`, `*.localhost`, `127.0.0.0/8`, and `::1` as *potentially
  trustworthy* — service workers and other gated APIs work over
  `http://foo.localhost`. <https://www.w3.org/TR/secure-contexts/> and
  <https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts>

This validates the current router design (`images/router/base.Caddyfile`
`auto_https off`, plain HTTP on `*.localhost`): browsers already treat these
origins as secure.

### When HTTPS still matters on localhost

- **Mixed content**: an `https://` page loading `http://` subresources gets
  blocked/upgraded — HTTPS must be end-to-end once any page is HTTPS.
  Firefox 84+ exempts `http://*.localhost` subresources (loopback).
  <https://developer.mozilla.org/en-US/docs/Web/Security/Mixed_content>
- **OAuth redirect URIs**: RFC 8252 permits plain-`http` **loopback** redirects
  for native apps, but many hosted providers require `https` for anything that
  looks like a hostname — the main reason a `*.localhost` catalog service
  might need real TLS. <https://datatracker.ietf.org/doc/html/rfc8252>
- **HSTS** is only honored over HTTPS.
  <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Strict-Transport-Security>
- **Cookies**: `SameSite=None` requires `Secure`; Chrome special-cases
  localhost as secure, but faithful reproduction of production cross-site
  cookie behavior needs HTTPS.
  <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie>

### If/when we do TLS: Caddy internal CA vs mkcert

- **Caddy `local_certs` / `tls internal`**: Caddy issues per-hostname certs
  from its own internal CA ("Caddy Local Authority"); on first use it attempts
  to install the root into the system trust store; `caddy trust` does it
  manually. On Linux the root lands at
  `~/.local/share/caddy/pki/authorities/local/root.crt`. **On-demand TLS**
  issues certs at first handshake, covering arbitrary
  `www.<project>.localhost` names without pre-enumeration (wildcard-ish).
  <https://caddyserver.com/docs/automatic-https> and
  <https://caddyserver.com/docs/caddyfile/directives/tls>
- **mkcert** (FiloSottile): `mkcert -install` creates a local CA and installs
  it into system + NSS (Firefox/Chromium) stores; supports wildcard certs like
  `*.example.com`. Good standalone alternative, but a second CA to manage.
  <https://github.com/FiloSottile/mkcert>
- Trust-store caveat: since the router runs Caddy **in a container**, the
  internal CA root must be exported from the container and installed on the
  host (`update-ca-certificates` / `trust anchor` on Fedora) plus NSS for
  Firefox — `caddy trust` inside the container cannot reach host stores.

**Recommendation**: keep plain HTTP on `*.localhost` (current design) as the
default; add an opt-in `tls internal` + on-demand mode only when a catalog
service hits the OAuth/mixed-content/HSTS cases above.

## 3. Curated catalog candidates

(retrieved 2026-07-15; sizes are approximate compressed pull sizes for
linux/amd64 and drift with releases)

### WEB — static + debug

| Image | Registry path | Approx size | Provenance | License |
|---|---|---|---|---|
| busybox httpd | `docker.io/library/busybox` | ~1-5 MB (most tags <900 KB compressed) | Docker Official Image | busybox is GPLv2 |
| caddy (alpine) | `docker.io/library/caddy:alpine` | ~45-50 MB | Docker Official / Caddy sponsor | Apache-2.0 |
| nginx (alpine) | `docker.io/library/nginx:alpine` | ~20-25 MB | Docker Official Image | 2-clause BSD |
| lighttpd | (no Docker Official image; 3rd-party e.g. `jitesoft/lighttpd`) | ~5-10 MB alpine-based | community | lighttpd is BSD |
| php-apache | `docker.io/library/php:8.4-apache` (Debian) | ~110-130 MB | Docker Official Image | PHP License |

Sources: busybox <https://hub.docker.com/_/busybox> (Docker blog on sizes
<https://www.docker.com/blog/use-cases-and-tips-for-using-the-busybox-docker-official-image/>);
caddy <https://hub.docker.com/_/caddy>; nginx <https://hub.docker.com/_/nginx>;
php <https://hub.docker.com/_/php>. Alpine base ~5 MB
<https://hub.docker.com/_/alpine>. Retrieved 2026-07-14.

Behind the Tillandsias Caddy router (already terminating `*.localhost` and
proxying), the sibling only needs to serve plain HTTP on an internal port — TLS
is the router's job, so the sibling's own TLS behavior is irrelevant. That
makes **smallest + simplest** the deciding factor.

- **busybox httpd** is the smallest (single static binary, ~1-5 MB) and serves
  a static docroot with one flag (`httpd -f -p 80 -h /www`) — ideal for the
  static/debug tier.
- **caddy:alpine** is bigger but is the same server the router already uses and
  has clean `file_server` + `reverse_proxy` semantics if a sibling itself needs
  to proxy.
- **nginx:alpine** sits between them and is the most familiar for classic
  static hosting.

**Recommendation — WEB static**: PRIMARY `busybox` (smallest, trivial static
serving behind the router); ALTERNATE `nginx:alpine` (familiar, still tiny,
better directory/MIME defaults than busybox httpd). For classic PHP apps,
`php:8.4-apache` (Docker Official) is the debug-friendly primary.

### WEB-APP — WordPress + MariaDB

| Image | Registry path | Approx size | Provenance | License |
|---|---|---|---|---|
| WordPress | `docker.io/library/wordpress` (apache + fpm + alpine variants) | ~250-260 MB (php8.x-fpm) | Docker Official Image (docker-library) | GPLv2 (WordPress) |
| MariaDB | `docker.io/library/mariadb` | ~110-130 MB | Docker Official Image | GPLv2 (server) |

Sources: <https://hub.docker.com/_/wordpress>, <https://hub.docker.com/_/mariadb>.
Retrieved 2026-07-14.

- **Required WordPress env**: `WORDPRESS_DB_HOST`, `WORDPRESS_DB_USER`,
  `WORDPRESS_DB_PASSWORD`, `WORDPRESS_DB_NAME` (`_FILE` suffixes read secrets
  from files — preferable to inline env for the catalog).
  <https://hub.docker.com/_/wordpress>
- **MariaDB env**: `MARIADB_ROOT_PASSWORD` (or `_FILE`), `MARIADB_DATABASE`,
  `MARIADB_USER`, `MARIADB_PASSWORD`. <https://hub.docker.com/_/mariadb>
- **Rootless Podman notes**: bind-mount volumes appear inside the user
  namespace owned by root; mount `wp-content` with `:Z` (SELinux relabel on
  Fedora) and reconcile UID/GID via the rootless user namespace. Dev flow is
  typically a bind-mounted `./wp-content:/var/www/html/wp-content:Z` so edits
  show on the host (e.g. an `inat-observations-wp`-style project bind-mounts
  its theme/plugins). Sources:
  <https://oneuptime.com/blog/post/2026-03-18-run-wordpress-podman-container/view>,
  <https://www.lisenet.com/2022/ex180-series-deploying-a-rootless-multi-container-wordpress-application-with-podman/>.
  Retrieved 2026-07-14.

**Recommendation — WEB-APP**: PRIMARY WordPress official (`wordpress`) +
MariaDB official (`mariadb`) run as a two-container pod, secrets via `_FILE`
env, `wp-content` bind-mounted `:Z` for dev; ALTERNATE `wordpress` + `mysql:8`
(the image's own compose example uses MySQL) if a project needs MySQL-specific
behavior.

### SCIENTIFIC — R / notebooks / modeling

(sub-research retrieved 2026-07-14)

| Image | Registry | ~Size | Maintenance / provenance | License |
|---|---|---|---|---|
| jupyter minimal-notebook | `quay.io/jupyter/minimal-notebook` (Docker Hub org deprecated post-2023 migration) | ~500–600 MB (verify on tag list before pinning) | Project Jupyter, actively maintained, dated tags, multi-arch ([docs](https://jupyter-docker-stacks.readthedocs.io/en/latest/using/running.html)) | BSD-3-Clause ([LICENSE](https://github.com/jupyter/docker-stacks/blob/main/LICENSE.md)) |
| rocker/rstudio | `docker.io/rocker/rstudio` | ~813 MB | Rocker Project (de-facto official R org), ~10k pulls/week, built from [rocker-versioned2](https://github.com/rocker-org/rocker-versioned2) | GPL-2+ scripts; RStudio Server is AGPL-3 |
| rocker/r2u | `docker.io/rocker/r2u` | ~338 MB | Rocker + Eddelbuettel's [r2u](https://github.com/eddelbuettel/r2u); binary CRAN installs (~31k pkgs) | GPL family |

Rootless notes: minimal-notebook has the cleanest story — designed for
arbitrary UIDs; documented invocation `--user $uid:$gid --userns
keep-id:uid=$uid,gid=$gid` keeps bind-mounted work host-owned. rocker/rstudio
needs `-u root` (its `/init` starts the server) + `--userns=keep-id:uid=1000,gid=1000`
+ `--security-opt label=disable` on SELinux hosts; Docker-style USERID/GROUPID
env vars are no-ops under Podman ([recipe](https://seergidev.github.io/posts/rstudio_podman_post/rstudio_podman_post.html)).

**PRIMARY: `quay.io/jupyter/minimal-notebook`** (cleanest rootless, BSD-3,
official Jupyter, dated tags). **ALTERNATE: `rocker/rstudio`** when the
workflow is R+IDE (accept AGPL RStudio + the keep-id recipe); `rocker/r2u`
as the headless R building block.

### BIOLOGY TECH — bioinformatics

(sub-research retrieved 2026-07-15)

| Image | Registry | ~Size | Maintenance / provenance | License |
|---|---|---|---|---|
| Bioconda per-tool ("mulled") | `quay.io/biocontainers/<tool>` (e.g. [samtools](https://quay.io/repository/biocontainers/samtools), bcftools) | low tens of MB | HIGH — auto-built from [Bioconda](https://bioconda.github.io/recipes/samtools/README.html) on merge; immutable version+build-string tags | per-tool upstream (samtools/bcftools MIT) |
| Bioconductor | `docker.io/bioconductor/bioconductor_docker:RELEASE_X_Y` | ~1.49 GB | HIGH — official, built on rocker/rstudio, rebuilt per release ([docs](https://www.bioconductor.org/help/docker/)) | Artistic-2.0; bundles AGPL-3 RStudio |
| BioContainers base | `docker.io/biocontainers/biocontainers` | ~67 MB | LOW — base only, ~2yr stale, superseded by per-tool | Apache-2.0 |

Rootless notes: Bioconda per-tool images are run-to-completion CLI tools —
no daemon, no ports, trivially rootless, immutable tags = reproducible.
Bioconductor needs `--userns=keep-id` + `:Z` for its uid-1000 `rstudio`
user on bind mounts.

**PRIMARY: `quay.io/biocontainers/<tool>`** (tiny, automated provenance,
version-pinned, cleanest rootless). **ALTERNATE: `bioconductor/bioconductor_docker`**
for R/Bioconductor+RStudio workflows (accept ~1.5 GB + AGPL RStudio).
Avoid the stale `biocontainers/biocontainers` base except as a build base.

### STORAGE — files / objects / sync

(sub-research retrieved 2026-07-15)

| Image | Registry | ~Size | Maintenance / provenance | License |
|---|---|---|---|---|
| NextCloud | `docker.io/library/nextcloud:apache` (or `:fpm-alpine` ~326 MB) | ~503 MB apache | Docker Official Image, community-maintained ([nextcloud/docker](https://github.com/nextcloud/docker)), tracks current releases | AGPLv3 |
| MinIO | `minio/minio` | ~57 MB | **RED FLAG: Docker Hub repo Archived, no updates since ~Oct 2025** — pin a digest + track CVEs yourself | AGPLv3 (since 2021) |
| WebDAV (nginx-dav-ext) | `dgraziotin/nginx-webdav-nononsense` | tens of MB | community, maintained; Alpine-nginx, real WebDAV client compat | nginx BSD-2 + MIT wrapper |

Rootless notes: NextCloud runs as `www-data` (uid 33) with deliberately
group-writable `/var/www` so an arbitrary runtime uid works — use `:U` on
bind mounts (or `podman unshare chown -R 33:33`). NextCloud needs a
MariaDB/PostgreSQL sidecar for anything beyond SQLite smoke tests, and
`NEXTCLOUD_TRUSTED_DOMAINS` must include `www.<project>.localhost` or it
rejects the host.

**PRIMARY: `docker.io/library/nextcloud:apache`** (genuine Official Image,
active, rich file/sync/share; `:apache` = single container, `:fpm-alpine`
= lean behind nginx). **ALTERNATE for object storage:** MinIO — tiny and
trivially rootless, but ONLY digest-pinned with your own CVE monitoring
given the archival; consider SeaweedFS/Garage if freshness matters. For a
dumb WebDAV drop prefer the nginx-dav-ext image over the 7-yr-stale
`bytemark/webdav`.

## 4. Allowlisted container catalogs — prior art

### Kubernetes admission (the heavyweight end)

- **ImagePolicyWebhook**: built-in validating admission controller delegating
  allow/deny on images to an external webhook (`ImageReview` objects).
  <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/>
- **ValidatingAdmissionPolicy (CEL)**: GA in Kubernetes 1.30; in-process CEL
  rules (e.g. `image.startsWith(allowedPrefix)`) with parameter ConfigMaps —
  the modern registry-allowlist mechanism without webhooks.
  <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>
- **OPA/Gatekeeper `K8sAllowedRepos`**: Rego constraint requiring image
  prefixes from a list (append `/` to prefixes to prevent bypass).
  <https://open-policy-agent.github.io/gatekeeper-library/website/validation/allowedrepos/>
- **Kyverno `verifyImages`**: Cosign-backed signature/attestation verification;
  `mutateDigest: true` rewrites tags to digests, `verifyDigest: true` requires
  digest references ("prevents spoofing"), `required: true` makes verification
  mandatory. <https://kyverno.io/docs/policy-types/cluster-policy/verify-images/overview/>

### Podman-native (the mechanism that fits us)

- **`containers-policy.json(5)`**: the signature policy consumed by
  Podman/Buildah/Skopeo. "It is *strongly* recommended to set the `default`
  policy to `reject`, and then selectively allow individual transports and
  scopes." Most-specific scope wins; anything unmatched is rejected — this
  alone restricts pulls to the allowlisted registries/repos.
  <https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md>
- **`sigstoreSigned`** policy type: pin a public key (`keyPath`/`keyData`) or
  keyless identity (`fulcio` issuer + subject, optional Rekor requirement) per
  registry scope. `signedBy` is the older GPG equivalent.
- **`containers-registries.conf`** (`blocked = true` per registry/namespace)
  and **`containers-registries.d`** (where sigstore signatures live) complete
  the enforcement surface.
  <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/building_running_and_managing_containers/working-with-container-registries_building-running-and-managing-containers>
- **cosign**: `cosign verify --key …` or keyless
  `--certificate-identity … --certificate-oidc-issuer …`; signature payloads
  embed the image digest, so verifying `image@sha256:…` binds signer to exact
  bytes. <https://docs.sigstore.dev/cosign/verifying/verify/> and
  <https://github.com/sigstore/cosign>

### Curated-catalog analogies

- **Flatpak/Flathub**: curated remotes; verified-only subset via
  `flatpak remote-add --subset=verified …`.
  <https://docs.flathub.org/docs/for-users/installation>
- **Toolbx**: default curated base-image set (name → known-good image on a
  trusted layer). <https://containertoolbx.org/>
- **Devcontainer Features**: named IDs resolving to versioned OCI artifacts in
  a registry — the closest "catalog name → artifact" analogy.
  <https://containers.dev/implementors/features-distribution/>

### The smallest enforceable mechanism

For "agent may only request catalog **names**; host maps names to pinned
digests", the minimal auditable core is:

1. **Host-owned name→digest lockfile** — versioned map
   `name → registry/repo@sha256:<digest>`, committed to the repo, unreachable
   from the forge. The agent's MCP tool takes an enum of names, nothing else.
2. **Run by digest only** — never a mutable tag (Kyverno's
   `verifyDigest` rationale; cosign binds signatures to digests).
3. **Reject-by-default `policy.json`** — `"default":[{"type":"reject"}]` with
   per-scope `sigstoreSigned` allows for exactly the catalog repos, plus
   `registries.conf` blocking everything else. Enforced by Podman itself at
   pull time, independent of the host binary's own checks (defence in depth).
4. **Append-only audit trail** — log every resolution
   `name → digest → verified-identity → launched` on the host; Rekor provides
   the public signing-time record.

This is consistent with the repo's existing Sigstore posture: release binaries
are Cosign-keyless-signed (`docs/VERIFICATION.md`) and the forge brew shim
requires `HOMEBREW_VERIFY_ATTESTATIONS=1`
(`images/default/brew-shim-exec.sh`) — the catalog extends "verify provenance
before executing" from formulae to sibling containers. Caveat: most upstream
Docker Hub official images are **not** Sigstore-signed; where no signature
exists, the digest pin in the host lockfile is the integrity anchor and the
`policy.json` scope-allowlist (without `sigstoreSigned`) still bounds *what*
can be pulled. Optionally re-sign vetted digests with a project key and
require `sigstoreSigned` against that key for full closure.

## 5. Recommendations for Tillandsias

| Decision | Recommendation | Provenance |
|---|---|---|
| MCP transport for the catalog tool | stdio server inside the forge; privileged spawn decided host-side over the enclave channel | <https://modelcontextprotocol.io/specification/2025-11-25/basic/transports> |
| MCP spec target | Build against `2025-11-25`; track the `2026-07-28` RC, don't depend on it | <https://modelcontextprotocol.io/specification/versioning> |
| Client config generation | Emit all four shapes: `opencode.json` (`mcp`, `type:local`, `command` array), `.mcp.json` (`mcpServers`, no-`type` ⇒ stdio), `~/.codex/config.toml` (`[mcp_servers.*]`), `~/.gemini/config/mcp_config.json` (`serverUrl` — verify) | <https://opencode.ai/docs/mcp-servers/>, <https://code.claude.com/docs/en/mcp>, <https://developers.openai.com/codex/mcp>, <https://github.com/github/github-mcp-server/blob/main/docs/installation-guides/install-antigravity.md> |
| Privileged-action security model | Allowlist on the trusted (host) side; agent sends catalog names only; no token passthrough; per-request host authorization | <https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices> |
| TLS for `www.<project>.localhost` | Keep plain HTTP (secure context already, Chrome always / Firefox 84+); opt-in Caddy `tls internal` + on-demand only for OAuth/mixed-content/HSTS cases | <https://www.w3.org/TR/secure-contexts/>, <https://bugzilla.mozilla.org/show_bug.cgi?id=1220810>, <https://caddyserver.com/docs/automatic-https> |
| WEB primary / alternate | `busybox` httpd / `nginx:alpine`; `php:8.4-apache` for classic PHP | <https://hub.docker.com/_/busybox>, <https://hub.docker.com/_/nginx>, <https://hub.docker.com/_/php> |
| WEB-APP primary / alternate | `wordpress` + `mariadb` officials, `_FILE` secrets, `wp-content` bind `:Z` / `wordpress` + `mysql:8` | <https://hub.docker.com/_/wordpress>, <https://hub.docker.com/_/mariadb> |
| SCIENTIFIC primary / alternate | `quay.io/jupyter/minimal-notebook` / `rocker/rstudio` (keep-id recipe; AGPL RStudio) | <https://jupyter-docker-stacks.readthedocs.io/en/latest/using/running.html>, <https://github.com/rocker-org/rocker-versioned2> |
| BIOLOGY TECH primary / alternate | `quay.io/biocontainers/<tool>` (immutable version+build tags) / `bioconductor/bioconductor_docker` | <https://bioconda.github.io/recipes/samtools/README.html>, <https://www.bioconductor.org/help/docker/> |
| STORAGE primary / alternate | `nextcloud:apache` (+ MariaDB sidecar, `NEXTCLOUD_TRUSTED_DOMAINS`) / MinIO digest-pinned only (Hub repo archived ~Oct 2025 — own the CVE watch) | <https://github.com/nextcloud/docker>, <https://hub.docker.com/r/minio/minio> |
| Allowlist enforcement | Host-owned name→digest lockfile; run by `@sha256` digest only; reject-by-default `policy.json` with per-scope allows (+`sigstoreSigned` where signatures exist); append-only audit log | <https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md>, <https://kyverno.io/docs/policy-types/cluster-policy/verify-images/overview/> |
| Signature verification | Cosign keyless where upstream signs; project re-signing of vetted digests for full closure — consistent with `docs/VERIFICATION.md` + brew `HOMEBREW_VERIFY_ATTESTATIONS=1` | <https://docs.sigstore.dev/cosign/verifying/verify/> |

## Provenance

- All web sources retrieved **2026-07-15** via live fetch (no memory-cited
  claims). Section-level URLs inline above.
- Repo grounding: `images/router/base.Caddyfile` (current plain-HTTP
  `*.localhost` router), `docs/VERIFICATION.md` (Cosign keyless releases),
  `images/default/brew-shim-exec.sh` (brew attestation gate),
  `cheatsheets/runtime/caddy-reverse-proxy.md`.
