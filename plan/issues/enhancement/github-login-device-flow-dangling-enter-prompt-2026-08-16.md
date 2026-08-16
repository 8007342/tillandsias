# GitHub login: after device-auth completes in the browser, the terminal stays blocked awaiting ENTER

- classification: enhancement
- filed: 2026-08-16 (windows/Yolanda, operator-attended session)
- status: open
- cross-ref: 648-e5pf (github-login-prompts-for-an-unneeded-token) — same
  login flow, adjacent defect; first-Windows-reproduction evidence recorded
  as a progress event on that packet
  (plan/index.d/20260816t211500z-648-e5pf-windows.yaml)

## Observation

Operator's live GitHub login run, 2026-08-16 ~13:30 local (20:30Z),
windows/Yolanda: after the browser device-auth flow completed — the browser
page said the login was done and it was ok to close — the login terminal
stayed blocked, awaiting ENTER. The login itself had already succeeded; the
flow does not self-detect device-auth completion, leaving a dangling
interactive prompt on an otherwise-completed login.

## Why this matters

The user is told (by the browser) that they are done, while the terminal
holds the login open on a keypress nobody knows is needed. On an unattended
or half-watched host this presents as a hung login. It is the same
promise-vs-flow mismatch family as 648-e5pf: the interactive surface makes
a claim the actual flow does not honor.

## Smallest next action

Make the login flow poll/detect device-auth completion and proceed without
the ENTER, or — minimally — have the prompt say that ENTER is required
after completing the browser step so the terminal's claim matches the
flow's reality.
