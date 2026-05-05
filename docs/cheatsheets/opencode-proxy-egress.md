# OpenCode Proxy Egress — Cheatsheet

@trace spec:opencode-web-session, spec:proxy-container, spec:inference-container

How OpenCode Web (and the CLI forge variants) reach their external providers
through the Tillandsias enclave without surfacing proxy errors to the user.

---

## Golden rule

External → proxy (allowlisted). Intra-enclave → direct (NO_PROXY bypass).

Every failure mode we've hit has been one of those two rules slipping: a
destination not on the allowlist, or an enclave-internal peer getting routed
through Squid. Keep the table below in sync and OpenCode sessions stay quiet.

---

## Env vars OpenCode (Bun) honours

| Env var | Purpose | Where set |
|---|---|---|
| `HTTP_PROXY` / `HTTPS_PROXY` | Upstream proxy URL (`http://proxy:3128`) | Forge + inference profiles in `container_profile.rs` |
| `http_proxy` / `https_proxy` | Lowercase duplicate — some libs (Go, libcurl, Python) only read these | Same |
| `NO_PROXY` / `no_proxy` | Comma-separated destinations that bypass the proxy | Same |
| `NODE_EXTRA_CA_CERTS` | PEM file added to Bun's trust store so MITM certs verify | `inject_ca_chain_mounts()` in `handlers.rs` |
| `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` | Combined (system + enclave CA) bundle for curl, pip, python | `entrypoint-forge-opencode-web.sh` writes `/tmp/tillandsias-combined-ca.crt` |
| `NODE_TLS_REJECT_UNAUTHORIZED=0` | DO NOT USE — disables verification, gap in sandbox | — |

Bun fully inherits Node.js conventions — no `BUN_CONFIG_CAFILE` or Bun-specific
override. Verified against Bun docs + v1.1.22 release notes.

---

## NO_PROXY canonical value

Both forge and inference profiles use the same list:

```
localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy
```

Why each entry is there:

| Entry | Who reaches it | What breaks without it |
|---|---|---|
| `localhost`, `127.0.0.1` | Every tool that loopbacks | curl/pip/python hang on self-probes |
| `0.0.0.0` | ollama's boot health probe | `TCP_DENIED/403 HEAD http://0.0.0.0:11434/` repeats every ~1s |
| `::1` | IPv6 loopback (rare, cheap to include) | — |
| `git-service` | forge cloning from git mirror | `git clone git://git-service/...` denied |
| `inference` | forge → ollama (OpenCode provider, health probe) | `GET http://inference:11434/api/version` denied, hangs on first prompt |
| `proxy` | self-reach safety net | Prevents accidental proxy→proxy loops |

---

## Squid allowlist — what OpenCode needs

Minimum set (on top of the package/registry/CDN lines already in
`images/proxy/allowlist.txt`):

| Line | Purpose |
|---|---|
| `.anthropic.com` | Claude API |
| `.openai.com` | OpenAI / Azure OpenAI-compatible endpoints |
| `.groq.com` | Groq |
| `.together.ai` | Together AI |
| `.deepseek.com` | DeepSeek |
| `.mistral.ai` | Mistral |
| `.fireworks.ai` | Fireworks |
| `.cerebras.ai` | Cerebras |
| `.sambanova.ai` | SambaNova |
| `.huggingface.co` | HF inference endpoints, model metadata |
| `.models.dev` | OpenCode canonical model registry |
| `.openrouter.ai` | OpenRouter aggregation gateway |
| `.helicone.ai` | Helicone telemetry / gateway |
| `.opencode.ai` | OpenCode updates, docs, metadata |
| `.ollama.com` | Model pulls from public registry (via inference) |

Squid 6.x rule: one entry per domain, leading-dot form (matches bare domain
AND subdomains). Duplicate entries are a fatal startup error.

## Adding a new provider

1. Identify the hostname(s) the provider serves from (API + docs + auth).
2. Pick the broadest leading-dot form that isn't a subdomain duplicate of an
   already-listed entry. Example: `.new-provider.com` is fine even if you only
   use `api.new-provider.com` — and future-proofs for auth endpoints.
3. Add one line to `images/proxy/allowlist.txt` under the AI/ML section.
4. Rebuild the proxy image: `scripts/build-image.sh proxy`.
5. Restart the enclave (tray Quit + re-launch). No forge image rebuild needed.
6. Run the smoke check: tail proxy log while sending a test prompt to the new
   provider. Zero `TCP_DENIED` entries means the provider is reachable.

---

## Smoke-test proxy transparency

```bash
# Tail Squid access log during a session
podman logs -f tillandsias-proxy 2>&1 | grep TCP_DENIED
```

Healthy session produces: no output. Any `TCP_DENIED` line identifies either
a missing allowlist entry or a missing NO_PROXY exclusion. Copy the URL/host
from the denial into the tables above to decide which side to fix.

---

## References

- [OpenCode providers](https://opencode.ai/docs/providers/)
- [OpenCode config](https://opencode.ai/docs/config/)
- [Bun env vars — proxy + TLS](https://bun.sh/docs/runtime/env)
- [Bun v1.1.22 release notes — NODE_EXTRA_CA_CERTS support](https://bun.com/blog/bun-v1.1.22)
- [Squid dstdomain allowlist format](https://www.squid-cache.org/Doc/config/acl/)

Related cheatsheets: `mitm-proxy-design.md`, `enclave-architecture.md`.
