# Forge Credential Channel Missing

- **Date**: 2026-07-12
- **Status**: blocked
- **Blocked-by**: missing:no-credential-channel
- **Owner**: operator
- **Host**: forge

## Symptom

`scripts/check-credential-channel.sh` exits non-zero with
`missing:no-credential-channel`. The forge's git origin resolves to
`https://github.com/8007342/tillandsias.git` (public HTTPS) instead of the
enclave git mirror. Anonymous reads succeed but every push silently fails.

## Impact

All meta-orchestration cycles on this forge host are blocked — cannot commit
or push any work. This violates the Non-Negotiable Exit Contract
(no local-only commits).

## Smallest Next Action

Re-seed the forge gitconfig injection so `origin` resolves to the enclave
git mirror with an authenticated push channel. Options:

1. Ensure the forge container's gitconfig or `.git/config` points origin to
   the enclave mirror URL (e.g. `ssh://...` or the mirror's HTTPS endpoint
   with credentials).
2. Alternatively, inject `GH_TOKEN` or set `.gh-credentials` — but per the
   guard, the forge should NOT import host credentials; the mirror is the
   correct path.
