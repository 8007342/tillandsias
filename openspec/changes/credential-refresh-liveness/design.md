# Design — credential-refresh-liveness

## Failure classes to separate

A log line saying a token failed can mean any of these, and the remedies differ:

1. **No refresh ran**: nothing was due, or nothing is responsible for this credential.
2. **Refresh could not read the store**: the measured GitHub case, `read:vault-unavailable`.
3. **The provider refused**: revoked, expired refresh token, or a single-use refresh token already spent.
4. **Refreshed but not stored**: the new token was lost, which is severe when refresh tokens are single-use.
5. **Stored but not propagated**: a consumer holds an old copy.
6. **The consumer lost its route to the store**: the mirror's Vault client token after a Vault restart (1998-mvrs).

## Measured so far (macuahuitl, 2026-11-04, PST)

- 45 GitHub rotation failures with `read:vault-unavailable` in the journal since 10:02, on every attempt seen.
- In the same window Cloudflare rotation succeeded three times, so the tray could reach Vault at least some of the time. This is the discriminating fact to explain: same process, same store, different result.
- The mirror reached Vault through its own Agent while the tray's GitHub read failed.
- GitHub refused the mirror's token from 15:55:56. That a token lifetime expired because rotation never ran is the leading hypothesis, not established.
- At 21:15, after the Vault restart, both GitHub and Cloudflare rotation reported `vault-unavailable`.

## Open questions (research row 1999-crsr answers these)

1. Why does the GitHub read fail while Cloudflare rotation succeeds?
2. What lifetime does each stored token have, and what is its refresh token's rule?
3. For Claude and Codex, which file or process owns refresh inside a forge, and how does a rotation get back to Vault? Sibling forges share an account: can one spend a refresh token another still holds?
4. What are the bleeding lines in long-running forges? Collect them verbatim per provider and classify them.
5. Does a re-seed reach a running consumer, for each consumer?

## Constraints

- No plaintext credentials at rest, and none printed.
- Fail closed stays. Liveness work must not add a fallback that weakens a credential gate.
- Polling cadence stays as approved; prefer events to faster polls.
- A forge log is ephemeral and not the operator's channel.
