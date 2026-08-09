# blocked: no-credential-channel — Esmeralda windows host, 2026-08-09

Filed by the meta-orchestration cycle (windows host, branch windows-next).

- **Verdict**: `scripts/check-credential-channel.sh` → `missing:no-credential-channel`
  (exit 1) at 2026-08-09 ~04:1xZ. `gh auth status`: "The token in keyring is
  invalid" for account 8007342. `gh api` calls return HTTP 401.
- **Evidence of prior health**: this same host pushed windows-next e1aef8b8 and
  linux-next 58de3558 successfully ~1h earlier via the gh credential helper —
  the token was invalidated between 2026-08-09T03:47Z and 04:10Z (window
  includes the v0.4.260809.1/.2 release automation runs).
- **Impact**: committable work on this host is blocked per the meta-orchestration
  Credential Channel Guard; the curl-install e2e gate proceeded read-only
  (release asset downloads are public and need no auth). This blocker file and
  the gate findings are queued locally until the channel returns.
- **Owner**: operator (bulloncito).
- **Smallest next action**: run `gh auth refresh -h github.com` interactively on
  this host (device flow), then re-run `scripts/check-credential-channel.sh`
  expecting `ok:*`, then push the queued windows-next commits.

## RESOLVED 2026-08-09 ~05:0xZ

Operator ran `gh auth refresh`; `check-credential-channel.sh` → `ok:gh-keyring`
(exit 0). Queued findings + this blocker pushed with this commit. Root cause of
the invalidation window (03:47Z–04:10Z, overlapping the release automation)
remains unidentified — if a second invalidation coincides with a release run,
file it as a pattern.
