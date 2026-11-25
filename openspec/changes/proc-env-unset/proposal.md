# Proposal — proc-env-unset

Packet: `2305-zm8j`.

## Why

Every door onto the runtime hands a child `CARGO_TARGET_DIR` and every
`TILLANDSIAS_*` name by design (1593-1ny6, design 2029-39bt §4.1). A gate exports
both, so a Lua fixture whose subject reads one is green on its author's host and
red in the gate. Measured 2026-11-24: #1488 and #1491 were evicted and #1490
landed with the same hole. The shell originals used `unset` or `env -u`; a Lua
fixture had no equivalent and had to write a shell prologue.

## What Changes

- `env_unset = { "NAME", "PREFIX_*" }` on `proc.run{}`, `proc.spawn{}` and each
  `proc.chain` stage, and on the fixture kit's `T:run`.
- preflight-fixtures-default-target.sh runs an added Lua fixture once more with a
  gate's variables set, and refuses one that is red only there.

## Impact

It only removes names, so it widens no child's environment. A call without it is
unchanged. The positional `sh.run` and the run verb do not take it.
