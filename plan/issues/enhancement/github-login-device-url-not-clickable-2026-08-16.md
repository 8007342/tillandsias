# GitHub login: the device-flow URL is not clickable in the login terminal

- classification: enhancement
- filed: 2026-08-16 (windows/Yolanda, operator-attended session)
- status: open
- cross-ref: 648-e5pf (github-login-prompts-for-an-unneeded-token),
  777-kyjp (github-login-device-flow-only — device flow is now the ONLY
  GitHub auth flow per the 2026-08-16 operator directive, which makes this
  URL the single load-bearing step of every GitHub login)

## Observation

Operator's live GitHub login run, 2026-08-16 ~13:30 local (20:30Z): the
`github.com/login/device` URL printed in the login terminal is plain text —
no OSC-8 hyperlink, no auto-open. The operator hand-copied it into the
browser; the one-time code then worked.

## Why this matters

With the device flow ruled the only auth path (777-kyjp), every GitHub
login funnels through this URL. Hand-copying a URL out of a terminal is
exactly the kind of small friction that compounds on headless-adjacent
hosts and in screen-sharing sessions.

## Small UX packet candidate

- Emit the URL as an OSC-8 hyperlink (terminals that do not support it
  render the plain text unchanged), or auto-open the default browser where
  a GUI session exists.
- Keep the one-time code on its own line for easy copy.
