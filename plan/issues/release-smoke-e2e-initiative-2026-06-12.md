# Release Smoke E2E Initiative + Quality Findings — 2026-06-12

## Status

Active. Coordination record for the clean-room release-smoke initiative and the
quality findings surfaced during the 2026-06-12 vault credential-chain fix +
end-to-end git-mirror smoke test.

## Host Identity

- host_id: linux-macuahuitl-fedora
- platform: linux
- branch: linux-next
- agent_id: linux-macuahuitl-claude-2026-06-12T2124Z

## Observed Remote Heads (2026-06-12T21:24Z)

| Branch | Commit |
|---|---|
| `main` | b5bf7463 |
| `linux-next` | 53ce48b1 (before this coordination commit) |
| `windows-next` | 98acdbc6 |
| `osx-next` | ffa9864a |

## Context

Two things converged this session:

1. The `/smoke-curl-install-and-test-e2e` skill was authored (canonical at
   `skills/smoke-curl-install-and-test-e2e/SKILL.md`, registered in
   `methodology.yaml`). It is a clean-room acceptance gate that curl-installs a
   PUBLISHED release, wipes Podman, inits from scratch, runs the forge
   continuous-enhancement lane, and files every issue here as a work packet.

2. The uid-1000 vault-token credential-chain fix (`7e18d994`) and its real
   end-to-end git-mirror push smoke surfaced two unrelated quality issues worth
   tracking. Both are filed below as `ready` packets.

This file is the intake point for `/advance-work-from-plan` workers. Smoke runs
append new `smoke-finding/*` packets to dated `plan/issues/smoke-e2e-findings-*`
reports; the two standing findings below are the starting backlog.

---

## Work Packets

### Work Packet: finding/build-sh-runtime-litmus-skip

- id: `finding/build-sh-runtime-litmus-skip`
- owner_host: linux
- capability_tags: [bash, ci, testing, podman]
- status: completed
- discovered_by: `./build.sh --ci-full --install` on 2026-06-12 (commit `53ce48b1`)
- evidence:
  - `build.sh:601` calls `podman_runtime_health_probe`, which is defined ONLY in
    `scripts/local-ci.sh:715`. `build.sh` sources only `scripts/common.sh:46`,
    never `local-ci.sh`, so the call errors:
    `./build.sh: line 601: podman_runtime_health_probe: command not found`.
  - Effect: the **runtime residual litmus is silently SKIPped** (fail-safe to
    SKIP, not a build failure) — a coverage hole, not a red build.
  - The evidence-bundle line `Litmus tests complete: 6 passed, 3 failed` is also
    misleading: the actual post-build summary is `PASS:6 FAIL:0 SKIP:217`; the
    "3 failed" is a stale count reused from an earlier CI phase log. Worth fixing
    the evidence-bundle aggregation while here.
- repro:
  - `grep -n podman_runtime_health_probe build.sh scripts/common.sh scripts/local-ci.sh`
  - run `./build.sh --ci-full` and observe the `command not found` at the runtime
    litmus step.
- next_action: >
    Move `podman_runtime_health_probe` into `scripts/common.sh` (sourced by both
    build.sh and local-ci.sh) and make it use `"$REPO_ROOT"`-anchored paths
    (`"$REPO_ROOT/VERSION"`, `"$REPO_ROOT/scripts/tillandsias-podman"`) since
    common.sh does not currently define REPO_ROOT — define/guard it. Remove the
    duplicate from local-ci.sh. Verify the runtime residual litmus actually RUNS
    on a host with a healthy podman runtime. Shared CI infra → coordinate before
    editing build.sh/common.sh/local-ci.sh.
- events:
  - type: discovered
    ts: `2026-06-12T20:34:00Z`
    agent_id: `linux-macuahuitl-claude-2026-06-12T2124Z`
    host: linux

### Work Packet: finding/router-wire-version-mismatch

- id: `finding/router-wire-version-mismatch`
- owner_host: linux
- capability_tags: [rust, control-wire, vsock, testing]
- status: completed
- discovered_by: `tillandsias --bash <proj> --debug` during the git-mirror push smoke, 2026-06-12
- evidence:
  - Repeating router warning during enclave bring-up:
    `Control-socket connection failed; backing off 8s spec="opencode-web-session-otp" error=wire_version mismatch: server=2, sidecar=1`
  - The `tillandsias-router` container's control-wire client (sidecar) speaks
    WIRE_VERSION 1 while the server speaks 2, so the opencode-web session-OTP
    control socket never connects (8s backoff loop). Did NOT affect the
    git-mirror push path, but it likely breaks `--opencode-web` session OTP.
- repro:
  - bring up an enclave (`tillandsias . --opencode <proj> --debug`) and grep the
    router container logs for `wire_version mismatch`.
- next_action: >
    Identify which side is stale (router sidecar pinned to WIRE_VERSION 1 vs the
    server at 2) in `crates/tillandsias-control-wire/` and the router image.
    Re-align the sidecar to the current WIRE_VERSION without breaking the wire
    contract (WIRE_VERSION must not regress). Add/adjust a litmus pinning the
    negotiated version so this skew is caught. Cross-host shared scope
    (control-wire) → coordinate via this ledger before editing.
- events:
  - type: discovered
    ts: `2026-06-12T20:46:00Z`
    agent_id: `linux-macuahuitl-claude-2026-06-12T2124Z`
    host: linux

### Work Packet: smoke/run-release-e2e

- id: `smoke/run-release-e2e`
- owner_host: linux
- capability_tags: [podman, vault, testing, release]
- status: ready
- recurring: true   # re-run after every published release
- next_action: >
    Run `/smoke-curl-install-and-test-e2e` against the latest published release.
    DESTRUCTIVE (`podman system reset --force`) — only on a host where wiping
    Podman is acceptable, or with operator "now" go-ahead. File each issue as a
    `smoke-finding/*` packet in a dated `plan/issues/smoke-e2e-findings-*` report.
- events:
  - type: discovered
    ts: `2026-06-12T21:24:00Z`
    agent_id: `linux-macuahuitl-claude-2026-06-12T2124Z`
    host: linux

---

## Delegation Notes

- The two `finding/*` packets are `ready` and claimable immediately by a Linux
  `/advance-work-from-plan` worker. `build-sh-runtime-litmus-skip` is the safer
  first claim (bash/CI). `router-wire-version-mismatch` touches shared
  control-wire — coordinate here first.
- `smoke/run-release-e2e` should be claimed AFTER the next release publishes (so
  there is a fresh artifact to curl-install) and only on a smoke-appropriate host.
