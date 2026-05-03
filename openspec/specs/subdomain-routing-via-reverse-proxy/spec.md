<!-- @trace spec:subdomain-routing-via-reverse-proxy -->
# subdomain-routing-via-reverse-proxy Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-25-subdomain-routing-via-reverse-proxy/
annotation-count: 11

## Purpose

Enable stable, port-agnostic URLs for all web services spawned in the enclave via a reverse-proxy listener that maps `<service>.<project>.localhost` hostnames to internal container ports, while maintaining RFC 6761 loopback-only binding.

## Requirements

### Requirement: Reverse-proxy container and binding

A new reverse-proxy container (Caddy 2.x) SHALL bind to exactly two addresses:

1. `127.0.0.1:80` on the host (loopback only — no external access possible)
2. `proxy:80` on the enclave network (accessible to forge agents via the forward proxy)

The container SHALL be named `tillandsias-router` and SHALL be created alongside the proxy and git-service containers at attach time.

#### Scenario: Reverse proxy binds to loopback only

- **WHEN** `ensure_enclave_ready()` creates the router container
- **THEN** port `80` SHALL be bound to `127.0.0.1` only on the host
- **AND** the container SHALL be reachable at `proxy:80` on the enclave network
- **AND** external port scanning SHALL find no listening socket on `0.0.0.0:80`

### Requirement: Dynamic routing table from Caddyfile

The tray SHALL generate a Caddyfile at `$XDG_RUNTIME_DIR/tillandsias/router/Caddyfile` with one stanza per service at each attach. The stanza maps `<service>.<project>.localhost:80` to an internal container port using Caddy's `reverse_proxy` directive.

Service-to-port conventions:

| Service | Internal port | Notes |
|---------|---------------|-------|
| `opencode` | 4096 | OpenCode Web |
| `flutter` | 8080 | Flutter web-server |
| `vite` | 5173 | Vite dev server |
| `next` | 3000 | Next.js dev server |
| `storybook` | 6006 | Storybook |
| `webpack` / `wds` | 8080 | webpack-dev-server |
| `jupyter` | 8888 | Jupyter notebook |
| `streamlit` | 8501 | Streamlit |

#### Scenario: Router forwards to correct internal port

- **WHEN** a browser request arrives for `opencode.java.localhost/`
- **THEN** the reverse proxy SHALL forward to `tillandsias-java-forge:4096`
- **AND** the host port `80` is never exposed to the service container

#### Scenario: Multiple services per project coexist

- **WHEN** a forge runs both OpenCode Web and Flutter
- **THEN** the Caddyfile SHALL contain two stanzas: `opencode.java.localhost:80` and `flutter.java.localhost:80`
- **AND** both route to the same forge container but different internal ports

### Requirement: Forward-proxy integration

Squid SHALL be configured to recognize `.localhost` domains and forward them to the reverse-proxy sibling at `proxy:80`. From inside a forge, `curl http://project.service.localhost/` SHALL be transparently routed via `HTTP_PROXY=http://proxy:3128` to the reverse proxy.

#### Scenario: Agents reach reverse proxy through forward proxy

- **WHEN** an in-forge agent runs `curl http://project.opencode.localhost/`
- **THEN** Squid recognizes the `.localhost` TLD and forwards the request to `proxy:80`
- **AND** the reverse proxy fulfills it at `tillandsias-project-forge:4096`
- **AND** the agent sees the response as if directly connected

### Requirement: No container port publication

Container service ports (e.g., `flutter run` binding `0.0.0.0:8080` inside the container) SHALL NOT be published to the host via `-p`. The router is the sole host-side listener on port `80`.

#### Scenario: Container ports stay internal

- **WHEN** a forge container's application binds port `8080` internally
- **THEN** the tray SHALL NOT invoke `podman run -p 8080:8080`
- **AND** the reverse router proxies to that internal port instead
- **AND** the application is unreachable from the host without going through the router

### Requirement: Caddyfile reload via admin API

The tray SHALL reload the router's configuration by sending a POST request to the Caddy admin API (`http://proxy:2019/config/` by default) with the updated Caddyfile. This enables dynamic route updates without restarting the container.

#### Scenario: Configuration update without container restart

- **WHEN** a new service spins up inside the forge
- **THEN** the tray updates `$XDG_RUNTIME_DIR/tillandsias/router/Caddyfile`
- **AND** POSTs it to the Caddy admin API
- **AND** the new route is live within milliseconds (no container restart)

### Requirement: Agent instructions for service binding

A new cheatsheet file `config-overlay/opencode/instructions/web-services.md` SHALL instruct agents:

1. Bind service servers to `0.0.0.0:<port>` inside the forge (never `localhost:N`)
2. The user accesses the service via `http://<project>.<service>.localhost/` on port `80`
3. Do not attempt port publication; the router handles host-side access
4. For self-testing from inside the forge, use `curl http://<project>.<service>.localhost/` (goes through the forward proxy and back)

#### Scenario: Agent documentation guides correct binding

- **WHEN** an agent is asked to run a dev server
- **THEN** the instructions cheatsheet explains binding to `0.0.0.0:<service-port>` and the stable URL format
- **AND** the agent follows the pattern without operator involvement

## Sources of Truth

- `cheatsheets/runtime/caddy-reverse-proxy.md` — Caddy 2.x configuration, admin API, hostname matching
- `cheatsheets/runtime/networking.md` — RFC 6761 loopback-only binding, localhost resolution
- `cheatsheets/runtime/squid-cache-peer-routing.md` — forward proxy integration with peer services
