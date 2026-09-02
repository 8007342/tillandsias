<!-- @trace spec:subdomain-routing-via-reverse-proxy -->
<!-- # freshness: auditor=linux-lenovinha-claude-20260902t025309z date=2026-09-02 verdict=updated scope=standing per-cycle audit, three drifts corrected against the live runtime: (1) the binding requirement pinned 127.0.0.1:80 and proxy:80, but the in-container listener is :8080 and the host port comes from the 80->8080->--port fallback (port 80 is privileged; pinning it made a conformant rootless launch impossible) - the loopback-only invariant it actually protects is unchanged; (2) the dynamic routing table is dynamic.Caddyfile merged with base.Caddyfile in-container, not a whole-config Caddyfile; (3) the reload requirement specified a POST to the Caddy admin API, which CANNOT work and must not be made to work - the admin port binds 127.0.0.1:2019 inside the container and is deliberately unpublished, so satisfying the old wording would have opened a reconfiguration hole; the canonical path is router-reload.sh in-container. Enclave alias verified as router, not proxy. -->
# subdomain-routing-via-reverse-proxy Specification

## Status

active
promoted-from: openspec/changes/archive/2026-04-25-subdomain-routing-via-reverse-proxy/
annotation-count: 11

## Purpose

Enable stable, port-agnostic URLs for all web services spawned in the enclave via a reverse-proxy listener that maps `<service>.<project>.localhost` hostnames to internal container ports, while maintaining RFC 6761 loopback-only binding.

Project-local web views use named hosts in the form
`<service>.<project>.localhost`; the Observatorium view uses
`observatorium.<project>.localhost` and keeps source access private behind the
same router/session gate as OpenCode Web.

## Requirements


### Requirement: Reverse-proxy container and binding
A new reverse-proxy container (Caddy 2.x) MUST publish exactly one host address, and it MUST be loopback-only:

1. `127.0.0.1:<host_port>` on the host, where `<host_port>` is chosen by `select_router_host_port()` from the fallback chain `80 -> 8080 -> --port`. The IN-CONTAINER listener is `:8080` and does not vary.
2. `router:8080` on the enclave network (reachable by forge agents; the enclave alias is `router`).

CORRECTED 2026-09-02 (standing freshness audit). This requirement previously specified `127.0.0.1:80` and `proxy:80`, and both literals had drifted. Port 80 is privileged, so a rootless host cannot always bind it — the fallback chain exists for exactly that, and pinning `80` would have made a spec-conformant launch impossible on a host where 80 is taken. What did NOT change, and what the requirement is actually protecting, is the loopback-only invariant: the publish is `127.0.0.1:{host_port}:8080` in every branch.

The container MUST be named `tillandsias-router` and MUST be created alongside the proxy and git-service containers at attach time.

#### Scenario: Reverse proxy binds to loopback only

- **WHEN** `ensure_enclave_ready()` creates the router container
- **THEN** the published host port MUST be bound to `127.0.0.1` only
- **AND** the in-container listener MUST be `:8080`
- **AND** external port scanning MUST find no listening socket on any `0.0.0.0` address

### Requirement: Dynamic routing table from Caddyfile

The tray MUST generate a dynamic Caddyfile at `$XDG_RUNTIME_DIR/tillandsias/router/dynamic.Caddyfile` with one stanza per service at each attach. It is bind-mounted read-write at `/run/router/dynamic.Caddyfile` and MERGED with the image's `base.Caddyfile` inside the container; it is not the whole config. (Filename corrected 2026-09-02: the spec said `Caddyfile`, the runtime writes `dynamic.Caddyfile`.) The stanza maps `<service>.<project>.localhost:80` to an internal container port using Caddy's `reverse_proxy` directive.

Service-to-port conventions:

| Service | Internal port | Notes |
|---------|---------------|-------|
| `opencode` | 4096 | OpenCode Web |
| `observatorium` | 8080 | Read-only project source viewer |
| `flutter` | 8080 | Flutter web-server |
| `vite` | 5173 | Vite dev server |
| `next` | 3000 | Next.js dev server |
| `storybook` | 6006 | Storybook |
| `webpack` / `wds` | 8080 | webpack-dev-server |
| `jupyter` | 8888 | Jupyter notebook |
| `streamlit` | 8501 | Streamlit |

#### Scenario: Router forwards to correct internal port

- **WHEN** a browser request arrives for `opencode.java.localhost/`
- **THEN** the reverse proxy MUST forward to `tillandsias-java-forge:4096`
- **AND** the host port `80` MUST NOT be exposed to the service container

#### Scenario: Multiple services per project coexist

- **WHEN** a project runs OpenCode Web, Observatorium, and Flutter
- **THEN** the dynamic Caddyfile MUST contain stanzas for `opencode.java.localhost`, `observatorium.java.localhost`, and `flutter.java.localhost`
- **AND** routes SHALL be upserted without dropping previously registered services
- **AND** OpenCode and Flutter MAY route to the forge container while Observatorium routes to its project web container

### Requirement: Forward-proxy integration

Squid MUST be configured to recognize `.localhost` domains and forward them to the reverse-proxy sibling at `proxy:80`. From inside a forge, `curl http://project.service.localhost/` MUST be transparently routed via `HTTP_PROXY=http://proxy:3128` to the reverse proxy.

#### Scenario: Agents reach reverse proxy through forward proxy

- **WHEN** an in-forge agent runs `curl http://project.opencode.localhost/`
- **THEN** Squid MUST recognize the `.localhost` TLD and forward the request to `proxy:80`
- **AND** the reverse proxy MUST fulfill it at `tillandsias-project-forge:4096`
- **AND** the agent MUST see the response as if directly connected

### Requirement: No container port publication

Container service ports (e.g., `flutter run` binding `0.0.0.0:8080` inside the container) MUST NOT be published to the host via `-p`. The router is the sole host-side listener on port `80`.

#### Scenario: Container ports stay internal

- **WHEN** a forge container's application binds port `8080` internally
- **THEN** the tray MUST NOT invoke `podman run -p 8080:8080`
- **AND** the reverse router MUST proxy to that internal port instead
- **AND** the application MUST be unreachable from the host without going through the router

### Requirement: Caddyfile reload via the in-container reload script

The tray MUST reload the router's configuration by executing
`/usr/local/bin/router-reload.sh` inside the `tillandsias-router` container,
which re-merges `base.Caddyfile` with the runtime-written `dynamic.Caddyfile`
and runs `caddy reload`. This updates routes without restarting the container.

CORRECTED 2026-09-02 (standing freshness audit). This requirement previously
read "sending a POST request to the Caddy admin API (`http://proxy:2019/config/`
by default)". **That mechanism cannot work, and its impossibility is
deliberate.** Caddy's admin API binds `127.0.0.1:2019` INSIDE the container and
the router publishes only its public listener to the host, so a POST from the
host always gets connection refused. Exposing the admin port to satisfy the old
wording would have handed anything on the host loopback full reconfiguration
authority over the router — the spec was, in effect, asking for a hole. The
in-container script is the canonical path precisely because it needs no exposed
admin surface.

The reload MUST tolerate a not-yet-ready router: a `connection refused` from the
script is retried, and exhausting the retries logs a warning rather than failing
the launch, since a stale config is detected by subsequent operations.

#### Scenario: Configuration update without container restart

- **WHEN** a new service spins up inside the forge
- **THEN** the tray MUST update `$XDG_RUNTIME_DIR/tillandsias/router/dynamic.Caddyfile`
- **AND** MUST invoke `router-reload.sh` inside the router container
- **AND** the new route MUST be live without a container restart
- **AND** the Caddy admin port MUST NOT be published to the host

### Requirement: Agent instructions for service binding

A new cheatsheet file `config-overlay/opencode/instructions/web-services.md` MUST instruct agents:

1. Bind service servers to `0.0.0.0:<port>` inside the forge (never `localhost:N`)
2. The user accesses the service via `http://<project>.<service>.localhost/` on port `80`
3. Do not attempt port publication; the router handles host-side access
4. For self-testing from inside the forge, use `curl http://<project>.<service>.localhost/` (goes through the forward proxy and back)

#### Scenario: Agent documentation guides correct binding

- **WHEN** an agent is asked to run a dev server
- **THEN** the instructions cheatsheet MUST explain binding to `0.0.0.0:<service-port>` and the stable URL format
- **AND** the agent MUST follow the pattern without operator involvement

## Sources of Truth

- `cheatsheets/runtime/caddy-reverse-proxy.md` — Caddy 2.x configuration, admin API, hostname matching
- `cheatsheets/runtime/networking.md` — RFC 6761 loopback-only binding, localhost resolution
- `cheatsheets/runtime/squid-cache-peer-routing.md` — forward proxy integration with peer services

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Subdomain routing state is ephemeral; reverse-proxy rules are cleaned on reload
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable
