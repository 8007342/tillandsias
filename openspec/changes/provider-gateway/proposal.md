## Why

Today every forge holds each agent CLI's full provider sign-in file, refresh
token included. An agent inside the forge, or anything it runs, can read that
file and take the operator's subscription sign-in with it. Order 2080 (the
credential harvest audit, row 2080-7euu) removes the forge's ability to write a
sign-in back to Vault as an interim step. The forge can still read and copy it.

A provider gateway removes the copy. The forge CLI is pointed at a local
gateway (for example `ANTHROPIC_BASE_URL`) and holds only a placeholder
credential. The gateway runs outside the forge. It swaps in the real token and
forwards the request upstream.

Operator direction 2026-11-11: the gateways are simple standalone components,
as simple and transparent as possible, documented as such and implemented
transparently. They handle credentials, so they must be reachable only from
the forges they serve. Their only Vault interaction is small cached reads, plus
writing back a refreshed token.

## What Changes

- One small standalone gateway binary per host (or per forge network), written
  in Rust or Go. No bash, python or jq anywhere in the gateway path.
- One upstream per provider: Claude, Codex, Copilot, OpenCode. Each provider is
  enabled only after its spike (order 2081) records a "yes".
- The gateway listens only on the forge's network. A request's peer identity is
  the network or socket it arrived on. No other identity scheme exists.
- No admin API. No logging of headers or bodies.
- The real token is cached in memory with a TTL. Refresh is serialized, so one
  refresh runs at a time per provider, and the result is written back to Vault.
- Forges get a placeholder credential and a base-URL setting instead of the
  sign-in file. A cleanup step per provider removes the forge's read-only copy.
- A documented threat model and a one-page "how it works" readme ship with the
  binary.

## Non-goals

- Agents never start a sign-in. The operator signs in from the tray. When no
  token exists, the gateway refuses with a message pointing at the tray.
- No plaintext credentials at rest, in the gateway or anywhere else.
- No request rewriting beyond the credential header, no response caching, and
  no rate limiting or quota logic.

## Impact

- New component: `provider-gateway` (a Rust crate or Go module, decided in
  design.md D2).
- Forge launch: an env and config change per provider (base URL plus
  placeholder).
- Vault: a read-and-refresh policy scoped to the provider sign-in paths, held
  by the gateway alone.
- Retires the forge read grant that 2080-7euu keeps (decision D2 of
  plan/issues/credential-harvest-audit-2026-11-11.md).
