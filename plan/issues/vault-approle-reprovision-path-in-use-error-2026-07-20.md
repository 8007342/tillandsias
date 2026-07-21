# Vault AppRole re-provision logs an ERROR because the auth path is already enabled (2026-07-20)

- order: 455
- status: ready
- **Class**: enhancement (idempotency hygiene) — not v0.4-blocking
- **Severity**: P3
- **Found**: live persisted-state restart, 2026-07-20T22:21:12Z
- **Owner host**: linux

## Symptom and concrete evidence

Immediately after Vault reported `vault is unsealed and serving (provisioning
persisted from a prior boot)` during a restart with persisted provisioning, its
entrypoint logged this ERROR-level line:

```text
ERROR error occurred during enable credential: path=approle/ error="path is already in use at approle/"
```

The error was observed live at 2026-07-20T22:21:12Z. Vault continued serving,
so this is not currently a boot failure.

## Leading hypothesis and confirmation

The provisioning script likely calls `vault auth enable approle`
unconditionally on every boot. Inspect the entrypoint's persisted-provisioning
path and confirm that the enable operation is not preceded by a `vault auth
list` check for `approle/`. Reproducing two starts against the same Vault data
volume should produce the error on the second start under the current code.

## Blast radius

The operation is harmless today, but the genuine ERROR-level log trains
operators and automation to ignore errors during security-service bootstrap.
It also makes future fail-on-error hardening unsafe: converting the entrypoint
to stop on Vault CLI errors would turn an ordinary persisted-state restart into
a crash.

## Smallest correct fix and exit criteria

Guard `vault auth enable approle` with an auth-list check and enable it only
when `approle/` is absent. Verify idempotency by starting the Vault container,
allowing provisioning to persist, and then restarting it twice against the
same state. Both consecutive persisted-state restarts must finish serving and
the Vault entrypoint logs must contain zero `ERROR` lines.
