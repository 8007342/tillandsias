# RESEARCH: forge→host lifecycle-control channel — "refresh me" and "I'm done" (2026-07-20)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Owner host**: linux
- **Operator ask (2026-07-20)**: agents inside a forge need a way to tell the
  host (a) they need an UPDATED tillandsias environment — a fresh build + fresh
  containers that load the changes they've committed — so the host can terminate
  tillandsias, rebuild, relaunch, and resume them on an updated forge; and (b)
  that they are DONE, so their forge can be safely closed/destroyed. "We might
  need some MCP servers and/or some code in our idiomatic layers for agents to
  call when done."
- **Goal it serves**: hands-off automation. Every release or so (aligned with
  dailies), rebuild + relaunch the local forge and keep delegating. Agents
  self-signal when they need a refresh or are finished.

## The two signals

1. **REFRESH** — "rebuild + relaunch me with my committed changes loaded."
   The forge runs a tillandsias/image build from launch time. An agent that
   commits+pushes improvements to the forge itself (images, entrypoints, the
   headless binary) does NOT see them until the host rebuilds and relaunches.
   Today the agent has no way to request that; it just keeps running the old
   environment. Observed live 2026-07-20: agents close packets that change the
   forge image, but the running forge keeps serving the pre-change image (the
   same "running image older than checkout" class as order 422).

2. **DONE** — "my work is complete; this forge can be destroyed."
   Today the host cannot tell a finished forge from a hung one. A DONE signal
   lets the host reclaim resources (destroy the ephemeral forge, per the
   ephemerality principle) without guessing or waiting on a timeout.

## What already exists (survey this first)

- The forge→host MCP socket exposes `publish_local`, `service_status`,
  `service_stop` (`/run/host/tillandsias-mcp` bind-mounted into the forge).
  This is the natural place to add `request_refresh` and `signal_done` verbs —
  the transport already crosses the boundary safely.
- ZeroClaw (agent↔agent message passing) was deleted as a critical violation
  and is gated behind an unstarted milestone (order 403). This packet is the
  SIMPLER, one-directional forge→host control case — do NOT reintroduce ZeroClaw
  to solve it.
- The forge-agent-delegation research
  (`plan/issues/forge-agent-delegation-research-2026-07-19.md`) covers the
  host→forge direction (sending prompts). This is the reverse (forge→host
  lifecycle), and the two together are the full duplex the automation needs.
- `smoke-curl-install-and-test-e2e` / `build-install-and-smoke-test-e2e` already
  encode the host-side rebuild+relaunch mechanics; a REFRESH handler would reuse
  that sequence rather than reinvent it.

## Research questions

1. **Transport: MCP verb vs idiomatic-layer call vs filesystem sentinel.**
   - MCP verbs (`request_refresh`, `signal_done`) on the existing forge→host
     socket: typed, discoverable, already boundary-crossing. Cost: the agent
     harness must know to call them (an idiomatic wrapper/skill).
   - Idiomatic-layer function the agent invokes (a `tellme`/`forge-ctl`-style
     CLI in the forge that speaks to the host socket): easiest for an agent to
     call from a shell; thin wrapper over the MCP verb.
   - Filesystem sentinel (agent writes `/run/host/tillandsias-refresh` /
     `.../done`; host watches): dead simple, no protocol, survives a crashed
     agent — but unstructured and racy. Evaluate as a fallback.
   Recommend the MCP verb as the contract, with a thin forge-local CLI wrapper
   so an agent can call it in one line, and a sentinel-file fallback for a dying
   agent. Confirm against the existing socket's protocol.

2. **REFRESH safety: what must be true before the host tears down and rebuilds?**
   - The agent's work MUST be committed AND relayed upstream first — a refresh
     that destroys uncommitted or unpushed work is a data-loss path (cf. the
     2026-07-19 forge data-loss findings). The host should VERIFY the forge's
     branch is pushed (mirror head == upstream head) before destroying, and
     refuse/​warn otherwise.
   - Clone-only forges (order 437) make this cleaner: the working tree is
     disposable by construction, so REFRESH is "destroy + relaunch (which
     re-clones the now-updated mirror) + resume the agent's prompt". Enumerate
     exactly what "resume" means — re-issue the same prompt? restore a session?

3. **DONE semantics and resource reclamation.**
   - Does DONE destroy only the agent's forge container, or also release its
     share of the shared stack (per order 443 reference-counting)? They compose:
     DONE decrements the refcount; the shared stack is torn down when the last
     forge signals DONE.
   - Idempotency: a DONE that arrives twice, or from a forge already gone, must
     be a no-op.

4. **Who drives the rebuild loop, and does it block?**
   - REFRESH implies: host terminates the tillandsias process, rebuilds images +
     binary, relaunches the forge, resumes. That is minutes of wall time. Is the
     agent paused (its container kept, re-execed) or destroyed+recreated
     (clone-only makes the latter cheap)? Decide and record.
   - Alignment with dailies: a REFRESH could also just be QUEUED for the next
     daily rebuild rather than triggering an immediate one, to batch churn.

5. **Failure modes.** A REFRESH that fails to rebuild (broken build the agent
   just pushed) must NOT leave the operator with no forge — fall back to the
   last-good image (the order-284 harness rollback pattern generalised to the
   whole environment; cf. order 439's contract-verification idea).

## Deliverable of THIS research packet

A decision record recommending: the transport (MCP verb + thin CLI wrapper +
sentinel fallback), the REFRESH pre-destroy verification (pushed-before-destroy),
the DONE↔refcount composition with order 443, the pause-vs-recreate choice, and
the rebuild-failure fallback. Then split into the smallest implementable rungs
(e.g. rung 1: `signal_done` verb + refcount decrement; rung 2: `request_refresh`
queued for next daily; rung 3: immediate rebuild-relaunch-resume).

## Non-goals

Not ZeroClaw. Not agent↔agent messaging. One-directional forge→host lifecycle
control only.
