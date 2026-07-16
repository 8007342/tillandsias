# P1: interrupted vault bootstrap rotates the unseal secret without re-initializing storage — permanent unseal 400 wedge

- Date: 2026-07-16
- Class: bugfix (crash-consistency; vault bootstrap)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-16T07:31Z
- Discovered by: live `--list-cloud-projects` on the fresh 0.3.260716.5 guest (macOS VZ)
- Related: order 235 R7 (recreate/lease-holder lock + transient health retry), c40db47a (the Tokio panic fix that exposed this), plan/issues/macos-build-findings-2026-07-16.md

## Failure chain (deterministic once entered)

1. A vault bootstrap run was killed mid-recreate — in this repro by the
   order-235 R7 backoff panic (`tokio::time::sleep` constructed as a
   `block_on` argument on a non-runtime thread; fixed in c40db47a), but ANY
   crash/SIGKILL in that window produces the same state.
2. The interrupted run had already rewritten the `tillandsias-vault-unseal`
   podman secret (observed: secret `UPDATED 44 seconds ago` vs
   `tillandsias-vault-data` volume `CREATED 2 days ago`) without wiping or
   re-initializing the storage volume.
3. Every subsequent boot: entrypoint logs `subsequent boot: using unseal key
   from secret` → `unsealing vault` → `curl: (22) ... error: 400` (key does
   not match storage) → container exits → headless reports
   `vault container did not report healthy` … `container is stopped`.
   The wedge is permanent; no retry can clear it.

## Recovery used (macOS guest, 2026-07-16)

Vault held no secrets yet (github token was 404), so a clean reset was
lossless: `podman rm -f tillandsias-vault`, `podman volume rm -f
tillandsias-vault-data`, `podman secret rm` of `tillandsias-vault-unseal`,
`tillandsias-vault-tls-{cert,ca,key}`, and stale
`tillandsias-vault-token-git-mirror-*` mints, plus
`/root/.cache/tillandsias/{vault-data,fallback_vault-root-token-v1,fallback_vault-shamir-share-v1}`.
Next bootstrap re-initialized cleanly (11 policies, images ensured
on-demand at v0.3.260716.5).

## Reduction ask (owner: linux, vault_bootstrap seam)

1. Make unseal-secret rotation and storage (re)initialization a single
   crash-ordered step: write the new unseal key to the secret ONLY AFTER
   the storage it unseals exists (or stage to a temp secret name and
   rename-commit last).
2. Self-diagnose the skew: on unseal 400 with an existing data volume,
   report "unseal key does not match vault storage (interrupted bootstrap?)"
   with the two artifact timestamps, instead of the generic
   `did not report healthy`. If the vault is known-empty (no successful
   secret write ever recorded), offer/perform the lossless reset above
   automatically.
3. Verifiable closure: a litmus that kills the bootstrap between secret
   rotation and storage init, then asserts the next boot either recovers
   or emits the skew diagnosis (not the permanent generic wedge).
