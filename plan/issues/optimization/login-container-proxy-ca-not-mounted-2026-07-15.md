# Login container: "[trust] WARNING: runtime proxy CA is not mounted; using vendor roots only"

- Date: 2026-07-15
- Class: optimization
- discovered_by: operator running `tillandsias --agy-login` (also visible on
  the successful --codex-login/--claude-login runs)

## Observation

The ephemeral provider-login container starts without the enclave proxy CA
bind-mount, so lib-common's trust setup warns and falls back to vendor
roots. Logins still WORK (claude/codex device flows succeeded — egress from
the login container evidently doesn't traverse the MITM bump, or the
touched hosts are passthrough), but:

1. The warning is noise on every login and reads like a failure.
2. If the login container's egress ever IS routed through the bump proxy,
   the agy installer download and npm harness installs would start failing
   TLS — silently coupled to network topology.

## Smallest next action

Mount the CA into the login container the same way forge lanes get it
(`/run/tillandsias/ca-chain.crt` bind), or suppress the warning for the
login lane if direct egress is the intended topology (state it, don't warn
it). Order-320's single-injection work is the natural home.
