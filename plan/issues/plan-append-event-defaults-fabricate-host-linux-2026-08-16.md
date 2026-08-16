# tillandsias-plan append-event defaults fabricate agent_id=unknown host=linux

- classification: enhancement
- filed: 2026-08-16 (windows, meta-orchestration cycle 2)
- status: resolved (2026-08-16, windows cycle 5, packet 772-4se9
  plan-append-event-writer-identity-defaults: host defaults from the compiled
  platform via shared resolve_writer_host, agent_id derives from
  TILLANDSIAS_AGENT_ID or refuses loudly, both pinned by unit tests)
- related: order 756-hn3a (agent_identity_contract: refuse, don't improvise)

## Observation

`tillandsias-plan append-event <ref> <type> <summary>` without `--agent`/
`--host` recorded `agent_id: "unknown"` and `host: linux` into the ledger —
from the WINDOWS .exe, on a Windows host. Caught this cycle only because the
write went to the uncommitted base and the diff was reviewed; the two fields
were hand-corrected before commit. A fragment write would have been immutable.

The caller omitting the flags is the proximate cause, but the defaults are
the defect: `linux` is not a neutral default, it is a wrong FACT on two of
the four host kinds, and `unknown` is exactly the hand-composed improvisation
756-hn3a removed from claim recipes. The binary knows its own platform at
compile time, and scripts/agent-identity.sh is the canonical id source.

## Smallest next action

In crates/tillandsias-plan append-event: default `host` from the compiled
platform (cfg target_os -> linux|macos|windows, forge via
TILLANDSIAS_HOST_KIND), and either derive `agent_id` from TILLANDSIAS_AGENT_ID
/ the agent-identity contract or REFUSE with a loud verdict when absent —
never record the literal string "unknown". Pin with a handler test asserting
no event can be written carrying host=linux from a non-linux build.
