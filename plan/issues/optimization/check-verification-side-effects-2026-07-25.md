# Verification commands have surprising scope and host side effects

- **Date**: 2026-07-25
- **Classification**: optimization
- **Status**: open
- **Observed by**: order 463 delegated implementation worker

## Findings

`./build.sh --check` rewrites `~/.config/containers/registries.conf` and creates
a timestamped backup before performing formatting, type-check, and clippy. A
check-only command therefore mutates host configuration even when no container
build is requested.

`./build.sh --ci --strict --filter tillandsias-vault` expanded beyond the named
spec into broad repository checks, regenerated empty CentiColon dashboards, and
failed on unrelated ledger/cheatsheet drift. The worker removed the generated
dashboard changes and used the direct scoped litmus command for valid order 463
evidence.

## Reduction

- `./build.sh --check` MUST not deploy or back up host registry configuration;
  move that setup behind a build/install phase that actually needs Podman.
- A strict filtered CI invocation MUST report the effective scope before work
  and MUST not regenerate broad dashboards outside that scope.
- Add fixtures that snapshot the host registries file and repository dashboard
  paths before each command and fail if either command changes an out-of-scope
  path.

This is not a v0.4 release blocker because order 463 has independent focused
evidence and the full check completed successfully; it is recurring automation
friction for a later optimization packet.
