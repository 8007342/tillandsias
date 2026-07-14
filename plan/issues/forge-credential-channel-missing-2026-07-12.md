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

## 2026-07-13 re-derivation (unattended cold e2e, macOS, tray git 66d8b134)

BigPickle's in-forge meta-orchestration cycle (23:08Z) re-derived this
blocker unchanged on a freshly destroyed + reprovisioned substrate:

- The forge entrypoint BANNER claims `git push origin <branch> routes to
  the enclave mirror (tillandsias-git:8080)` — but the shared checkout's
  `origin` still resolves to `https://github.com/8007342/tillandsias.git`
  and pushes fail. Banner and reality disagree; the order-315 audit's
  platform matrix (no `write_forge_gitconfig` equivalent on the macOS VM
  forge) remains accurate. Fix path: order 320 (single gitconfig
  injection point, all platforms).
- Deeper on cold substrates: `--exec-guest … --init` ended with
  `Error bringing Vault up: running in VM but no root token delivered
  from host` — by design (order 114) the vault token arrives only via the
  tray's vsock DeliverCredentials, and no GitHub login has ever run on a
  destroyed substrate. So even with origin→mirror fixed, the mirror has
  no credential to relay with until a login seeds the vault. Unattended
  cold-substrate in-forge pushes are structurally impossible until orders
  320 + 303/304 land AND a login has seeded the vault.
- Evidence: target/build-install-smoke-e2e/20260713T224400Z/
  04a-exec-guest-init.log + 04b-bigpickle-meta-orchestration.log (host);
  BigPickle's own cycle summary reported the same root cause and
  smallest-next-action as this file.
