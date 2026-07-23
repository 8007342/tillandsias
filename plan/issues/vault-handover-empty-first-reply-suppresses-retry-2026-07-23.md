# Empty first Vault handover reply must not suppress later first-boot retries

**Filed:** 2026-07-23T04:20:47Z  
**Host:** forge  
**Classification:** bugfix  
**Status:** completed  
**Packet:** `vault-handover-empty-first-reply-suppresses-retry`

## Finding

Commit `0efd14b9` correctly stopped paying the eight-second
`GetVaultHandover` poll on every steady-state wire connection, but its first
implementation set `HANDOVER_DELIVERED=true` whenever the handler replied.
That included an empty reply after the first eight-second timeout.

The first-boot comment at the handler explains why an empty result is not
terminal: Vault initialization may still be producing the Shamir share the
host must save. Marking an empty result delivered made every later connection
skip the retry window for the rest of that headless process.

## Fix

Keep the performance gate, but close it only after a reply actually contains a
non-empty unseal share. Empty and root-token-only replies remain eligible for a
later bounded first-boot poll; after a real share is sent, all later
steady-state connections still answer immediately.

## Evidence

- focused Vault handover classification and handler-wiring tests
- `cargo test -p tillandsias-headless` — 242 passed, 1 ignored; all integration
  targets passed
- `cargo run -q -p tillandsias-policy -- validate-yaml plan/index.yaml`
- `./build.sh --check`
