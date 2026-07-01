# Agent API-Key Entry Flows (autonomous track) — 2026-07-01

- class: enhancement
- filed: 2026-07-01
- owner: linux
- status: pending (deferred; do AFTER the OAuth login flows land)
- depends_on: agent-login-flows-impl-2026-06-28.md (order 132), forge-harness-auth-vault-proxy-2026-06-27.md (order 112, ProviderId + api-key storage)
- trace: spec:tillandsias-vault, spec:secret-rotation

## Why deferred / why separate

Operator decision 2026-07-01 (see `agent-login-flows-research-2026-06-28.md`
Verdict): **API keys are the credential for autonomous / unattended forge work**;
OAuth subscriptions cover interactive sessions and ship first as the
`--<provider>-login` flows (order 132). This packet is the **later** API-key
*entry* flow — the counterpart that lets an operator seed the API key that
autonomous forges consume.

The API-key **storage + consumption** side already exists (order 112):
`ProviderId`, `secret/<provider>/api-key`, `read/write_provider_api_key`, and
`build_forge_agent_run_args` injecting `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` /
`GEMINI_API_KEY`. What is missing is a first-class, containerized **entry** flow
so the key is set the same host-never-sees-it way as `--github-login`, rather
than an operator hand-writing Vault.

## Scope

- Add `AuthModel::ApiKeyPaste` to the `run_provider_login` shape defined by the
  OAuth research/impl, reusing the same containerized boundary + hidden-paste
  pipe. The paste target is `secret/<provider>/api-key` (existing schema) instead
  of `secret/<provider>/oauth`.
- Entry points: extend the provider-login subcommands with an explicit API-key
  mode (e.g. `--claude-login --api-key` / a `--claude-set-key`), operator-gated;
  autonomous runs never prompt — they read the stored key.
- Validate the key inside the container (a cheap authenticated probe) before
  writing to Vault, so a bad paste fails loudly rather than at first forge use.
- Tray: show api-key-present vs oauth-present distinctly per provider so the
  operator knows which track a provider is on.

## Non-goals

- No change to how autonomous forges READ the key (order 112 already does that).
- No OAuth changes — that is order 132.

## Exit criteria

- API-key entry flow stores `secret/<provider>/api-key` via the containerized
  paste boundary; host never holds the raw key.
- In-container validation rejects a malformed/invalid key before the Vault write.
- Autonomous forge run consumes the stored key with zero interactive prompt.
- Tray distinguishes api-key vs oauth presence per provider.
- `./build.sh --check` and `--test` pass.
