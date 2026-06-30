# Vault podman-exec Reads Missing Env — Headless + Tray Broken Since HTTP→exec Move

**Status:** `completed`
**Owner:** linux
**Date:** 2026-06-27
**Severity:** CRITICAL — headless + tray credential reads silently fail
**Trace:** `spec:tillandsias-vault`, order 113 follow-up

## Symptom

Linux headless and tray have been failing since host-side Vault reads moved from
the HTTP Vault client to `podman exec` (order 113, "eliminate raw credential
reads from host"). The tray shows perpetually logged-out even after a successful
GitHub login, and forge provider API-key injection silently gets no keys.

## Root Cause

`vault_kv_get_via_exec` and `is_github_key_present` ran:

```
podman exec tillandsias-vault vault kv get -field=token secret/github/token
```

with **no environment**. But `podman exec` does **not** inherit the container
entrypoint's environment, so inside the exec there is no `VAULT_ADDR`, no
`VAULT_TOKEN`, and no `VAULT_SKIP_VERIFY`/`VAULT_CACERT`. The exec'd `vault` CLI
therefore:

1. defaults to `https://127.0.0.1:8200` and fails TLS verification against the
   self-signed cert — `Get "https://127.0.0.1:8200/...": x509: certificate
   signed by unknown authority`;
2. even with TLS bypassed, has no token — `missing client token`.

Confirmed empirically — the real exit code was **2** (an earlier `$?` read the
exit of a piped `sed`, masking it):

```
$ podman exec tillandsias-vault vault kv get -field=token secret/github/token
Get "https://127.0.0.1:8200/v1/sys/internal/ui/mounts/secret...   # exit 2
```

`is_github_key_present` (the tray's 120×1s post-login poll) thus **always**
returned `false`; `read_provider_api_key` (forge key injection) always errored.

Writes were unaffected because `write_provider_api_key` / `store_github_token`
still use the HTTP `VaultClient` (published port `:8201`, skip-verify in the
client). Only the *read* path was moved to exec — so the system was a broken
half-migration.

## Fix

New `vault_exec_command(root_token, vault_args)` builds the `podman exec` with the
env the CLI needs but exec does not inherit:

- `-e VAULT_ADDR=https://127.0.0.1:8200` — the loopback TLS listener
- `-e VAULT_SKIP_VERIFY=true` — self-signed cert; the request never leaves the
  container loopback, so verification is moot (not a network hop)
- `-e VAULT_TOKEN` — **name-only passthrough**: the root token is set in the
  podman process's environment (`command.env`) and forwarded by name, so it
  never appears in the exec argv (not visible in `ps`)

The root token comes from `read_and_handover_root_token` — the same accessor the
HTTP write path already uses; the host legitimately holds Vault's root token
(that is not a stored secret value, and order 113's "host never reads raw
credential values" model is preserved — the github token still only surfaces as
the exec stdout during injection).

Both `vault_kv_get_via_exec` and `is_github_key_present` route through the helper.

## Verification

End-to-end against the running Vault container:

```
# before: exit 2 (TLS / missing token) regardless of whether a token exists
# after:
$ VAULT_TOKEN=<root> podman exec -e VAULT_ADDR=https://127.0.0.1:8200 \
    -e VAULT_SKIP_VERIFY=true -e VAULT_TOKEN tillandsias-vault \
    vault kv put secret/github/token token=...        # version 1
$ ... vault kv get -field=token secret/github/token ; echo $?
ghp_...                                               # exit 0  → tray sees authed
$ ... vault token lookup                              # display_name: root, exit 0
```

Pinned by unit test `vault_exec_command_sets_required_env_and_hides_token`
(asserts VAULT_ADDR + VAULT_SKIP_VERIFY + name-only VAULT_TOKEN present, token
absent from argv, token present in process env).

## Why CI/tests didn't catch it

Order 113 swapped HTTP reads for `podman exec` but had no test exercising the
exec against a TLS-enabled, token-gated Vault container. The unit tests mocked
nothing about the exec environment. Bar-raise candidate: an e2e gate that runs a
real login + `is_github_key_present` round-trip against a live Vault container.

## Related

- `plan/issues/vault-credential-host-exposure-audit-2026-06-27.md` — order 113 (the move that introduced the regression)
- `hardcoded-ip/remove-port-publish` — still blocked; this fix keeps reads on
  exec (the forward direction) so removing the published port stays viable.
