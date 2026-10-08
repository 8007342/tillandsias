# The GitHub token rotates itself before it expires

## Why

The Tlatoāni, 2026-09-28: "The vault's token keeps expiring every 8 hours as
expected, looks like we're missing the automatic token rotation. Make sure to
file ./plan and specs to keep that token alive automatically".

GitHub App user-to-server access tokens expire after 8 hours; the device login
also returns a refresh token (about six months) that mints the next pair. The
live spec (gh-auth-script, "Token Rotation and Expiration Management") already
REQUIRES automatic rotation — "WHEN an access token nears expiration (within
30 minutes) … THEN the system MUST exchange the refresh token" — and the
single-use-safe exchange exists (`rotate_github_token_locked`, 1383-5hpk). What
does not exist is anything that RUNS it: the only caller is the explicit
`tillandsias --refresh-github-token`, and that refuses without a desktop
session. So every 8 hours the token expires, every mirror push is refused
upstream (measured 2026-09-28: macuahuitl-forge twice in one day,
blocked:upstream-push-unauthorized), and the operator re-seeds by hand.

A second defect keeps the gate shut after the fix: check-credential-channel
reads the mirror's last PUBLISHED upstream-auth verdict, and a later successful
push did not overwrite a `denied` one (macuahuitl-forge, same day). A worker
obeying the gate idles after the credential is healthy again.

## What Changes

- A due-check runs in the resident process that holds this installation's
  Vault client: the Linux tray; on macOS and Windows the guest's resident
  service (the same loop that runs the order-276 login tick). At start and at
  least every 15 minutes it rotates when `expires_at - now <= 30 min`, through
  the existing locked exchange. Nothing about the exchange changes.
- The desktop-session gate stays on the EXPLICIT forced rotation. The due-check
  is allowed without a session because it spends the refresh token only when
  the access token is due, and only under the host's exclusive lock. Forges
  never rotate: their policy cannot read `secret/github/refresh`.
- Every consumer reads the token at use time and never caches past its
  `expires_at`, so a rotation reaches the mirror's next push.
- Refresh-token expiry is visible: 14 days before `refresh_token_expires_at`
  the tray says so, with the one action (`tillandsias --github-login`).
- A failed rotation retries with backoff until the access token expires, and
  the credential verdict then names the cause
  (`blocked:github-token-rotation-failed:<reason>`), never a bare 401.
- The mirror's published upstream-auth verdict is overwritten by the next
  upstream outcome, success included.

## Impact

- Spec: gh-auth-script (MODIFIED "Token Rotation and Expiration Management";
  ADDED the scheduler, the consumer rule, refresh-expiry visibility) — delta
  below. git-mirror-service for the published-verdict overwrite.
- Code: crates/tillandsias-headless (tray + guest service loop, vault_bootstrap),
  the mirror's upstream-auth publisher, scripts/check-credential-channel.sh.
