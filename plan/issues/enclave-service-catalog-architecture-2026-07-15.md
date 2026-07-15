# Enclave service catalog / "publish it locally" — architecture research

- Date: 2026-07-15 (HEAD 5628ee28)
- Class: research (order-353 milestone input; operator-directed)
- Author: Fable architecture fork; every claim cites file:line at 5628ee28
- Decision needed: transport recommendation (§2) requires Tlatoāni sign-off

## 0. Goal (operator, 2026-07-15)

Forge agent says "publish it locally" → an allowlisted, hand-curated
container starts in the enclave serving the user's project in debug mode at
`https://www.<project>.localhost` via the reverse proxy. Friendly names,
never IPs. Agents choose CATALOG CATEGORIES (WEB / SCIENTIFIC / BIOLOGY
TECH / STORAGE), never arbitrary images. Test projects: `../visual-chess`,
`../lakanoa` (static), `../inat-observations-wp` (WordPress + database).
Linux host first; VM boundaries later.

## 1. Current-state map — most of the skeleton already exists

| Piece | State | Provenance |
|---|---|---|
| Tiny WEB image | EXISTS: alpine 3.20 + busybox-extras httpd, `/var/www` on :8080, <10MB requirement | images/web/Containerfile:4-16; openspec/specs/web-image/spec.md ("Image size", "Base image") |
| Image build plumbing | EXISTS: `scripts/build-image.sh web` + runtime asset root knows `"web" => "images/web"` | scripts/build-image.sh:151; crates/tillandsias-headless/src/main.rs:1296 |
| Hostname routing | EXISTS: Caddy router container; tray/headless writes per-project routes to a dynamic Caddyfile bind-mounted at `/run/router/dynamic.Caddyfile`, entrypoint merges + reloads | images/router/base.Caddyfile:1-40; main.rs:2450-2483 (router_dynamic_caddyfile_host_path); images/router/router-reload.sh |
| Naming convention | EXISTS: `<service>.<project>.localhost`, loopback-only per RFC 6761 | openspec/specs/subdomain-routing-via-reverse-proxy/spec.md (Purpose) |
| HTTPS | **GAP**: router deliberately serves plain HTTP (`auto_https off`, :8080) — "TLS would require a CA dance for hostnames browsers already treat as secure contexts" | images/router/base.Caddyfile:18-22; reverse-proxy-internal/spec.md:50 (documented drift note) |
| Forge→host MCP channel | EXISTS AND PROVEN: stdio MCP bridge script in the config overlay socat-pipes newline JSON-RPC through the bind-mounted control socket as `ControlMessage::McpFrame`; headless dispatches UnixSocket-only (`(McpFrame, Vsock) => Unsupported`) | images/default/config-overlay/mcp/host-browser.sh:24-26; crates/tillandsias-headless/src/control_dispatch.rs:127-131; crates/tillandsias-browser-mcp/src/framing.rs:1-8 |
| Agent MCP discovery | EXISTS: opencode config.json lists stdio MCP commands (git-tools, project-info, host-browser); claude/codex/agy read equivalent config-overlay entries | images/default/config-overlay/opencode/config.json:39-52 |
| Host-side allowlist precedent | EXISTS: browser.open URLs validated HOST-side against active window routes; deny-by-default (`Allowlist::empty()`) | crates/tillandsias-browser-mcp/src/allowlist.rs:21,81,103,174 |
| Idiomatic orchestration | EXISTS: typestate dependency graph — `ensure_*` returns `Up<T>` witnesses that cannot be constructed without prerequisites running | crates/tillandsias-headless/src/container_deps.rs:143-204 |
| Session-gating | EXISTS: router-sidecar validates cookies via `forward_auth` for private views (Observatorium/OpenCode Web); public project views can bypass | crates/tillandsias-router-sidecar/src/main.rs:1-30 |

What is genuinely NEW: (a) a catalog abstraction (category → curated
image/group) with host-side enforcement; (b) an McpFrame tool family for
service lifecycle; (c) the publish handler wiring worktree bind-mount +
ContainerSpec + dynamic Caddy route; (d) an https answer.

## 2. Transport decision (operator's question)

Candidates evaluated against: forge must NEVER hold podman socket or host
privileges (request/verify, allowlist host-side); auditability; discovery
across opencode/claude/codex/agy; failure modes; DEFAULTS OVER CONFIGURATION.

**(a) stdio MCP in forge proxied over the control socket — RECOMMENDED.**
This is host-browser-mcp's exact, working pattern: a ~25-line bridge script
(host-browser.sh:24 `socat - UNIX-CONNECT:$TILLANDSIAS_CONTROL_SOCKET`), a
`McpFrame` dispatch arm, host-side validation, per-session semaphores
(browser-mcp/src/server.rs:33-38). Zero new transports, zero new listeners,
already UnixSocket-gated so a compromised guest vsock cannot reach it
(control_dispatch.rs:131). Every agent runtime already consumes stdio MCP
from the config overlay. Adding `publish_local`/`service_status`/
`service_stop` tools is an extension of a proven seam, and the allowlist
lives where it must: in the headless handler, host-side.

(b) HTTP/SSE MCP served by headless on the enclave network: new listener,
new authn story (any container on the enclave net could hit it), duplicate
framing code. Rejected — more surface for no gain.

(c) CLI-only shim: reliable but invisible to agents' tool-discovery;
each runtime would need prompt-engineering to know it exists; MCP tool
schemas are the discoverability mechanism all four harnesses share.

(d) Hybrid (MCP primary + CLI shim wrapping the same socket): adopt the
CLI HALF ONLY IF a human-in-maintenance-shell need materializes — the shim
is trivial later (it is the bridge script with a one-shot payload). Do not
build it speculatively.

**Recommendation: (a), with (d)'s CLI shim deferred until demanded.**
Sign-off requested from The Tlatoāni before implementation.

## 3. Request/grant protocol sketch

New McpFrame tools (JSON-RPC methods under `tools/call`, mirroring
browser-mcp's dispatch):

- `publish_local {category: "WEB", mode: "debug"}` → headless resolves
  (project label comes from the SESSION, not the request — same pattern as
  browser-mcp's project_label from `TILLANDSIAS_PROJECT`, server.rs:56;
  never trust the forge's claimed project). Host-side: category →
  catalog entry lookup (deny anything else), `ensure_service_catalog(entry,
  project)` through container_deps (new `Up<CatalogServiceReady>` witness),
  container `tillandsias-<project>-web`, worktree bind-mounted RO (debug
  mode: RW is a per-entry catalog property, not agent-choosable), dynamic
  Caddyfile route `www.<project>.localhost → tillandsias-<project>-web:8080`,
  caddy reload, respond `{url: "https://www.<project>.localhost", state:
  "running"}`.
- Idempotency: re-publish with same (project, category) returns the
  existing URL (ensure semantics, like every ensure_* in container_deps).
- `service_status {}` → list this project's catalog services + states.
- `service_stop {category}` → stop+rm the service container (route removed).
  Lifecycle default: services are `--rm`, project-scoped, reaped by the
  existing cleanup_shared_stack_if_no_running_forge sweep when the last
  lane closes (main.rs, order-298 lineage) — no orphan web servers.
- Errors: JSON-RPC error objects with actionable text (the agent shows the
  user); every deny logs an accountability event (spec:secret-rotation
  logging pattern, main.rs run_provider_login:5026-5034 precedent).

## 4. HTTPS at *.localhost

Current router is deliberately HTTP-only (base.Caddyfile:18-22). The
operator wants literal `https://` out of the box. Options:

1. **Caddy `tls internal` (RECOMMENDED)**: Caddy mints a local CA and leaf
   certs for `www.<project>.localhost`. One-time host trust: install
   Caddy's root into the host trust store — Tillandsias already OWNS a
   host-side CA install flow for the enclave proxy CA (the certs_dir /
   `intermediate.crt` machinery, main.rs:7671-7687 lineage), so the same
   install step can add the router root. Browsers then show a clean padlock.
2. Reuse the enclave proxy CA: hand Caddy the enclave intermediate to mint
   leafs — one root for users to trust instead of two. Preferred IF the
   intermediate's key is mountable into the router container without
   weakening the vault story; needs a small security review (the proxy CA
   signs MITM certs — sharing it with the router widens its blast radius).
3. Stay HTTP and rely on secure-context semantics: rejected — operator
   explicitly specified https, and mixed-content/PWA tooling increasingly
   expects the scheme, not just the context.

Rung order: ship rung 1 (tls internal + trust-store step), file rung 2 as
a security-review packet that could consolidate to one CA later.

## 5. The three use cases

| Project | Catalog entry | Containers | Debug mode |
|---|---|---|---|
| visual-chess, lakanoa | WEB (static) | 1× tillandsias-web (alpine httpd) | worktree bind-mounted at /var/www (RO); busybox httpd serves live edits — no reload needed for static |
| inat-observations-wp | WEB-APP:wordpress | wordpress + mariadb on a per-project service network | wp-content bind-mounted from worktree; DB creds minted into vault + injected as env (podman secrets pattern, spec:podman-secrets-integration); DB volume persistent per-project |
| (any SPA w/ build step) | WEB (static) first; WEB-APP:node later | — | out of first-rung scope; catalog is versioned so entries can grow |

WordPress is deliberately rung 4+: multi-container groups need a
compose-like catalog schema (ordered ensure, healthchecks, secret
injection) — that is exactly what the catalog manifest research packet
(§6 R2) must design, using container_deps' typestate graph rather than
compose files.

## 6. Packet tree proposal (milestone: enclave-service-catalog)

- R1 (this doc) transport + https sign-off — Tlatoāni decision gate. ~0h.
- R2 catalog manifest schema research: hand-curated catalog format
  (category → image/group, mounts, ports, secrets, debug semantics),
  host-side enforcement, versioning; closure = schema doc + validator
  fixture. ~6h.
- I3 FIRST RUNG: `publish_local` for static WEB on Linux host — McpFrame
  tools + headless handler + ensure_catalog_service + dynamic Caddy route
  (http-internal), `tillandsias-<project>-web` bind-mount RO; closure =
  litmus: e2e curl `http://www.<project>.localhost` returns the worktree's
  index.html for a fixture project. ~8h.
- I4 https: tls internal + router root into the host trust flow; closure =
  litmus curl over https with the installed root, no -k. ~6h.
- I5 spec + allowlist litmus: openspec/specs/enclave-service-catalog;
  closure = litmus proving a non-catalog image/category is refused
  HOST-side (fixture sends a forged McpFrame). ~4h.
- I6 lifecycle tools: service_status/service_stop + lane-close reaping;
  closure = fixture: publish, close lane, container gone. ~4h.
- I7 WEB-APP:wordpress group: multi-container entry + vault-minted DB
  secret + persistent volume; closure = e2e on inat-observations-wp
  (wp-login reachable over https). ~10h.
- I8 agent UX: config-overlay MCP entry for all four runtimes + cheatsheet
  + "publish it locally" skill prompt; closure = in-forge e2e (agent
  invokes the tool via prompt). ~4h.
- R9 catalog expansion (multi_cycle): SCIENTIFIC (R/modeling), BIOLOGY
  TECH, STORAGE (NextCloud) curation with per-entry security review. Open-
  ended; each entry lands as its own child packet.

Dependencies: R1 → {R2, I3}; I3 → {I4, I5, I6, I8}; R2 → I7; I7 → R9.

## Open questions for The Tlatoāni

1. Transport recommendation (a): approve MCP-over-control-socket, CLI shim
   deferred?
2. HTTPS rung 1 = Caddy `tls internal` with a second trusted root; OK to
   ship before the one-CA consolidation review (rung 2)?
3. Lifecycle default: services die with the last forge lane (--rm + sweep).
   Should "publish" outlive the forge session (tray-owned) instead?
4. WEB debug mode mounts the worktree read-only into the service container.
   WordPress needs wp-content RW — acceptable for the WEB-APP tier?
5. Category names locked as WEB / SCIENTIFIC / BIOLOGY TECH / STORAGE?
   (Manifest is versioned; renames are cheap now, expensive later.)
