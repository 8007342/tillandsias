# dev-control-mcp — capability (development-only rebuild/restart verb surface)

## ADDED Requirements

### Requirement: Two-key gate — compile-time dev-build feature plus host-side env opt-in

The dev-control surface SHALL be gated by two keys, BOTH required:

1. **Key 1 (compile-time)**: the code SHALL exist only behind a cargo
   feature (`dev-control` on `tillandsias-headless`) that is NOT in the
   default feature set and is NEVER enabled by any release or CI artifact
   build. Release artifacts SHALL NOT contain the dev-control verbs at
   all — not their dispatch arms, not their tool descriptors, not their
   names as strings. The feature exists only in local dev builds from a
   source checkout. Doctrine: DEVELOPMENT TIME = built from a source
   checkout; END USER RUNTIME = curl-installed artifact with no
   Tillandsias checkout access, containers SEALED — freshness in user
   runtime comes only from the normal ephemeral/idempotent
   relaunch/recreate path.
2. **Key 2 (runtime)**: `TILLANDSIAS_DEV_CONTROL=1` SHALL be read ONCE
   from the TRAY's own process environment at MCP socket-server start.
   Peer input SHALL NEVER participate in gating — forge environment is
   authored entirely by the host, and nothing a peer sends or sets can
   turn the surface on.

There SHALL be no repository-identity key: no repository — including the
Tillandsias repository itself — receives automatic opt-in; a clone or fork
on any machine enables nothing. End users never receive development
privileges.

When BOTH keys are on, the tray SHALL pass `TILLANDSIAS_DEV_CONTROL=1`
into forge environments as a read-only advertisement SIGNAL (so
`agent_init.sh` can mention the verbs); the signal SHALL grant nothing —
authority stays host-side.

#### Scenario: Release artifact contains no verb names (litmus)
- **WHEN** the released `tillandsias` binary (the curl-install artifact)
  is scanned for the byte strings `dev_rebuild` and `dev_rebuild_status`
- **THEN** neither string SHALL be present
- **AND** this SHALL be asserted by a litmus test bound to this spec so a
  gating regression is caught at release time

#### Scenario: Gate off is indistinguishable from nonexistence
- **WHEN** either key is absent (release build, or dev build without
  `TILLANDSIAS_DEV_CONTROL=1` on the tray process) and an attributed
  client calls `tools/list` then `tools/call` for `dev_rebuild`
- **THEN** `tools/list` SHALL omit both dev verbs
- **AND** `tools/call` SHALL return the byte-identical `-32601`
  "Unknown tool" error shape produced for any tool that has never existed
- **AND** a unit test SHALL assert the gate-off responses are
  indistinguishable from those of a server with no dev-control code

#### Scenario: Peer cannot enable the gate
- **WHEN** an in-forge process sets `TILLANDSIAS_DEV_CONTROL=1` in its own
  environment and calls the verbs
- **THEN** the gate SHALL remain off (it was read once, host-side, at
  server start) and the reply SHALL be `-32601`

### Requirement: Per-lane listener identity is a hard dependency

The dev verbs SHALL be dispatched only on connections whose
`(project, instance)` identity is derived from a per-lane listener as
specified by `mcp-tool-socket` (order 505). On any connection attributed
by peer-environment inspection — including the legacy shared
`mcp.sock` — the dev verbs SHALL be absent (omitted from `tools/list`,
`-32601` on call) even when both gate keys are on. Every mutating action
SHALL target only containers that the listener-derived identity provably
maps to; stop-then-remove is permitted ONLY for the exact container the
identity maps to (true self-restart) — everywhere else plain `rm` with no
pre-stop remains the ownership assertion, so a stopped-first sibling can
never convert the running-sibling refusal into success.

#### Scenario: Legacy socket never carries dev verbs
- **WHEN** both gate keys are on but the host still serves the single
  shared pre-order-505 socket
- **THEN** `tools/list` SHALL omit the dev verbs and calls SHALL return
  `-32601`

#### Scenario: Ownership proof gates stop-then-rm
- **WHEN** a `dev_rebuild` cycle for lane `(alpha, w1)` reaches teardown
- **THEN** the tray SHALL stop-and-remove only the container its own
  launch records map to `(alpha, w1)`
- **AND** SHALL never pre-stop any other container

### Requirement: `dev_rebuild` tool

When the gate is on, `tools/list` SHALL include `dev_rebuild` with this
schema, and the server SHALL implement `tools/call` for it through an
explicit match with a default-deny arm before any name or path
construction (the inputSchema is advertisement, not enforcement):

```json
{
  "name": "dev_rebuild",
  "description": "Rebuild or restart a component of the calling lane's own stack. The host decides the tier; the reply is a ticket to poll with dev_rebuild_status.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "component": { "type": "string", "enum": ["forge", "proxy", "git", "inference"] },
      "reason": { "type": "string", "maxLength": 2000 },
      "restart_tier": { "type": "string", "enum": ["restart", "fresh", "full"] },
      "push_first": { "type": "boolean" },
      "seed_prompt": { "type": "string", "maxLength": 8192 }
    },
    "required": ["component", "reason"]
  }
}
```

The result SHALL be
`{"ticket": "<sha8>", "tier": "rebuild+recreate|recreate-only|retag|noop|tray-advisory|rebuild-deferred", "teardown_deadline_secs": <N|null>, "note": "<string>"}`.

Constraints the server SHALL enforce:

- `component` SHALL NOT accept `tray` or any value outside the enum —
  agent-triggered tray recompilation is prohibited permanently (operator
  ruling 2026-07-28: the deterministic compiled tray is the idiomatic
  layer protecting the host; rebuilding it from agent-editable sources
  would be arbitrary code execution on the host). Out-of-enum values SHALL
  be answered with `-32602` by the default-deny arm.
- `restart_tier` and `seed_prompt` SHALL be valid only with
  `component: "forge"`; present on any other component the call SHALL be
  refused with `-32602` naming the offending field.
- The result `tier` is the HOST's decision, derived from the image-build
  identity (`decide_image_build` semantics: digest mismatch →
  `rebuild+recreate`; alias drift → `retag`; digest present →
  `recreate-only` or `noop`). A request that can only be satisfied by a
  tray recompile SHALL be answered `tier: "tray-advisory"` — an
  informational ticket surfaced in tray UI and telemetry for a HUMAN to
  act on (`./build.sh --ci-full --install`); the verb SHALL never build
  the tray. True hot-reload of a live container SHALL be refused,
  permanently (it does not exist in podman and contradicts immutability).
- `dev_rebuild` SHALL target leaf images only; base-image chain rebuilds
  remain `--init` territory.

#### Scenario: Agent states intent, host picks the tier
- **WHEN** lane `(alpha, w1)` calls `dev_rebuild` with
  `component: "proxy"`, `reason: "allowlist change"` and the proxy image
  digest is stale
- **THEN** the reply SHALL carry a ticket and `tier: "rebuild+recreate"`
- **AND** the rebuild SHALL proceed asynchronously — the reply returns
  immediately

#### Scenario: tray is not a component
- **WHEN** any client calls `dev_rebuild` with `component: "tray"`
- **THEN** the server's default-deny arm SHALL answer `-32602`
- **AND** no build, ticket, or container action SHALL occur

#### Scenario: Definition change yields tray-advisory
- **WHEN** the requested rebuild can only be satisfied by recompiling the
  tray (container definitions are Rust compiled into the tray)
- **THEN** the reply SHALL be `tier: "tray-advisory"` with a ticket
- **AND** the ticket SHALL appear in the tray's advisory queue for a human
- **AND** no compilation SHALL be triggered

### Requirement: Forge restart tiers

For `component: "forge"`, `restart_tier` SHALL select among exactly three
tiers ("restart me" means the FORGE, not the stack — the shared stack
proxy/git/inference/vault is untouched by tiers 1 and 2):

- **`restart` (tier 1, default when omitted)**: a new forge container from
  the same image — near-equivalent to exiting the forge and relaunching
  from the tray.
- **`fresh` (tier 2)**: wipe that container's ephemeral cache, then
  launch again.
- **`full` (tier 3)**: forced re-create through the idiomatic layer
  (known signature/certificate churn risk) — DEVELOPMENT TIME only, like
  the rest of this surface.

The forge self-restart cycle SHALL keep the build-before-destroy order:
(a) reply with ticket while the old forge still runs; (b) rebuild if the
tier requires it — a build failure SHALL destroy nothing (`failed`, agent
keeps working); (c) on green, write the relaunch token and enter
`pending_teardown` with a deadline (default 30 s) carried in the first
reply; (d) at deadline, stop+rm of the ownership-proven own container
only; (e) relaunch through the normal pipeline; (f) a recreate failure
after destruction SHALL retain the token and mark the ticket `failed`
naming the exact recreate command.

#### Scenario: Tier 1 leaves the shared stack alone
- **WHEN** a `restart`-tier forge cycle completes
- **THEN** the proxy, git-mirror, inference, and vault containers SHALL
  have been neither stopped, removed, nor rebuilt by this cycle

#### Scenario: Build failure destroys nothing
- **WHEN** the image rebuild step of a forge cycle fails
- **THEN** the old forge SHALL still be running
- **AND** the ticket SHALL read `failed` with the build error in `note`

### Requirement: Unpushed-work refusal for forge and git

`component: "forge"` and `component: "git"` SHALL be REFUSED unless the
lane's worktree is clean AND its HEAD is reachable from a ref on the
lane's mirror: `/home/forge/src` is a hot tmpfs root, the mirror is the
only push channel, and a restart would otherwise silently discard every
commit not yet pushed. The refusal SHALL use status
`refused-unpushed-work` and SHALL name the exact `git push` command that
clears it. `push_first: true` SHALL perform the mirror push first and
SHALL refuse on push failure. Additionally, `component: "git"` SHALL be
refused with `refused-sibling-live` while ANY live lane of the project
holds the mirror (mid-clone teardown was the order-494 incident).

#### Scenario: Dirty worktree refuses restart
- **WHEN** lane `(alpha, w1)` calls `dev_rebuild` `component: "forge"`
  with uncommitted changes or commits absent from the lane's mirror ref
- **THEN** the ticket SHALL read `refused-unpushed-work`
- **AND** the `note` SHALL contain the exact `git push` command
- **AND** nothing SHALL be rebuilt or destroyed

#### Scenario: push_first clears the refusal
- **WHEN** the same call is made with `push_first: true` and the mirror
  push succeeds
- **THEN** the cycle SHALL proceed
- **WHEN** the mirror push fails
- **THEN** the ticket SHALL read `refused-unpushed-work` with the push
  error in `note`

### Requirement: Seed-prompt-only relaunch injection

There SHALL be NO session persistence of any kind: no `--resume`
threading, no session-id capture, no transcript or harness-state volume
(operator ruling 2026-07-28 round 2 — order 511 REJECTED; harness state
directories are credential locations, and continuity is what the seed
prompt is for: every forge session starts new per the ephemeral contract,
bootstrapped from `./plan` and `./methodology`).

The optional `seed_prompt` SHALL be delivered to the relaunched harness
via a host-side relaunch-request token:
`state/resume/<project>/<instance>.json`, mode `0600`, path components
equality-validated against enumerated lanes, containing the prompt, the
ticket id, a host-generated nonce, and a creation timestamp. Consumption
SHALL be an atomic rename (single-use; a duplicated relaunch finds no
token and starts fresh) that SHALL verify: TTL unexpired
(refuse-and-delete on expiry), nonce bound to the ticket registry, and
ticket still in `pending_teardown` or `recreating`; every consume SHALL
be loudly logged. The prompt SHALL travel env-only into already-quoted
entrypoint exec lines, capped at 8 KiB, logged to telemetry; all
entrypoints SHALL place a `--` separator before every injected positional
(quoting is not argv separation).

#### Scenario: Fresh session seeded with the prompt
- **WHEN** a forge cycle with `seed_prompt: "continue work #123"`
  relaunches
- **THEN** the new harness session SHALL start fresh (no prior session
  state) with the seed prompt as its initial prompt
- **AND** the token file SHALL have been atomically renamed away

#### Scenario: Expired or replayed token is refused
- **WHEN** a relaunch finds a token whose TTL has expired, whose nonce
  does not match the ticket registry, or whose ticket is in a terminal
  state
- **THEN** the token SHALL be refused and deleted with a loud log
- **AND** the lane SHALL launch fresh without a seed prompt

### Requirement: `dev_rebuild_status` tool and status taxonomy

When the gate is on, `tools/list` SHALL include `dev_rebuild_status` with
this schema:

```json
{
  "name": "dev_rebuild_status",
  "description": "Poll dev_rebuild tickets. Without a ticket id, lists the tickets of the calling lane only.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "ticket": { "type": "string", "pattern": "^[a-f0-9]{8}$" }
    }
  }
}
```

Ticket status SHALL be one of:
`queued | building | ready | pending_teardown | recreating | done | failed
| refused-unpushed-work | refused-sibling-live | rebuild-deferred
| tray-advisory | busy | rate-limited`.
`rebuild-deferred` and `refused-sibling-live` are terminal for the
requesting cycle (never retry-hammer): for shared components
(`proxy`/`inference`), a rebuild whose recreate is blocked by a live
sibling SHALL land the new digest without yanking anything from running
containers (content-addressed `sha256-` tags) and defer the recreate to
the next zero-refcount teardown. Ticket-plus-poll replaces push progress —
the NDJSON transport has no notification convention, and multi-minute
builds must not look hung.

Status SHALL be scoped strictly to the caller's listener-derived lane:
without a ticket id, only that lane's tickets are listed; with a ticket id
belonging to another lane, the server SHALL answer as if the ticket does
not exist; and no response SHALL ever echo another lane's `reason` or
`seed_prompt` — the verb must not become a cross-lane oracle.

#### Scenario: Poll a build in progress
- **WHEN** a lane polls a ticket during the image rebuild
- **THEN** the reply SHALL carry status `building`
- **AND** later polls SHALL observe `pending_teardown` with the deadline,
  then `recreating`, then `done`

#### Scenario: Cross-lane ticket is invisible
- **WHEN** lane `(alpha, w1)` polls a ticket created by lane `(beta, w2)`
- **THEN** the reply SHALL be indistinguishable from polling a ticket that
  never existed

#### Scenario: Sibling-held shared component defers
- **WHEN** a `proxy` rebuild completes while a sibling lane's containers
  still use the proxy
- **THEN** the ticket SHALL read `rebuild-deferred`
- **AND** running containers SHALL keep their current image
- **AND** the recreate SHALL occur at the next zero-refcount teardown

### Requirement: Ticket registry and duplicate dedupe

The ticket id SHALL be the first 8 hex characters of
`sha256(project, instance, component)`. While a ticket for that key is
in-flight (non-terminal), a duplicate `dev_rebuild` SHALL return the SAME
ticket; after a terminal status, a new call SHALL start a legitimate new
cycle. (The design's 4-tuple including a session id was rescoped with
order 511's rejection — there is no session id.)

#### Scenario: In-flight duplicate is idempotent
- **WHEN** a lane calls `dev_rebuild` twice for the same component while
  the first cycle is `building`
- **THEN** both replies SHALL carry the same ticket id and one cycle SHALL
  run

### Requirement: Non-blocking lock acquisition and rate limiting

Dev-control SHALL acquire the image build `resource_lock` with a short
NON-blocking try; on contention it SHALL return status `busy` immediately
— it SHALL never queue behind the tray's own launch path (which may hold
the lock for ~900 s; the general-purpose `resource_lock::acquire` is a
bounded blocking poll and is therefore unsuitable here). Rate limits SHALL
be enforced per-lane, keyed on the unforgeable listener-derived identity,
plus one host-wide global bucket; exhaustion SHALL return `rate-limited`.
Superseded agent-initiated LEAF image digests SHALL be pruned (scoped
pruning — this surface never invokes `podman system reset`).

#### Scenario: Launch path holds the image lock
- **WHEN** `dev_rebuild` is called while the tray's launch path holds the
  image resource lock
- **THEN** the reply SHALL be status `busy` within the non-blocking try
  window
- **AND** the tray's launch SHALL be unaffected

#### Scenario: Rebuild-loop protection
- **WHEN** one lane exhausts its rate bucket
- **THEN** further `dev_rebuild` calls from that lane SHALL return
  `rate-limited`
- **AND** other lanes' budgets SHALL be unaffected until the global bucket
  is exhausted

### Requirement: Kept-warm cache preconditions

Fast recreate is cheap only because every expensive input is cached; these
are normative preconditions, not folklore:

1. The podman image store's canonical `sha256-` tags and layer cache SHALL
   persist across dev-control operations (no `podman system reset`, ever,
   from this surface; digest pruning is scoped to superseded
   agent-initiated leaf digests only).
2. Base-image chain digests SHALL cascade via `dependency_digests`;
   dev-control targets leaf images only.
3. The order-459 harness curl-install artifact cache (Claude/OpenCode
   downloads) SHALL live host-side of the mount boundary so a fast
   recreate never re-pays the network — the single biggest recreate cost.
4. The git-mirror container SHALL survive forge recreates
   (leak-not-destroy, order 494) so `/home/forge/src` re-clones from the
   warm local mirror.

#### Scenario: Recreate does not re-download harnesses
- **WHEN** a tier-1 forge restart completes on a host with a warm
  order-459 artifact cache
- **THEN** the relaunched forge SHALL reuse the cached harness artifacts
- **AND** no harness download SHALL occur unless a newer version exists

### Requirement: Telemetry initiator attribution

Every dev-control-initiated image build SHALL stamp the initiator
`{project, instance, reason}` into the image-build events log
(`image-build-events.jsonl`), so cross-project image effects (a rebuilt
shared image is content-addressed and identical for identical inputs, but
the ACT of rebuilding is attributable) are auditable.

#### Scenario: Build event carries the initiator
- **WHEN** lane `(alpha, w1)` triggers a proxy rebuild with reason
  "allowlist change"
- **THEN** the corresponding build event SHALL record
  `{"project": "alpha", "instance": "w1", "reason": "allowlist change"}`
