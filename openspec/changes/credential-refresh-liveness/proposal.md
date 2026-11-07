# Proposal — credential-refresh-liveness

- **Builds on:** `github-credential-health`, `secret-rotation`, `tillandsias-vault`, and the rotation schedulers (orders 1461-8tyy, 1505-iysn).
- **Design only.** No code lands with this change. Research row 1999-crsr answers the open questions in `design.md` first.

## Why

Operator, 2026-11-05: long-running forges bleed log lines about failing tokens, such as an expired Codex login. The reading is that our tokens fail to refresh, or that we fail to store and propagate the refreshed token.

One instance is measured. On macuahuitl the tray logged `blocked:github-token-rotation-failed:read:vault-unavailable` on every 15-minute attempt from at least 10:02 PST on 2026-11-04. GitHub began refusing the mirror's token at 15:55:56 PST, and nobody was told until a push failed five hours later (`plan/issues/git-mirror-credential-outage-2026-11-04.md`).

## What changes

- One credential inventory: every token we hold, who refreshes it, where the refreshed copy is stored, and who consumes it.
- A health state for each credential, derived from what a real attempt returned.
- A failed refresh reaches the operator once, in plain words, while there is still time to act. It does not repeat in a forge's log.
- A refreshed or re-seeded credential reaches running consumers without restarting them.
