# Podman idiom spec contradicts scoped forge Vault capabilities

- Packet: `podman-idiomatic-forge-secret-contract-drift`
- Order: 461
- Status: ready
- Desired release: v0.5
- Owner host: any
- Filed: 2026-07-23 during order429 result-channel repair

## Observation

`openspec/specs/podman-idiomatic-patterns/spec.md` says forge containers MUST
receive no `--secret` flags. That is false for the current, intentional
least-privilege design:

- `openspec/specs/podman-secrets-integration/spec.md` explicitly permits
  provider one-shots and credentialed forge containers to receive short-lived
  per-container Vault AppRole capability secrets.
- OpenCode and OAuth-backed forge lanes mount those scoped capability documents
  and derive provider material inside the container.

The contradiction makes either compliant production behavior fail the generic
spec or makes the generic spec silently untrustworthy. No behavior was changed
while observing this drift.

## Proposed reconciliation

Preserve the security intent by distinguishing credentials from capabilities:
forge lanes remain free of long-lived provider credential bytes and MUST NOT
receive raw provider tokens through argv/environment, while an explicitly
credentialed lane MAY receive a short-lived, least-privilege Vault capability
secret authorized by `podman-secrets-integration`.

Operator/spec review should choose the final wording, update the generic
scenario and invariant together, and keep the narrower secret-integration spec
authoritative for allowed roles, paths, TTL, and mount shape.

## Exit criteria

- The two active specs make the same claim about scoped forge AppRole secrets.
- A litmus distinguishes forbidden raw provider credentials from allowed
  short-lived Vault capability mounts.
- Existing OpenCode/OAuth forge mounts either satisfy the reconciled wording or
  fail a named, falsifiable check.
