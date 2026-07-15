# Forge terminal lane: `agy` and `brew` not on PATH

- Date: 2026-07-15
- Class: optimization
- discovered_by: operator (maintenance/terminal lane, 2026-07-15)

## Observation

From the forge terminal lane the operator reports `agy` and `brew` are "not
available (or not in the path)". Signing into Claude/Codex works and OpenCode
works, so the agent harnesses resolve — but:

- `agy` (Antigravity CLI) installs to `/home/forge/.local/bin/agy` at the
  antigravity lane launch, but the TERMINAL lane never runs
  `require_antigravity`, and `/home/forge/.local/bin` may not be on the
  terminal PATH.
- `brew` bootstraps into a userspace prefix; its shellenv (`brew shellenv`)
  may not be evaluated in the terminal lane's shell rc, so `brew` isn't on
  PATH even after the first-use bootstrap ran.

## Smallest next action

- Ensure `/home/forge/.local/bin` and the brew prefix `bin` are on PATH for
  ALL lanes (add to lib-common PATH export / fish + bash rc), so tools
  installed by one lane are discoverable in the terminal.
- Consider running `require_antigravity` (now shared in lib-common) lazily
  from the terminal lane too, or documenting `tillandsias --agy-login` /
  the agy lane as the install trigger.
- Pairs with order 359 (github token injection) since brew needs the token to
  install attested bottles at all.
