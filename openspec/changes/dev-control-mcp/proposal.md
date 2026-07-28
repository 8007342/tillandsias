# dev-control-mcp — retro-specify the mcp.sock transport, specify the dev-control verb surface

## Why

Two debts converge here.

**Spec debt (retroactive).** Order 363 shipped a host-side NDJSON MCP tool
socket (`mcp.sock`, served by the tray, mounted into forge containers) with
no capability spec of its own — it is annotated against
`spec:host-browser-mcp`, which actually specifies the separate browser-MCP
bridge and even pins a *different* MCP protocol revision (`2025-06-18` in
`openspec/specs/host-browser-mcp/spec.md:19` and
`crates/tillandsias-browser-mcp/src/server.rs:191`) than the one `mcp.sock`
answers (`2024-11-05`, hardcoded at
`crates/tillandsias-headless/src/tray/mod.rs:702`). The transport also has a
red-team-proven attribution hole: the project label is read from the peer's
`/proc/<pid>/environ` (self-asserted at execve) and the one shared socket
directory is mounted into every forge of every project, so any in-forge
agent can impersonate any project on `publish_local` today. Order 505
(`mcp-sock-perlane-attribution`) repairs this with per-lane sockets; the
transport must be specified so that repair has a normative target.

**New surface (dev-control).** The operator directive of 2026-07-28 (decision
record `plan/issues/forge-rebuild-mcp-orchestration-research-2026-07-28.md`,
orders 505–515) adds a development-only MCP surface letting in-forge agents
ask the host tray to rebuild/restart components of their own lane stack. The
red-team review and two rounds of operator rulings fixed its authorization
model (per-lane listener identity, compile-time + env two-key gate, no
repo-identity key, no tray recompilation ever, no session persistence —
order 511 REJECTED, seed-prompt-only resume). This change writes the
*post-ruling* surface into spec form so implementation packets 507–510 and
512–514 build against requirements, not against the superseded design prose.

This change is spec-only (order 506, packet `dev-control-mcp-spec`). It
deliberately re-verified every load-bearing code citation against HEAD
`2f15c1da` and corrects the design record's disproven claims (see
`design.md` §"Corrected grounding claims") so they cannot enter the spec.

## What Changes

- **ADDED** new capability spec `mcp-tool-socket` — retro-specifies the
  NDJSON JSON-RPC transport the tray serves for in-forge agents: socket
  location and lifecycle, per-lane socket + listener-derived attribution
  model (order 505; environ attribution demoted to a documented legacy
  hazard), NDJSON framing and deny contract, method surface, explicit
  `protocolVersion` negotiation reconciling the `2024-11-05` vs
  `2025-06-18` drift, the existing order-363 tool surface
  (`publish_local` / `service_status` / `service_stop`), and the
  control-plane separation invariant (`control.sock` is never mounted).
- **ADDED** new capability spec `dev-control-mcp` — the development-only
  verb surface: exactly two tools, `dev_rebuild` and `dev_rebuild_status`,
  with JSON schemas; component enum `forge|proxy|git|inference` (NO `tray`
  — permanently prohibited by operator ruling); forge restart tiers
  `restart|fresh|full`; the two-key gate (compile-time `dev-control` cargo
  feature present only in source-checkout dev builds + `TILLANDSIAS_DEV_CONTROL=1`
  host-side env opt-in) with `-32601` curated absence when off; a litmus
  requirement that release artifacts contain no dev-control verb names;
  per-lane listener identity as a hard dependency (order 505);
  unpushed-work refusal for `forge`/`git`; seed-prompt-only relaunch
  injection (order 511 rejected — no session persistence); ticket registry,
  status taxonomy and lane-scoped status; non-blocking lock acquisition and
  rate limiting; kept-warm cache preconditions.

## Capabilities

### New Capabilities

- `mcp-tool-socket` — retro-spec of the existing transport plus the order-505
  per-lane socket model.
- `dev-control-mcp` — the gated dev verb surface (new; implementation in
  orders 507–510, 512–514).

### Modified Capabilities

(none — `host-browser-mcp` keeps specifying the browser bridge; this change
removes the need to keep annotating `mcp.sock` code against it, and the
follow-up sync may retarget those `@trace` lines to `spec:mcp-tool-socket`.)

## Impact

- **Spec**: two new capability specs under this change's `specs/`. No
  existing spec text is modified.
- **Crates (later, by dependent packets)**: `tillandsias-headless`
  (tray MCP server, dispatcher, gate, ticket registry, launch-time token
  consume — orders 505/507/508/510), `tillandsias-logging` (initiator
  fields — order 508), `images/default` entrypoints (seed-prompt injection
  — order 509), `tillandsias-control-wire` (vsock arm — order 514).
- **Security**: the gate is compile-time first — release artifacts MUST NOT
  contain the verbs at all (operator ruling 2026-07-28: the capability is a
  security hole in USER RUNTIME). END USER RUNTIME (curl-installed sealed
  artifact) never sees the surface; `tools/list` omits the verbs and
  `tools/call` answers the same `-32601` as any unknown tool.
- **No breaking change**: the retro-spec captures current behaviour where it
  is sound, and captures orders 505/507+ requirements as deltas where it is
  not; the baseline order-363 tools keep their wire shape.
