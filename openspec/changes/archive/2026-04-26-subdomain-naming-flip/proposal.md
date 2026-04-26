## Why

Today's URL pattern `<project>.opencode.localhost:8080` puts the project name first and the service second. As soon as Tillandsias adds a second service per project (`web` for Flutter dev server, `dashboard` for an agent UI, `www` for a static preview), the URL space becomes hard to scan: `java.opencode.localhost`, `python.opencode.localhost`, `java.web.localhost`, `python.web.localhost` — services interleave with projects when sorted alphabetically and there is no visual hierarchy.

Flipping to `<service>.<project>.localhost` (e.g., `opencode.java.localhost`, `web.java.localhost`, `dashboard.java.localhost`) groups all services for one project under a single `*.<project>.localhost` namespace. `*.java.localhost` resolves to loopback by RFC 6761 regardless of depth, so wildcards work the same. The browser-MCP allowlist becomes trivial to specify (`*.<project>.localhost:8080 except opencode.<project>.localhost`).

## What Changes

- **BREAKING** URL ordering flips: `<project>.opencode.localhost:8080/` → `opencode.<project>.localhost:8080/`.
- `src-tauri/src/browser.rs::build_subdomain_url` returns the new shape.
- `src-tauri/src/handlers.rs::regenerate_router_caddyfile` writes `opencode.<project>.localhost:80 { reverse_proxy tillandsias-<project>-forge:4096 }` instead of `<project>.opencode.localhost:80 { ... }`.
- Browser tests in `browser.rs::tests` invert their expected hostname order.
- Spec delta on `opencode-web-session` flips every URL example.
- Cheatsheet `agents/opencode.md` URL note updated (still DRAFT — provenance retrofit will pick this up).

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `opencode-web-session`: subdomain shape inverted from `<project>.opencode.localhost` to `opencode.<project>.localhost`.

## Impact

- `src-tauri/src/browser.rs:163-170` — flip the format string.
- `src-tauri/src/handlers.rs:1024-1029` — flip the Caddyfile route key.
- `src-tauri/src/browser.rs::tests` — invert four test assertions.
- `openspec/changes/subdomain-naming-flip/specs/opencode-web-session/spec.md` — MODIFIED Requirement: Native browser URL format.
- One existing change-in-flight (`fix-router-loopback-port`) used the old `<project>.opencode.localhost:8080` shape — its delta spec is updated to use the new ordering before either lands.
- No runtime, network, or container changes beyond the URL string. The router still binds `127.0.0.1:8080`. Browser still resolves `*.localhost` via RFC 6761.

## Sources of Truth

- `cheatsheets/runtime/networking.md` (DRAFT) — confirms `*.localhost` loopback resolution applies at any subdomain depth.
- `cheatsheets/agents/opencode.md` (DRAFT) — current URL examples will be updated to the new shape.
