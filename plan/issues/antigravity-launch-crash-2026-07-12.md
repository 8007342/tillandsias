# Antigravity lane crashes instantly on tray launch

- Date: 2026-07-12
- Class: exploration (work packet — order 307)
- Filed by: linux_mutable meta-orchestration cycle (operator repro)

## Operator repro (2026-07-12, local build, fresh --init)

Tray → Antigravity: the lane window "crashed right away". No error was
readable because agent entrypoints had no exit pause — the popup closed with
the container.

## This cycle's changes (observability + likely contributing fixes)

- All agent entrypoints now trap EXIT and pause on non-zero exit
  ("Press any key…", mirroring entrypoint-terminal.sh), so the NEXT repro
  shows the real error instead of a vanishing window.
- `GIT_SSL_CAINFO` now points at the combined CA bundle in every forge lane
  (git/libcurl ignored `SSL_CERT_FILE` and the injected gitconfig pinned the
  enclave-CA-only file) — fixes any git-over-HTTPS step in the agy installer
  path.

## Candidate root causes (in likelihood order)

1. **No Gemini/Antigravity credential**: operator never completed an
   Antigravity login; vault has no `GEMINI_API_KEY`, so `agy` may exit
   immediately demanding auth → the login-flow packet
   (`plan/issues/agent-login-flows-vault-2026-07-12.md`) is the real fix.
2. `agy` installer failure (fetch/unpack) leaving `agy` absent → `exec agy`
   fails; the entrypoint traces but (pre-fix) the window closed unreadably.
3. `--dangerously-skip-permissions` flag drift in a newer agy release
   (flag verified against agy --help 2026-07-06; EVERY_LAUNCH @latest install
   means upstream can break us any day).

## Exit criteria (order 307)

- Reproduce with the new exit-pause trap and capture the actual error text
  into this file.
- Root cause identified and either fixed or split into the owning packet
  (login flows → order 303/304).
- Antigravity lane launches to a usable TUI on a host with a valid Gemini
  credential in the vault.
