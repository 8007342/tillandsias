# E2E destructive reset blocked by concurrent sibling runtime on shared host

- branch: linux-next
- status: blocked
- owner_host: linux_mutable
- blocker: sibling-runtime-active (cannot `podman system reset --force` without destroying a concurrent agent's live runtime)
- owner: operator / coordinator (window coordination)
- source: meta-orchestration loop e2e, 2026-06-21T06:40Z

## What happened (and what passed)

Local-build e2e **step1 PASSED** on `linux-next` HEAD after the fmt + litmus
fixes landed this session:

- `build.sh --ci-full --install` exit 0; **all checks 100%** (133/133 litmus,
  14/14 ci checks, 5/5, 7/7); installed `Tillandsias v0.3.260621.1` at
  `~/.local/bin/tillandsias`, version assertion passed.

This validates the branch is buildable, installable, and CI-green — the
non-destructive half of the e2e.

## Why step2 (destructive reset) is blocked

`scripts/e2e-step2-linux.sh` runs `podman system reset --force` (wipes ALL
containers/volumes/images). At reset time the host had **active sibling work**:

- Multiple `./repeat --times 12 --wait 2h --prompt "Use the /meta-orchestration
  skill." --agent opencode` processes, plus a live `opencode run` (pid 1478026)
  executing the skill.
- `tillandsias-vault` + `tillandsias-router` **Up 4 minutes**, router on image
  `v0.3.260621.1` — a sibling opencode agent had just `init`-ed using the binary
  this cycle built. (`cranky_tesla`/`elastic_keller` alpine containers up ~1h.)

A host-wide reset would destroy the sibling's runtime + Vault secret state
mid-operation. The build-install-smoke-e2e flock was **free**, but it only
serializes e2e gates against each other — it does **not** cover a sibling's
`init`/runtime started outside the e2e flow. So "lock free" is not "safe to
reset." Per the exit contract, do not overwrite unknown/sibling work — recorded
as a blocker instead.

## Concurrency gap (extends [[agent-concurrency-collisions-2026-06-20]])

The destructive smoke-lock does not guard against a sibling agent's live
runtime/init. Destructive reset needs a stronger precondition than the e2e lock.

### Smallest next action (ready)

- id: gate-reset-on-idle-runtime
  status: ready
  action: >
    Before `podman system reset --force`, e2e-step2 should assert NO foreign
    `tillandsias-*` runtime containers are Up and NO active `opencode run`/forge
    agent is present (beyond this e2e's own), and otherwise wait/skip with a clear
    "host busy — reset deferred" message rather than destroying sibling state.
    Alternatively, a host-level "destructive-window" lease that all agents honor.

## Events

- type: finding
  ts: "2026-06-21T06:42:00Z"
  agent_id: "linux-claude-opus48-loop-20260621T0642Z"
  host: linux_mutable
  note: >
    e2e step1 (build+install) PASSED 100% on linux-next HEAD after the fmt/litmus
    fixes. step2 destructive reset deferred: a concurrent sibling opencode
    meta-orch agent had a live tillandsias-vault/router runtime (Up 4 min on
    v0.3.260621.1). Smoke-lock was free but does not cover sibling init/runtime;
    declined to reset and destroy sibling state. Filed concurrency-gap follow-up
    to gate the reset on an idle runtime.
