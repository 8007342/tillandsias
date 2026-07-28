# dev-control-mcp — design

## Context

The decision record is
`plan/issues/forge-rebuild-mcp-orchestration-research-2026-07-28.md`
(design grounded @ `e57b6a3d`, red-team re-verified @ `05fff9d6`, **both
"Operator rulings" sections at its end override earlier text**). This
change was authored against HEAD `2f15c1da` and every citation below was
re-verified there, per the packet's explicit instruction — the design's own
red-team note flags grounding drift and two outright false claims.

The existing transport (order 363): the tray binds
`$XDG_RUNTIME_DIR/tillandsias/mcp/mcp.sock`
(`crates/tillandsias-headless/src/tray/mod.rs:498-503`), 0600, serves
NDJSON JSON-RPC from detached threads (`tray/mod.rs:876-907`), attributes
the peer's project via SO_PEERCRED → `/proc/<pid>/environ` →
`TILLANDSIAS_PROJECT` (`tray/mod.rs:649-676`), answers `initialize` with a
hardcoded `"protocolVersion": "2024-11-05"` (`tray/mod.rs:702`), returns a
hardcoded three-tool `tools/list` array (`tray/mod.rs:710-742`), and
dispatches `tools/call` trusting request args (`tray/mod.rs:743-801`;
`-32601` for unknown tools/methods at `tray/mod.rs:798-805`). The host DIR
— not the socket file — is bind-mounted read-only into every forge as
`/run/host/tillandsias-mcp` with
`TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias-mcp/mcp.sock`
(`crates/tillandsias-headless/src/main.rs:10979-10991`; helper
`mcp_socket_host_dir` at `main.rs:3425-3427`), so a tray restart's re-bind
stays visible inside a running forge.

## Corrected grounding claims (packet requirement — verified @ 2f15c1da)

The original design contained claims its own red-team disproved. They are
corrected here and ONLY the verified statements appear in the spec deltas:

1. **FALSE: "`TILLANDSIAS_FORGE_INSTANCE` is threaded into the forge, so
   environ attribution can resolve the instance."** Verified at HEAD: every
   non-test read (`main.rs:4252`, `4289`, `8581`, `11047`) is a
   `std::env::var` in the HOST-side `tillandsias` process (the dispatcher
   spawns one host process per worker with the variable set — doc comment
   `main.rs:4165-4178`); occurrences at `main.rs:15681+` are tests. There
   is NO `.env("TILLANDSIAS_FORGE_INSTANCE", ...)` on any container spec —
   the variable is never injected into forge containers. Environ-based
   instance resolution therefore always yields the UNsuffixed container
   name, and "restart myself" would destroy the interactive lane (the exact
   order-427/428 collision class pinned by the test at
   `main.rs:14053-14081`). Spec consequence: identity comes from the
   per-lane listener ONLY (order 505); peer environ is untrusted,
   permanently.
2. **FALSE: "a dev-sessions state volume carries no credentials."** Verified
   at HEAD: the harness state dirs ARE credential locations — OpenCode's
   `auth.json` is not lock-protected and Codex's credential file is
   truncate-then-write (comment block `main.rs:11027-11045`); the vault
   restore helpers are `CODEX_HOME`-aware (`main.rs:4316-4340`). Persisting
   harness state would carry vault-delivered credentials past the
   container. Moot for this spec: **order 511 is REJECTED** (operator
   ruling round 2) — there is NO session persistence of any kind; resume is
   seed-prompt-only.
3. **Citation drift corrected** (design cited → verified at HEAD):
   - `resolve_peer_project` "tray/mod.rs:658-676" → `tray/mod.rs:649-676`.
   - dispatcher-trusts-args "tray/mod.rs:761-765" → the `tools/call` arm is
     `tray/mod.rs:743-801` (the cited category extraction is at 762-765).
   - `decide_image_build` "image_builder.rs:96-189" → the function is
     `crates/tillandsias-core/src/image_builder.rs:166-189`
     (`image_build_identity`, the SHA-256 identity over the build-context
     tree, is 96-165). Actions verified: `ForceRebuild|Build|Retag|Skip`
     with reasons `Forced|DigestMissing|LabelMismatch|AliasMissing|DigestPresent`.
   - `resource_lock.rs:105-115` → `acquire` is
     `crates/tillandsias-headless/src/resource_lock.rs:101-115`; verified
     it is a bounded LOCK_NB poll **waiting up to `timeout`** — i.e. a
     blocking wait. The B8 requirement (dev-control must use a short
     NON-blocking try and return `busy`) stands and is now normative.
   - curated-absence "tray-ux spec.md:111" → line 111 has drifted (it is
     now inside the per-project action-buttons requirement). The curated-UX
     doctrine lives in `openspec/specs/tray-ux/spec.md:14-24` ("UX curation
     governance"; "everything is curated to the last detail"). The spec
     cites the requirement, not a line number.
   - `(McpFrame, Vsock) => Unsupported` "control_dispatch.rs:127-131" →
     `crates/tillandsias-headless/src/control_dispatch.rs:130-131` (order
     514 flips this arm behind the same gate).
   - Verified UNCHANGED: `tools/list` array `tray/mod.rs:710-742`;
     `protocolVersion` pin `tray/mod.rs:702`; shared-dir mount
     `main.rs:10979-10991`; unsanitized `project_name` path joins
     `main.rs:12721-12722` (container-name format + worktree join);
     host-browser-mcp `2025-06-18` (`spec.md:19`,
     `tillandsias-browser-mcp/src/server.rs:191`); order-494 interim guard
     commit `1498c7fd`; order-459 harness curl-install cache
     (`plan/index.yaml` packet `harness-curl-install-launch-time`).

## Goals / Non-Goals

**Goals**
- Give the existing transport a spec of its own (`mcp-tool-socket`) with
  the order-505 per-lane socket model as its normative attribution story.
- Reconcile the protocolVersion drift explicitly, in spec — not silently in
  code (recorded conflict (c) of the decision record).
- Specify the two dev verbs exactly as ruled: component enum without
  `tray`, forge restart tiers, seed-prompt-only resume, two-key
  compile-time gate, `-32601` curated absence, refusal statuses.
- Make the release-artifact honesty falsifiable (litmus: released binaries
  contain no dev-control verb names).

**Non-Goals**
- Implementation (orders 505, 507–510, 512–514).
- Session/transcript persistence in any form (order 511 REJECTED —
  tombstoned; do not revive without a new operator decision).
- Any tray-rebuild capability (operator ruling: prohibited permanently —
  advisory tickets only).
- Base-image chain rebuilds (`--init` territory; `dev_rebuild` targets leaf
  images only).
- The browser bridge (`spec:host-browser-mcp` continues to own it).

## Decisions

### D1: Per-lane sockets are a hard dependency, not an option

Attribution = which listener accepted. Order 505 binds
`<mcp_dir>/<project>-<instance>/mcp.sock` and mounts ONLY that lane's
subdirectory into that lane's forge; identity is kernel/filesystem-enforced
and maps to exactly one container name the tray itself chose. The red-team
PoC (`env TILLANDSIAS_PROJECT=attacker-wins …`) proved environ attribution
forgeable, and correction #1 above proves instance resolution via environ
is impossible even for honest peers. Therefore: the dev verbs MUST NOT be
dispatched on any connection attributed by environ — on the legacy shared
socket the verbs are absent even with both gate keys on. `publish_local`'s
label equality-validation (never sanitization — `project_name` is used
unsanitized in path joins today, `main.rs:12721-12722`) rides the same
repair. `control.sock` stays unmounted (decision `483c3472` preserved).

### D2: protocolVersion — negotiate, latest `2025-06-18`, shared constant

The drift: `mcp.sock` pins `2024-11-05` (`tray/mod.rs:702`); the sibling
host-browser-mcp surface pins `2025-06-18`
(`openspec/specs/host-browser-mcp/spec.md:19`, `server.rs:191`). Neither
surface implements MCP version negotiation. Resolution (explicit, per
recorded conflict (c)): the mcp-tool-socket server SHALL negotiate — echo
the client's requested revision when supported, else answer its own latest,
which SHALL be `2025-06-18`; and both host MCP surfaces SHALL source their
latest-supported revision from one shared constant so the drift cannot
recur. `2024-11-05` remains in the supported set (existing in-forge clients
were written against it; nothing in the order-363 tool surface or the dev
verbs requires post-`2024-11-05` protocol features — the verbs are plain
`tools/*`). Migration is a one-line change plus the constant extraction; the
retro-spec names today's pinned behaviour as the documented starting point.

### D3: Component enum has NO `tray` — but `tray-advisory` survives as a tier

Operator ruling round 1, #1: forge containers only; no agent-triggered tray
recompilation, EVER — the deterministic compiled tray is the idiomatic
layer that protects the host from rogue forge creations; rebuilding it from
agent-editable sources is arbitrary code execution on the host. So the
enum is `forge|proxy|git|inference`. The design's insight that container
*definitions* are Rust compiled into the tray remains true — when a
requested rebuild can only be satisfied by a tray recompile, the host
answers tier `tray-advisory`: an informational ticket surfaced in tray UI +
telemetry; a human runs `./build.sh --ci-full --install`. The verb never
builds the tray; the tier never acts.

### D4: Two tier vocabularies, deliberately distinct

- **Request-side (forge only): `restart_tier` = `restart|fresh|full`**
  (operator ruling round 2, #2). Tier 1 `restart`: new forge container from
  the same image; shared stack (proxy/git/inference/vault) untouched —
  near-equivalent to exiting the forge and relaunching from the tray. Tier
  2 `fresh`: additionally wipe that container's ephemeral cache, then
  launch. Tier 3 `full`: forced podman re-create through the idiomatic
  layer (known signature/certificate churn risk) — DEVELOPMENT TIME only.
- **Result-side: `tier` = what the HOST decided**
  (`rebuild+recreate|recreate-only|retag|noop|tray-advisory|rebuild-deferred`),
  derived from `decide_image_build` (`image_builder.rs:166-189`): digest
  mismatch → build+recreate; alias drift → retag (no recreate); digest
  present → recreate-only/noop. The agent states intent; the host picks the
  tier. True hot-reload of a live container does not exist in podman and is
  refused permanently.

### D5: Resume is seed-prompt-only (order 511 REJECTED)

Operator ruling round 2, #1: continuity is what the seed prompt is for —
with `./plan` and `./methodology`, a resume prompt is a bootstrap
("continue work #123"); every forge session starts new per the ephemeral
contract. So: no `--resume` threading, no session-id capture, no transcript
or harness-state persistence (which would also violate credential
quarantine — correction #2). What remains from order 509 (rescoped): the
relaunch REQUEST token (0600, TTL, host-generated nonce bound to the
ticket, atomic rename-on-consume, loud consume log — it authorizes and
deduplicates the restart, and carries the seed prompt; nothing to do with
session state) and injection-safe delivery: prompt travels env-only into
already-quoted exec lines, 8 KiB cap, and all three entrypoints place a
`--` separator before every injected positional (quoting is not argv
separation). The schema consequently has a flat `seed_prompt` string — the
design's `resume{session_id, initial_prompt}` object is gone.

### D6: Two-key gate — compile-time cfg + host env; no repo-identity key

Operator ruling (order 507 block + round 1 #3-4, round 2 #3): the
capability is a security hole in USER RUNTIME and must not ship in the
artifact at all.

- **Key 1 (compile-time)**: cargo feature `dev-control` on
  `tillandsias-headless`, NOT in `default` (existing features precedent:
  `default = ["vault"]`, `tray`, `listen-vsock` — `Cargo.toml:70-86`),
  never enabled by any release/CI artifact build. It exists only in local
  dev builds from a source checkout. Doctrine, precisely: DEVELOPMENT
  TIME = built from a source checkout; END USER RUNTIME = curl-installed
  artifact, no Tillandsias checkout access, containers SEALED.
- **Key 2 (runtime)**: `TILLANDSIAS_DEV_CONTROL=1` read ONCE from the
  TRAY's own process env at MCP socket-server start. Forge env is authored
  by the host; peer input is never used for gating. Idiom lineage:
  `TILLANDSIAS_ENABLE_E2E_TESTS`, `TILLANDSIAS_DESTRUCTIVE_RESET_OK`.
- **No repo-identity key**: the Tillandsias repo gets no auto-opt-in; repo
  identity is spoofable and END USERS never receive development privileges
  ("DEVELOPMENT TIME only, just me"). This supersedes the design's
  per-project allowlist key shape (repair B9): B9's threat — one malicious
  repo's agent owning a dev host through a global gate — is answered by
  key 1 (the binary an end user runs cannot do this at all) plus key 2
  (explicit operator opt-in on the operator's own tray process) plus D1
  (per-lane identity + per-lane rate buckets bound what any one lane can
  do).
- **Off ⇒ curated absence** (tray-ux "curated to the last detail"
  doctrine): `tools/list` omits the verbs (the hardcoded array
  `tray/mod.rs:710-742` becomes a builder) and `tools/call` answers the
  byte-identical `-32601` shape of any unknown tool
  (`tray/mod.rs:798-800`) — unit-tested indistinguishable from
  nonexistence.
- **Litmus**: a release-artifact assertion that the released binary
  contains neither `dev_rebuild` nor `dev_rebuild_status` as strings
  (folded into orders 507/513 per ruling round 1 #3).
- When both keys are on, `TILLANDSIAS_DEV_CONTROL=1` passes into forge env
  as a read-only SIGNAL so order-458 `agent_init.sh` mentions the verbs;
  the signal grants nothing (order 512).

### D7: Unpushed-work refusal (repair B5)

`/home/forge/src` is a hot tmpfs root; nothing persists the worktree; the
git mirror is the only push channel. "Restart me" would silently discard
every commit not yet pushed. `component=forge` (and `git`) REFUSES unless
the worktree is clean AND HEAD is reachable from a ref on the lane's
mirror; else status `refused-unpushed-work` naming the exact `git push`
command (ephemerality error policy: errors name the exact command).
Optional `push_first: true` performs the mirror push first and refuses on
push failure.

### D8: Ticket registry — dedupe key rescoped without session_id

Design had `sha256(project,instance,component,session_id)[..8]`; with
session-id capture dropped (D5) the dedupe key is
`sha256(project,instance,component)[..8]`. An in-flight duplicate returns
the SAME ticket; a duplicate after a terminal status starts a legitimate
new cycle. `dev_rebuild_status` with no ticket lists only tickets of the
caller's listener-derived lane; it never echoes another lane's
`reason`/`seed_prompt` (repair B10 — no cross-lane oracle).

### D9: Non-blocking locks + rate limits (repair B8)

`resource_lock::acquire` is a bounded blocking poll (verified,
`resource_lock.rs:101-115`) and the tray's own launch path can hold the
image lock for ~900 s. Dev-control therefore acquires the image
`resource_lock` with a short NON-blocking try and returns status `busy` —
it never queues behind the launch path. Rate buckets are keyed on the
unforgeable lane identity plus one host-wide global bucket; exhaustion
returns `rate-limited`. Superseded agent-initiated leaf digests are pruned
(reconciles with the no-`podman system reset` rule).

### D10: Kept-warm caches are named preconditions, not folklore

"Restart is a breeze" only while: (1) the podman image store's canonical
`sha256-` tags + layer cache persist (this surface never invokes
`podman system reset`); (2) base-image chain digests cascade via
`dependency_digests`, leaf-only targeting; (3) **the order-459 harness
curl-install artifact cache lives host-side of the mount boundary** — else
every fast recreate pays the full Claude/OpenCode download, the single
biggest recreate cost (packet `harness-curl-install-launch-time`,
operator directive 2026-07-21); (4) the git-mirror container survives forge
recreate (leak-not-destroy, order 494) so `/home/forge/src` re-clones from
the warm local mirror; (5) cheatsheets tmpfs repopulates from the image,
free.

## Risks / Trade-offs

- **[R1] Two tier vocabularies confuse implementers.** → Mitigation: the
  spec names them `restart_tier` (request, forge-only) and `tier` (result,
  host decision) and never uses bare "tier" for the request side.
- **[R2] `2024-11-05` clients break if the server answers `2025-06-18`.** →
  Mitigation: negotiation echoes the client's requested revision when
  supported; `2024-11-05` stays in the supported set.
- **[R3] The cargo-feature gate forks test coverage** (release builds no
  longer compile the dev-control paths). → Accepted by operator ruling
  (release-artifact honesty outranks one-binary uniformity; the earlier
  "one binary + runtime env" stance is superseded). CI runs the gate-off
  indistinguishability tests on the release-shaped build and the
  functional tests on a `--features dev-control` build.
- **[R4] Per-lane socket migration races the dev-verb rollout.** →
  Mitigation: D1 makes order 505 a hard precondition; on the legacy shared
  socket the verbs are absent regardless of keys, so a partially-updated
  host fails closed.
- **[R5] `rebuild-deferred` may look like a hang to an eager agent.** →
  Mitigation: the status taxonomy documents it as terminal-for-this-cycle;
  order 512's cheatsheet instructs "never retry-hammer".

## Migration Plan

1. This change (order 506): specs land; no code.
2. Order 505 ships FIRST (standalone security value — it closes the
   pre-existing `publish_local` impersonation hole even if dev-control
   never ships): per-lane sockets + listener identity + equality label
   validation. `mcp-tool-socket` retro-spec becomes fully true at that
   point; until then its per-lane requirements are the delta being built.
3. Orders 507 → 508 → 509/510 implement the gate, shared-component path,
   and forge self-restart against `dev-control-mcp` requirements.
4. Orders 512 (advertisement/cheatsheet/tray tickets), 513 (end-user
   transparency litmus), 514 (vsock arm for Windows/macOS dev hosts behind
   the same gate — `control_dispatch.rs:130-131` arm flip).
5. Sync deltas to `openspec/specs/` (`/opsx:sync dev-control-mcp`), add
   litmus bindings, retarget the `mcp.sock` code's `@trace` lines from
   `spec:host-browser-mcp` to `spec:mcp-tool-socket`.

Rollback: the surface is spec + gated code; unset key 2 (or ship without
key 1) and the verbs are absent — indistinguishable from never having
existed, which is itself a specified requirement.

## Open Questions

None. All four open questions of the decision record were closed by the two
operator-rulings sections of 2026-07-28 (forge-only scope / no tray
recompile ever; sealed user runtime; compile-time gate; no repo-identity
key; order 511 rejected; order 514 pulled to v0.5; tray-advisory always
requires a human build).
