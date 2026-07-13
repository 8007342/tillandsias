# Forge .gh-credentials owned by root, unreadable by forge user

- Date: 2026-07-13
- Class: enhancement (optimization)
- Discovered by: forge meta-orchestration cycle (order 307)

## Symptom

`git push origin linux-next` from the forge fails with `fatal: could not read
Username for 'https://github.com': No such device or address`. The credential
helper `store --file=.git/.gh-credentials` cannot read the file because it is
owned by `root:root` (mode `0600`) and the forge process runs as `forge`
(uid 1000).

`scripts/check-credential-channel.sh` reports `ok:gh-credentials-store` because
the file exists and is non-empty — but the check only verifies presence, not
readability by the current user.

## Impact

- Forge cannot push directly to GitHub origin; must rely on the git mirror
  relay (`git://tillandsias-git/tillandsias` → GitHub).
- The mirror relay works (verified in prior cycles), so this is a resilience
  gap, not a hard blocker.
- If the mirror is down, the forge has no direct push path.

## Fix options

1. **Chown the credentials file** after seeding: `chown forge:forge .git/.gh-credentials`
   in the forge entrypoint or initialization.
2. **Make the credential channel check verify readability**, not just presence:
   add a `-r` test to `scripts/check-credential-channel.sh`.
3. **Use `GH_TOKEN` env var** instead of the file-based credential helper
   (simpler, no file ownership issue).

## Owner

Operator (credential seeding is outside the forge container's write scope).
