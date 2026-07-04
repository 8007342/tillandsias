# P0: Node forge agents (Codex/Claude) bypass the proxy → can't reach remote — 2026-07-04

- class: bug (P0, connectivity)
- filed: 2026-07-04
- owner: linux
- status: done
- trace: spec:proxy-container, cheatsheets/runtime/enclave-proxy-patterns.md
- found-by: live probe inside a running forge (project "lakanoa") on the host

## Symptom (operator report)

Codex, authenticated inline in the forge, "fails to connect to remote — times out
5 times for websockets, then times out 5 retries for https, then dies." OpenCode
works. The operator suspected an allowlist gap or a lost login token.

## Root cause — Node ignores HTTP_PROXY (NOT an allowlist gap)

The enclave network is `--internal`: no NAT egress, no external DNS; the Squid
proxy is the ONLY route out, reached via the `HTTP_PROXY`/`HTTPS_PROXY` env the
forge sets. Live evidence from inside the running forge:

```
# curl uses the env proxy -> reaches OpenAI:
curl https://api.openai.com/v1/models        -> http=401 in 0.13s   (WORKS)

# Node global fetch/undici does NOT honor HTTP_PROXY by default:
node -e 'fetch("https://api.openai.com/v1/models")'  -> ERR ENOTFOUND

# with the built-in Node env-proxy flag:
NODE_USE_ENV_PROXY=1 node -e 'fetch(...)'    -> http=401           (WORKS)
```

So `api.openai.com` is **allowlisted and reachable** — the allowlist is fine.
Codex (a Node app) tries to connect DIRECTLY (fetch/undici + `ws`), the
`--internal` enclave can't resolve external hosts, and it times out / ENOTFOUNDs.
OpenCode "works" because it targets the *local* inference container
(`http://inference:11434`), needing no egress. Node v22.22.2 in the forge had no
`NODE_USE_ENV_PROXY` / `NODE_OPTIONS` / proxy-agent set.

## Fix

Set `NODE_USE_ENV_PROXY=1` at both proxy-env injection chokepoints in
`crates/tillandsias-headless/src/main.rs`:

- `apply_proxy_env` (ContainerSpec) — used by `build_forge_agent_run_args`
  (Codex/Claude/OpenCode forge agents);
- `proxy_env_args` (Vec) — used by the provider-login containers
  (`run_provider_login`) and other enclave containers.

`NODE_USE_ENV_PROXY=1` makes undici's `EnvHttpProxyAgent` route Node egress
through the already-present `HTTP(S)_PROXY`, respecting `NO_PROXY`. Verified live:
flips node fetch from `ENOTFOUND` to `http=401`. Regression test
`proxy_env_routes_node_through_the_proxy` pins it in both sites.

## Residual / follow-ups (filed, not blocking this fix)

1. **Websockets (`ws` package):** `NODE_USE_ENV_PROXY` covers undici/fetch. If any
   agent opens a raw `wss://` via the `ws` package, that may still need an
   explicit proxy agent. Codex should fall back to HTTPS (now working). Confirm
   with a live Codex session once a token is present; if `ws` still bypasses,
   add an explicit ws proxy agent. Tracked as a follow-up probe.
2. **Login-first gating (operator request):** launching Codex/Claude/Antigravity
   should run the provider login flow first when no token is stored, then relaunch
   an authenticated forge; when a token is present, launch directly. Currently
   `run_forge_agent_cli_mode` launches the forge unconditionally with no
   token-presence gate. Separate packet.

## Verifiable closure

- `./build.sh --check` + `proxy_env_routes_node_through_the_proxy` test green.
- Live: `NODE_USE_ENV_PROXY=1` flips node fetch ENOTFOUND -> HTTP 401 in the forge.
- Ships next release; operator re-tests a Codex session reaching remote.
