# Abandoned provider-login one-shot containers are never reaped (2026-07-12)

- class: bug (lifecycle hygiene / resource leak; end-user facing)
- found by: operator attended smoke (windows-bullo-fable5-20260712T1940Z),
  straggler audit requested by The Tlatoāni
- status: open
- trace: provider-login one-shot lanes (orders 287/303/304 family),
  is_active_lane_container predicate (order 289 counts login one-shots as live)

## Symptom

`tillandsias-codex-login-12981` was still **Up 2 hours** after the operator
abandoned its token prompt (closed/ignored the popup terminal). Login
one-shots have no idle timeout and no reaper tied to their terminal's
lifetime, so every abandoned prompt leaks a running container indefinitely.
Compounding: order 289 deliberately counts provider-login one-shots as
"active lanes", so a leaked login container ALSO pins the shared
proxy/inference stack up forever (defeats the no-lanes teardown).

## Fix direction

- Tie the one-shot's lifetime to its interactive session: when the PTY/
  terminal detaches (wsl.exe bridge exits), stop the container.
- Belt-and-braces: an idle timeout inside the login one-shot itself (no
  credential input for N minutes → exit with a clear message).
- A periodic reaper for `*-login-*` containers older than the timeout.

## Repro

Launch Codex (no vault credential) → token prompt appears → close the
terminal without entering anything → `podman ps` shows the login container
running indefinitely.
