## Why

OpenCode Web hangs after one or two prompts inside a forge container. Proxy logs
captured from a live session show three independent failure modes all traced back
to proxy configuration:

1. `TCP_DENIED/200 CONNECT models.dev:443` — `models.dev`, the canonical OpenCode
   model registry, is not on the Squid allowlist. Every attempt by the agent to
   resolve or enumerate models stalls on a denied CONNECT tunnel.
2. `TCP_DENIED/403 GET http://inference:11434/api/version` — the forge container
   proxies its own intra-enclave reach to `inference:11434` through Squid, which
   denies it because `inference:11434` is not a public URL. The forge's
   `NO_PROXY` currently lists only `localhost,127.0.0.1,git-service`, so the
   inference hostname is not excluded.
3. `TCP_DENIED/403 HEAD http://0.0.0.0:11434/` (from the inference container itself
   at 10.89.0.3) — ollama's internal health probe against its own listen address
   routes through the proxy (inference has `HTTP_PROXY=http://proxy:3128` with no
   `NO_PROXY`), which denies `0.0.0.0:11434`. Each denied probe costs one model
   slot and eventually produces a hang that the client sees as a stuck prompt.

Research confirms OpenCode is a Bun-compiled TypeScript app that honours standard
Node conventions — `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, and
`NODE_EXTRA_CA_CERTS` — without an OpenCode-specific knob. The proxy already has
CA infrastructure (`/etc/squid/certs/intermediate.crt`) and the forge container
already mounts `ca-chain.crt` + sets `NODE_EXTRA_CA_CERTS` / `SSL_CERT_FILE`. The
missing pieces are:

- Domain allowlist coverage for OpenCode's registry + the providers OpenCode Web
  routes to by default (OpenRouter, Helicone, and the existing provider family).
- `NO_PROXY` completeness in every enclave-resident container so intra-enclave
  traffic never hairpins through the proxy.

The user's direction is "make the proxy transparent": the agent should not be
able to tell it is behind a proxy for its normal request path. That means every
allowed domain resolves cleanly, every intra-enclave hostname bypasses the proxy,
and every TLS handshake against an allowed external origin succeeds under the
enclave CA.

## What Changes

- **Extend the Squid allowlist** (`images/proxy/allowlist.txt`) to include
  `.models.dev`, `.openrouter.ai`, `.helicone.ai`, and any provider domain that
  shows up in OpenCode's AI SDK footprint but is not already covered. No bare
  domains (Squid prefers `.domain` form) and no duplicates of subdomains of
  already-listed domains.
- **Broaden NO_PROXY in the forge profile** (`container_profile.rs` `forge_profile`)
  from `localhost,127.0.0.1,git-service` to
  `localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy`. Intra-enclave
  service names + loopback variants never traverse the proxy; external DNS names
  still do. Uppercase and lowercase variants stay in sync.
- **Add NO_PROXY to the inference profile** (`container_profile.rs`
  `inference_profile`) — currently missing entirely. Mirror the forge list so
  ollama's internal health checks and inter-model probes stay inside the
  container.
- **Audit the opencode-web entrypoint** to confirm `SSL_CERT_FILE` /
  `REQUESTS_CA_BUNDLE` remain set to the combined bundle and that
  `NODE_EXTRA_CA_CERTS` is the injected chain. Document the Bun-inherits-Node
  contract with a reference comment so future readers don't re-research it.
- **Spec deltas** (`opencode-web-session`, `proxy-container`, `inference-container`)
  to record the transparency contract: all egress domains explicitly allowlisted,
  all enclave-internal hostnames excluded from proxying, CA trust via
  `NODE_EXTRA_CA_CERTS` for the Bun runtime.

## Capabilities

### Modified Capabilities

- `opencode-web-session`: adds "Proxy egress is transparent to opencode" contract.
- `proxy-container`: explicit allowlist coverage for OpenCode registry + default
  provider set; documented minimum set.
- `inference-container`: `NO_PROXY` is mandatory so ollama's internal probes do
  not hairpin through the proxy.

## Impact

- **Images**: `images/proxy/allowlist.txt` gains three domain lines. No Squid
  config change required — the allowlist file is loaded via `dstdomain
  "/etc/squid/allowlist.txt"` already.
- **Rust**: `crates/tillandsias-core/src/container_profile.rs` changes two profile
  functions (forge, inference). `src-tauri/src/launch.rs` test assertions move in
  lockstep (they hard-code the NO_PROXY value); update both to the new default.
- **Cheatsheet**: add `docs/cheatsheets/opencode-proxy-egress.md` documenting the
  allowlist strategy, NO_PROXY rules, Bun CA env, and how to add a new provider.
- **No forge image rebuild required** — the entrypoint already handles CA trust
  correctly. Only the proxy image needs a rebuild (allowlist change), and the
  profile changes are applied at launch time.
- **No schema/config changes**, no migration.
