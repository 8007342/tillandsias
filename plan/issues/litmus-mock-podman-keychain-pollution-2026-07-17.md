# P1: mocked-podman test runs write into the REAL host keychain — operator credential pollution

- Date: 2026-07-17
- Class: enhancement (test-harness isolation; credential safety)
- Filed by: linux-macuahuitl-fable5-20260717T1747Z (order 383 root-cause analysis)
- Related: order 383 (vault-root-token-rederivation, the symptom this caused),
  scripts/test-support/podman-mock.sh,
  plan/issues/vault-unseal-secret-storage-crash-skew-2026-07-16.md

## What happened (live forensic, macuahuitl)

The operator's real `service=tillandsias` keychain entries
`vault-root-token-v1` and `vault-shamir-share-v1` were found holding the
literal string `mock-exec-output` — the canned exec reply from
`scripts/test-support/podman-mock.sh`. Mechanism:

1. A litmus/e2e run pointed podman at the mock backend but left the OS
   keychain (secret-service) UN-mocked.
2. The mock answered `podman exec … cat /run/vault-handover/root.token`
   and `…/unseal.key` with `mock-exec-output` + exit 0.
3. `read_and_handover_root_token` treated that as a fresh first-boot
   handover and — by design ("handover overwrites stale keychain state")
   — wrote both values over the operator's REAL credentials.
4. The real vault then rejected every root-token write
   (`permission denied / invalid token`) while its storage stayed
   healthy: order 383's linux real-secret repro.

## Mitigation landed (072f6efb, order 383)

`handover_pair_is_persistable` now refuses to persist any handover pair
that is not a Vault service token (`hvs.`/`s.` prefix) plus a 32-byte
base64 share, and the generate-root self-heal seam recovers a wedged
host from the stored share without touching storage. The symptom class
is closed; the ISOLATION gap is not.

## Reduction ask (open)

1. Test harnesses that mock podman MUST also isolate the keychain: a
   `TILLANDSIAS_KEYCHAIN_SERVICE` (or equivalent) override the litmus
   runner sets to a throwaway service name, or a mock `secret-tool`/
   secret-service on the litmus PATH. No test may be ABLE to write
   `service=tillandsias` on a developer/operator host.
2. Verifiable closure: a litmus that runs the vault bootstrap surface
   under the podman mock and asserts the real service name was never
   written (query the keychain after; expect zero `tillandsias` writes).
3. Sweep other keychain writers (`keychain_set_blocking` callers,
   installation anchor) for the same exposure.

## Operator recovery recipe (proven on macuahuitl)

The live container's mounted unseal secret IS the Shamir share while the
vault is up: `podman exec tillandsias-vault sh -c 'base64
</run/secrets/tillandsias-vault-unseal'` (44 chars) → restore to the
keychain → the order-383 seam self-heals the root token on the next
vault bring-up.
