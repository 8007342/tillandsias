# Podman Reset Harness Policy - 2026-06-16

Status: completed
Owner: linux-next

## Completed

- Set `TILLANDSIAS_DESTRUCTIVE_RESET_OK=1` by default in the repeat harness and
  Codex Tillandsias profile.
- Updated `/meta-orchestration`, `/build-install-and-smoke-test-e2e`, and
  `/smoke-curl-install-and-test-e2e` so Podman reset is treated as expected test
  setup on Tillandsias smoke hosts.
- Updated agent-facing e2e metadata and active smoke work packets to avoid
  stopping for reset confirmation.

## Policy

`podman system reset --force` is a required precondition for Linux idempotence
smoke tests. Agents must not pause, skip, or mark a skill blocked because the
reset is destructive when `TILLANDSIAS_DESTRUCTIVE_RESET_OK` is unset or `1`.
The only supported opt-out for a non-smoke host is
`TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, which must produce a pushed plan blocker.
