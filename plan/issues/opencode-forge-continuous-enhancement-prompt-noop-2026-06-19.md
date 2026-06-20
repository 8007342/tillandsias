# OpenCode forge continuous-enhancement prompt no-op - 2026-06-19

Status: ready
Owner: linux
Discovered by: /build-install-and-smoke-test-e2e (linux)

## Summary

The local-build E2E forge lane exited `0`, but the prompted OpenCode run did
not execute `/forge-continuous-enhancement`. Instead, the transcript shows the
agent responding that `diagnose-forge` is not in its available skill list and
asking for clarification. This can make the Linux forge smoke gate pass without
running the intended in-forge work.

## Packet

- id: `local-smoke/opencode-forge-continuous-enhancement-prompt-noop`
- type: fix
- owner_host: linux
- status: ready
- capability_tags: [linux, opencode, forge, smoke, testing]
- severity: high
- source: this smoke report
- next_action: >
    Make `tillandsias . --opencode --prompt "Use the
    /forge-continuous-enhancement skill"` reliably run the in-forge
    `forge-continuous-enhancement` skill, or fail nonzero when the prompt is
    consumed as a no-op/clarification response. Add regression coverage that
    catches a transcript where the command exits 0 without either entering the
    skill, filing plan packets, or emitting an explicit no-op completion marker.
- blocker: none
- evidence_required:
    - prompted OpenCode forge lane exits 0 only after the intended skill starts
      and completes, or after it records an explicit no-work-needed result
    - E2E transcript distinguishes command success from semantic no-op
    - regression coverage pins the accepted transcript marker(s)

## Evidence

- log_dir: `target/build-install-smoke-e2e/20260619T233855Z`
- command:
  `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"`
- command exit: `04-forge-exit.txt:1` records `forge_exit=0`
- transcript:
  - `04-forge-continuous-enhancement.log:16`: `Skill "diagnose-forge"`
  - `04-forge-continuous-enhancement.log:17`: `That's not a skill in my available list`
  - `04-forge-continuous-enhancement.log:19`: `What would you like me to do?`

## Repro

1. Install a local Linux build and reset the runtime substrate from a clean
   store.
2. Run `tillandsias --init --debug`.
3. Run `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"`.
4. Observe the command can exit `0` while the transcript asks for clarification
   instead of executing `forge-continuous-enhancement`.

## Notes

- This is distinct from the completed
  `local-smoke/opencode-interactive-prompt-not-consumed` packet: the prompt is
  consumed here, but the result is a semantic no-op.
- The musl build blocker in
  `plan/issues/build-install-smoke-e2e-findings-2026-06-19.md` remains closed;
  this packet tracks the separate forge semantic-success contract.
