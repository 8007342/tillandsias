# Root cause: git-mirror relay loses push after ~1h — its approle vault-token TTL expires (not the GitHub token)

- Date: 2026-07-18
- Class: bug (credentials / forge robustness)
- Filed by: linux-macuahuitl-opus48 (operator "forge agents can't push" repro)
- Proposed order: 412 (coordinator to promote into plan/index.yaml —
  `git-mirror-relay-token-renewal`, `desired_release: v0.4`). Filed as a
  standalone issue because plan/index.yaml was being actively edited by a live
  forge agent at diagnosis time; do not entangle the shared ledger with an
  in-flight agent worktree.
- Related: order 319 (credential-helper-broker), the windows-260716
  mirror-credential series, order 383 (vault heal).

## Symptom (live, 2026-07-18)

Forge OpenCode agents could not push. The relay rejected with:

```
remote: [relay] HTTPS upstream credential is unavailable; run GitHub Login before pushing
remote: [pre-receive] Push rejected: configured upstream did not durably accept the ref transaction
 ! [remote rejected]   linux-next -> linux-next (pre-receive hook declined)
```

The order-392 implementation (`f7701ffd`) + its blocker filing (`00f15dff`)
were committed locally on `linux-next` but stuck — 2 commits ahead of origin.

## Root cause (nailed)

The GitHub token in Vault is FINE. The git-mirror container's own Vault access
expired.

- `secret/github/token` in Vault is VALID and push-capable: `GET /user` → 200,
  `GET /repos/8007342/tillandsias` → 200, `permissions.push = true` (verified
  against the GitHub API with the actual stored token).
- BUT inside the running `tillandsias-git-tillandsias` (Up ~1h),
  `vault-cli read auth/token/lookup-self` → **HTTP 403**: the mounted approle
  vault-token (`/run/secrets/vault-token`) has EXPIRED.
- `APPROLE_TOKEN_TTL_SECS = 3600` (1h); `APPROLE_TOKEN_MAX_TTL_SECS = 86400`
  (24h). The shared git-mirror container lives longer than 1h, and nothing
  renews its token.
- `images/git/relay-refs.sh` line ~61 reads the GitHub token via
  `vault-cli read -field=token secret/github/token 2>/dev/null || true`. With
  the mirror's vault-token expired, that read 403s → the `|| true` swallows it →
  `TOKEN=""` → line ~70 logs "HTTPS upstream credential is unavailable".

**Every forge session running past 1h silently loses push capability.**

## Workaround applied this cycle

The operator's HOST keyring token (`gho_`, scopes repo+workflow) is valid and
independent of the mirror. The stuck commits were pushed from the HOST
(fast-forward, secret-scanned): `origin/linux-next` is now current at
`00f15dff`.

**Immediate operator remedy to restore forge self-push:** relaunch the forge.
`build_git_run_args` uses `--replace`, so a fresh forge launch re-mints the
git-mirror approle lease and recreates the mirror container with a fresh
(unexpired) vault-token.

## Durable fix (proposed order 412 exit criteria)

1. A forge session running > 1h can still push: the git-mirror's vault access
   is renewed (the token is renewable to 24h) or re-minted before/on expiry —
   no 403 on lookup-self mid-session.
2. `relay-refs.sh` must not silently swallow a vault read-failure into a bare
   "credential unavailable": distinguish a 403/expired mirror token (→ renew /
   re-mint) from a genuinely-absent GitHub token (→ the real "run GitHub Login"
   case).
3. Litmus/behavioral: simulate an expired mirror token and assert the relay
   recovers (renew or re-mint) instead of failing the push.
