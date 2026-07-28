# dev-control-mcp — tasks

This change is spec-only (order 506). Sections 2–8 are owned by the named
implementation packets; they are listed here so `/opsx:verify` has the full
map from requirement to landing slice, and each SHALL be checked off in the
packet that lands it.

## 1. Spec authoring (order 506 — this packet)

- [x] 1.1 Re-verify every design-record citation against HEAD `2f15c1da`;
  record corrections in `design.md` ("Corrected grounding claims") — the
  two disproven claims (`TILLANDSIAS_FORGE_INSTANCE` threading;
  "dev-sessions carries no credentials") are excluded from spec text.
- [x] 1.2 Retro-spec the NDJSON transport as capability `mcp-tool-socket`
  with the order-505 per-lane socket model, listener-derived attribution,
  deny contract, framing, method surface, and baseline order-363 tools.
- [x] 1.3 Reconcile the protocolVersion drift explicitly: negotiation,
  supported set {`2024-11-05`, `2025-06-18`}, latest `2025-06-18` sourced
  from one shared constant across both host MCP surfaces.
- [x] 1.4 Specify `dev_rebuild` / `dev_rebuild_status` with JSON schemas;
  component enum `forge|proxy|git|inference` (NO tray — operator ruling);
  result tier taxonomy incl. `tray-advisory` and `rebuild-deferred`;
  forge restart tiers `restart|fresh|full`; seed-prompt-only injection
  (order 511 REJECTED); unpushed-work refusal; status taxonomy + lane
  scoping; ticket dedupe without session id; non-blocking lock + rate
  limits; kept-warm cache preconditions; telemetry initiator.
- [x] 1.5 Specify the two-key gate as requirements: compile-time
  `dev-control` cargo feature (dev builds from a source checkout only) +
  `TILLANDSIAS_DEV_CONTROL=1` on the tray process; `-32601` curated
  absence; release-artifact litmus (no verb name strings in the released
  binary); no repo-identity key.

## 2. Transport repair (order 505 — `mcp-sock-perlane-attribution`, P0, ships first)

- [ ] 2.1 Bind `<mcp_dir>/<project>-<instance>/mcp.sock` per lane; mount
  only that lane's subdirectory into its forge.
- [ ] 2.2 Derive `(project, instance)` from the accepting listener; delete
  environ-based attribution from the dispatch path (`resolve_peer_project`
  survives at most as a diagnostic log field, never as identity).
- [ ] 2.3 Equality-validate project labels against enumerated local
  projects before any name/path construction (incl. the
  `main.rs:12721-12722` join sites).
- [ ] 2.4 Regression tests: forged `TILLANDSIAS_PROJECT` has no effect;
  cross-lane socket invisible; unattributable peer denied once, loudly.

## 3. Gate + registry (order 507 — `dev-control-gate-and-registry`, P2)

- [ ] 3.1 Add the `dev-control` cargo feature (not in `default`); wrap all
  verb code, descriptors, and name strings in it; assert release build
  scripts never enable it.
- [ ] 3.2 Read `TILLANDSIAS_DEV_CONTROL` once at MCP server start; convert
  the hardcoded `tools/list` array (`tray/mod.rs:710-742`) into a builder.
- [ ] 3.3 Gate-off unit test: responses byte-identical to a server with no
  dev-control code (`tools/list` omission + `-32601` shape).
- [ ] 3.4 Litmus: released artifact contains no `dev_rebuild` /
  `dev_rebuild_status` strings (shared with order 513's end-user
  transparency litmus).
- [ ] 3.5 Ticket registry with `sha256(project,instance,component)[..8]`
  dedupe; lane-scoped `dev_rebuild_status`; server-side default-deny match
  before any construction; per-lane + global rate buckets; non-blocking
  image-lock try returning `busy`.
- [ ] 3.6 Shared latest-protocolVersion constant + negotiation in
  `handle_mcp_jsonrpc` (replaces the `2024-11-05` pin at
  `tray/mod.rs:702`); reuse from the host-browser-mcp surface.

## 4. Shared components (order 508 — `dev-rebuild-shared-components`, P3)

- [ ] 4.1 Force path into `ensure_image_exists` gated by
  `runtime_phase::container_mutations_allowed`; order-494 plain-rm
  recreate protocol; `rebuild-deferred` on live sibling; leaf-digest
  pruning; initiator stamping into `image-build-events.jsonl`.
- [ ] 4.2 `component: "git"` refusals (`refused-sibling-live`,
  unpushed-work). Litmus instant: refused-sibling-live shape.

## 5. Relaunch plumbing (order 509 — `resume-relaunch-plumbing`, P4, rescoped)

- [ ] 5.1 Relaunch-request token store/consume: 0600, TTL, nonce bound to
  ticket, atomic rename, loud log; equality-validated path components.
- [ ] 5.2 Seed-prompt env-only threading, 8 KiB cap, `--` separators in
  all three entrypoints. NO session-id capture, NO `--resume` threading
  (order 511 rejected).

## 6. Forge self-restart (order 510 — `forge-self-restart-lifecycle`, P5)

- [ ] 6.1 Build-before-destroy cycle; `pending_teardown` deadline;
  ownership-proven stop+rm; post-destroy failure path naming the exact
  recreate command; restart tiers `restart|fresh|full`.
- [ ] 6.2 Unpushed-work refusal + `push_first`. e2e litmus `--size instant
  --phase pre-build`.

## 7. Surface polish (orders 512/513/514)

- [ ] 7.1 Order 512: `agent_init.sh` advertisement via the read-only
  signal; cheatsheet (statuses, never retry-hammer, push-first flow);
  tray-menu ticket visibility incl. the tray-advisory queue.
- [ ] 7.2 Order 513: end-user transparency litmus (non-opted project sees
  no verbs, `-32601`, no lane branches).
- [ ] 7.3 Order 514: vsock `(McpFrame, Vsock)` arm
  (`control_dispatch.rs:130-131`) behind the same two-key gate for
  Windows/macOS dev hosts.

## 8. Sync + archive

- [ ] 8.1 `/opsx:sync dev-control-mcp` to promote both capability specs;
  add litmus bindings in `openspec/litmus-bindings.yaml`; retarget the
  `mcp.sock` code's `@trace` lines from `spec:host-browser-mcp` to
  `spec:mcp-tool-socket`.
- [ ] 8.2 `/opsx:verify dev-control-mcp`, then `/opsx:archive` once orders
  505/507–510 have landed against these requirements.
