# Forge rebuild/reload MCP surface ("dev-control") — design record (2026-07-28)

- **Class**: research/ (decision record; spawns implementation packets, orders 505-514)
- **Provenance**: operator directive, The Tlatoani, 2026-07-28; designed and adversarially reviewed 2026-07-28. Design grounded @ e57b6a3d, red-team re-verified @ 05fff9d6 — re-verify citations at P1 (grounding drift noted).
- **Red-team verdict**: **adopt-with-repairs, 4 CRITICAL blocking** (B1-B4). The engineering spine (tiering, build-before-destroy, tray-advisory, refusing hot-reload) survived attack; the authorization model did not and is rebuilt below. All 13 findings dispositioned.

## 1. Operator directive & doctrine anchors

A development-gated MCP surface letting in-forge agents ask the host tray: "this forge/proxy needs rebuilding"; "restart this forge and re-launch me with `--resume <id>` and `<initial prompt>`"; hot-reload of a container when only the definition changed. DEVELOPMENT features, explicitly gated, disabled for end-user runtime. Anchors: ephemerality (destroy-and-recreate over fix-forward; errors name the exact recreate command); leak-not-destroy (order 494, interim guard 1498c7fd: plain `podman rm`, refusal on running siblings, shared teardown skipped with loud REFUSING warnings); curated UX (dev verbs ABSENT in end-user runtime, not erroring — openspec/specs/tray-ux/spec.md:111).

## 2. Verb surface — exactly two tools

No `container_hot_reload` verb: true hot-reload is incoherent (§5), and tiering is a HOST decision via `decide_image_build` (tillandsias-core/src/image_builder.rs:96-189). The agent states intent; the host picks the tier.

**`dev_rebuild`** — rebuild/recreate a component in the CALLER'S OWN lane stack:
```json
{"name":"dev_rebuild","inputSchema":{"type":"object","properties":{
  "component":{"type":"string","enum":["forge","proxy","inference","git","tray"]},
  "reason":{"type":"string","maxLength":2000},
  "push_first":{"type":"boolean"},
  "resume":{"type":"object","properties":{
     "session_id":{"type":"string","pattern":"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"},
     "initial_prompt":{"type":"string","maxLength":8192}},
   "required":["session_id"]}},
 "required":["component","reason"]}}
```
Result: `{"ticket":"<sha8>","tier":"rebuild+recreate|recreate-only|retag|noop|tray-advisory|rebuild-deferred","teardown_deadline_secs":N|null,"note":"..."}`.

The inputSchema is ADVERTISEMENT, not enforcement (B12 — today's dispatcher trusts args, tray/mod.rs:761-765): the server implements an explicit `match` with a **default-deny arm** before any name/path construction.

Per component: `forge` = self-restart lifecycle (§4); `proxy`/`inference` (shared) = image rebuild serialized, recreate strictly via the order-494 protocol — sibling holds it ⇒ tier `rebuild-deferred` (new digest lands; content-addressed `sha256-` tags mean nothing is yanked from running containers; recreate at next zero-refcount teardown); `git` = recreate refused while ANY live lane of the project holds it (the mirror is the only push channel; mid-clone teardown was the order-494 incident) and subject to the same unpushed-work refusal as `forge` (B5); `tray` = **ADVISORY-ONLY, forever** — container definitions are Rust compiled into the tray; auto-building the tray from sources an in-forge agent can edit is arbitrary-code-execution on the host. The verb enqueues a ticket surfaced in tray UI + telemetry; a human runs `./build.sh --ci-full --install`.

**`dev_rebuild_status`** — optional `ticket`; no ticket → tickets **scoped strictly to the caller's listener-derived lane identity** (B10 — never a cross-lane oracle; never echo another lane's reason/prompt). Phases: `queued|building|ready|pending_teardown|recreating|done|failed|refused-sibling-live|refused-unpushed-work|busy|rate-limited`. Ticket+poll replaces push progress (the NDJSON tunnel has no notification convention; multi-minute builds must not look hung).

## 3. Transport + auth — per-lane sockets (red-team B1/B2 override the original design; choice recorded)

Original design reused the single order-363 `mcp.sock` with SO_PEERCRED → `/proc/<pid>/environ` attribution. Red-team PROVED this unsound: environ is self-asserted at execve (PoC: `env TILLANDSIAS_PROJECT=attacker-wins …`), the same host dir is mounted into every forge of every project (main.rs:3416-3427, 10979-10991), and `TILLANDSIAS_FORGE_INSTANCE` is never actually injected into forge containers (main.rs:4252/4289/11047 are host-side reads; 15681+ are tests) — so instance resolution would always yield the UNsuffixed container name and "restart myself" would destroy the interactive lane (the exact orders-427/428 collision, pinned by main.rs:14057-14071). With forged attribution, the design would also have pre-authorized stop-then-rm of siblings (B3 — order-494's guard refuses only RUNNING containers; stopping first converts refusal into success) and cross-enclave resume-token planting (attacker-authored `initial_prompt` executed later with the victim's credentials and push rights) — an enclave-isolation violation.

**Adopted repair (P0, order 505 — has standalone value: it closes the pre-existing order-363 publish_local hole even if dev-control never ships):**
- **Per-lane socket**: bind `<mcp_dir>/<project>-<instance>/mcp.sock`; mount ONLY that lane's subdirectory into that lane's forge. Attribution = which listener accepted — kernel/filesystem-enforced, unforgeable, zero `/proc` reads. Dir-mount preserved, so the tray-restart re-bind rationale survives. B13 (pid-reuse TOCTOU) vanishes.
- **Identity from the listener, never injected-and-trusted**; `(project, instance)` maps to exactly one container name the tray itself chose.
- **Label validation by equality** against the tray's enumerated local projects, never by sanitizing (B7 — `project_name` is used unsanitized in paths today, main.rs:12721-12722; resume-token and state paths would otherwise be attacker-positioned host writes).
- **Ownership proof before any stop-then-rm** (B3): stop-then-rm is permitted ONLY for the exact container the listener identity maps to (true self-restart); everywhere else plain `rm` (no pre-stop) remains the ownership assertion.
- control.sock stays unmounted (preserves decision 483c3472); no new privileged channel.

## 4. Restart-and-resume contract

**Round-trip order (kept verbatim — red-team: "genuinely failure-safe"):** (a) verb arrives, ticket issued, reply sent — old forge STILL RUNNING; (b) image rebuild (`ensure_image_exists` force path) — build FAILS ⇒ status `failed`, nothing destroyed, agent keeps working; (c) build green → write resume token → `pending_teardown` with deadline (default 30s); (d) deadline → stop+rm of the listener-proven OWN container only; (e) relaunch via the normal pipeline: launcher finds `state/resume/<project>/<instance>.json`, atomically renames to `.consumed-<ts>` (idempotent: duplicated relaunch finds no token, starts fresh), injects `TILLANDSIAS_RESUME_SESSION_ID` + prompt env; entrypoints grow one branch (`claude --resume` / `codex exec resume` / opencode equivalent); (f) recreate FAILS after destruction → lane down, token retained, ticket `failed` naming the exact recreate command (ephemerality error policy); next manual launch consumes the token.

**Repairs folded in:**
- **Unpushed-work refusal (B5 — the explicit answer the brief demanded):** `/home/forge/src` is a hot tmpfs root; nothing persists the worktree; under the operator directive agents commit freely on lane branches and the mirror is the only push channel, so "restart me" would silently discard every commit not yet pushed. Therefore `component=forge` (and `git`) REFUSES unless the worktree is clean AND HEAD is reachable from a ref on the lane's mirror; else `refused-unpushed-work` naming the exact `git push` command. Optional `push_first:true` performs the mirror push and refuses on push failure.
- **Argv safety (B6):** session_id pattern is dash-anchored (`^[A-Za-z0-9]…`) — the original regex admitted `-h`/`--config`; and ALL three entrypoints place a `--` separator before every injected positional (quoting is not argv separation). Prompt travels only via env into already-quoted exec lines, capped 8 KiB, logged to telemetry.
- **Token hardening (B11):** 0600 host-side token gains a TTL checked at consume (refuse-and-delete on expiry), a host-generated nonce bound to the ticket registry, a requirement that the ticket still be `pending_teardown|recreating` at consume, and a loud consume log. Single-use rename bounds count; TTL bounds detonation time.
- **Session-STATE persistence — the honest gap, resolved against the original design (B4):** the design's `state/dev-sessions` bind-mount of the harness state dir is REJECTED — harness state dirs ARE the credential locations (`CODEX_HOME` vault-restore comment main.rs:11020-11040; OpenCode `auth.json`); mounting them onto a persistent host volume makes vault-delivered credentials outlive the container — a credential-quarantine violation and a new at-rest surface. **First drain ships resume WITHOUT persistent session state**: honest semantics = fresh harness session seeded with `initial_prompt` (+ best-effort `--resume` that works only if the harness finds state, i.e., normally not). A transcripts-ONLY persistence design (explicit allowlist copy-out at teardown, litmus asserting no credential filename ever appears under the volume) is a separate operator-gated packet (order 511), since without it the operator's `--resume` ask is continuity-cosmetic.
- Duplicate requests: ticket = sha256(project,instance,component,session_id)[..8]; in-flight duplicate returns the SAME ticket; post-completion duplicate starts a legitimate new cycle.

## 5. Rebuild vs recreate — honesty

Host-side tiering via `decide_image_build` (SHA-256 over build-context tree + build_args + dependency_digests): digest mismatch → build+recreate; alias drift → retag, no recreate; digest present → recreate-only ("fast recreate"). **True hot-reload (mutating a live container's env/mounts/args) does not exist in podman and contradicts immutability + `--rm` + tmpfs hot roots — refused, permanently.** The operator's "hot-reload when only the container definition changed" premise is architecturally inverted: image-content changes need NO tray restart (content-addressed images); definition changes are Rust compiled into the tray and need ONLY a tray restart — hence tier `tray-advisory`, never silent. Fast recreate = destroy + `podman run` from cached image; cheap because every expensive input is cached (§8). `dev_rebuild` targets leaf images only; base-chain rebuilds remain `--init` territory.

## 6. Feature gate — two-key, host-side only

- Key 1: `TILLANDSIAS_DEV_CONTROL=1` read ONCE from the TRAY's own process env at socket-server start. Forge env is authored entirely by the host; peer input is never used for gating — structurally unsettable from inside.
- Key 2 (B9 — the global gate would let one malicious repo's agent own the dev host): **per-project opt-in held host-side** (allowlist in the tray state dir / lane-registry flag at launch). Non-opted projects are indistinguishable from gate-off.
- Default OFF. Off ⇒ `tools/list` omits the verbs (hardcoded array mod.rs:710-742 becomes a builder) and `tools/call` returns the SAME -32601 as any unknown tool — curated ABSENCE per tray-ux spec, not "gated but visible".
- One binary + runtime env, no cfg-feature fork (release-artifact honesty; idiom lineage: `TILLANDSIAS_ENABLE_E2E_TESTS`, `TILLANDSIAS_DESTRUCTIVE_RESET_OK`, `runtime_phase::refusal()`).
- When on, `TILLANDSIAS_DEV_CONTROL=1` is passed into forge env as a read-only SIGNAL so order-458 `agent_init.sh` mentions the verbs; the signal grants nothing.

## 7. Abuse cases & mitigations (post-repair)

| Threat | Mitigation |
|---|---|
| Cross-lane impersonation (B1/B2/B13) | Per-lane sockets; listener-derived identity; no environ trust |
| Sibling destruction via stop-then-rm (B3) | Ownership proof = listener↔container equality; plain rm elsewhere; order-494 protocol for shared components |
| Credential persistence (B4) | No harness-state-dir mount; transcripts-only design operator-gated with credential-exclusion litmus |
| Silent work loss (B5) | refused-unpushed-work + clean-worktree + HEAD-on-mirror precondition; push_first |
| Argv injection (B6) | Dash-anchored id regex; `--` separators; env-only prompt transport |
| Host path traversal (B7) | Equality validation against enumerated projects; single-path-component reject |
| Rebuild-loop DoS / launch-path wedge (B8) | Rate bucket keyed on UNFORGEABLE lane identity + host-wide global bucket; image lock acquired with short NON-blocking try (status `busy`) — never queue 900s behind the tray's own launch path (resource_lock.rs:105-115); prune superseded agent-initiated digests (reconciles with the no-`podman system reset` rule) |
| Malicious repo on dev host (B9) | Two-key gate |
| Cross-lane disclosure (B10) | Status scoped to listener identity |
| Token replay / delayed detonation (B11) | Rename-on-consume + TTL + nonce + ticket-state binding + loud log |
| Schema bypass (B12) | Server-side default-deny match before any construction |
| Tray-rebuild ACE | Advisory-only, forever |
| Agent killed mid-flow | By design: deadline was in the first reply; token guarantees continuity |
| Cross-project image blast radius | Accepted under two-key gate; initiator `{project,instance,reason}` stamped into image-build-events.jsonl; digest identity ⇒ rebuild differs only if images/** bytes differ |

## 8. Cache-dependency statement ("restart is a breeze" preconditions)

1. Podman image store: canonical `sha256-` tags + layer cache persist; this design never invokes `podman system reset`; superseded-digest pruning (B8) is scoped to agent-initiated leaf digests only.
2. Base-image chain digests: cascades via dependency_digests; leaf-only targeting.
3. Order-459 tier-3 harness installs: the download/artifact cache MUST live host-side of the mount boundary or every fast-recreate pays the network — the single biggest recreate cost; named in the P1 spec as kept-warm.
4. git-mirror container survives forge recreate (lane dep, leak-not-destroy) — `/home/forge/src` re-clones from the warm local mirror.
5. cheatsheets tmpfs: repopulated from the image, free.
(Original item 6, dev-sessions volume, moved to the pending order-511 decision.)

## 9. Implementation shape (Rust + POSIX sh; forge-cycle-sized)

No new crate (order-456's crate is an in-forge read-only server — different animal). Crates: tillandsias-headless (dispatcher, orchestration, launch-time token consume), tillandsias-logging (initiator fields), tillandsias-control-wire (P7 only), images/default entrypoints (sh).

- **P0 (order 505, 4h, SHIPS FIRST, standalone security value)**: per-lane socket + listener-derived identity + equality label validation. Fixes B1/B2/B7/B13 and the existing order-363 hole.
- **P1 (506, 2h)**: OpenSpec change `dev-control-mcp`: retro-specify mcp.sock NDJSON transport; verbs + two-key gate + refusal statuses; reconcile protocolVersion drift (2024-11-05 vs host-browser-mcp's 2025-06-18) explicitly; CORRECT the design's false grounding claims (instance threading, "carries no credentials") so they cannot enter the spec; re-verify all citations vs current HEAD.
- **P2 (507, 3h)**: gate keys, tools/list builder, -32601 indistinguishability (incl. gate-off unit test), status scoping (B10), server-side default-deny (B12), rate limiter with non-blocking lock try + global bucket (B8).
- **P3 (508, 4h)**: dev_rebuild for proxy/inference/git: force path into ensure_image_exists, order-494 recreate protocol, ticket registry, telemetry initiator tagging, digest pruning. Litmus instant: refused-sibling-live.
- **P4 (509, 4h)**: resume plumbing without session-state persistence: session-id capture (3 entrypoints, sh; codex `thread.started` JSONL host-side), token store/consume with TTL+nonce (B11), dash-anchored validation + `--` separators (B6), env threading.
- **P5 (510, 4h)**: component=forge self-restart lifecycle: unpushed-work refusal + push_first (B5), ownership-proven stop+rm (B3), pending_teardown deadline, relaunch-with-inject, post-destroy-failure path with exact-command error; e2e litmus instant pre-build shape.
- **P6 (512, 2h)**: agent_init.sh advertisement, cheatsheet, tray-menu ticket visibility incl. tray-advisory queue.
- **Pending**: order 511 transcripts-only persistence (operator-gated); order 514 (P7) vsock arm `(McpFrame, Vsock)` for Windows/macOS behind the same gate.

First drain ~23h. Gate off ⇒ surface absent ⇒ "transparent to end users" holds.

## 10. Recorded conflicts & resolutions

(a) Operator's "hot-reload on definition change" is architecturally inverted — resolved as tray-advisory tier, never silent. (b) Session persistence is a credential exception, not merely a hot/cold one (red-team strengthened the design's own flag) — resolved by dropping the mount; transcripts-only variant operator-gated with litmus. (c) protocolVersion drift — resolved in P1 spec, not silently in code. (d) Designer's single-socket §2 vs red-team per-lane sockets — red-team wins on a working PoC; recorded above. (e) Designer's "belt and braces" (attribution + order-494 refusal) was one strap — replaced by listener-proof + refusal, genuinely two.

## 11. OPEN QUESTIONS for the operator

1. Resume continuity: accept a dev-gated, transcripts-only host volume (explicit spec exception, credential-exclusion litmus) — or ship resume as fresh-session+initial_prompt only (order 511 pending)?
2. Two-key gate: auto-opt-in the Tillandsias repo itself as the second key's first entry?
3. P7 vsock arm priority for Windows/macOS dev hosts — deferred to v0.6 acceptable?
4. Tray-advisory UX: acceptable that tray rebuilds ALWAYS require a human `./build.sh --ci-full --install`?
## Operator rulings — 2026-07-28 (The Tlatoani)

Recorded same-day, superseding the corresponding open questions above:

1. **Scope: forge containers ONLY.** No agent-triggered tray recompilation,
   ever — not even as a "build" tier. The deterministic compiled tray is the
   idiomatic layer that protects the host from rogue forge creations and
   keeps agents in-forge running "unrestricted" safely; rebuilding it from
   agent-editable sources would dissolve the boundary. The tray-advisory
   tier is informational tickets only; a human acts on them.
2. **Runtime doctrine.** DEVELOPMENT RUNTIME → supports container
   hot-recreation (this whole surface exists for development velocity).
   USER RUNTIME → containers are SEALED; no dev-control surface; freshness
   comes from the normal ephemeral/idempotent relaunch/recreate path — the
   Containerfiles are declarative "use latest" formulae, and a borked forge
   is fixed by recreate, not by any dev capability. Forge recreation in
   user runtime is for major updates (e.g. a Fedora revision), not routine.
3. **Gate is compile-time, not just env.** The capability is a security
   hole in USER RUNTIME and therefore must not exist in release artifacts
   at all: dev-control compiles only into local dev builds (cfg feature),
   plus the explicit host-side operator env opt-in at runtime. A litmus
   asserts released binaries contain no dev-control verb names (folded into
   orders 507/513).
4. **No repo-identity key.** The Tillandsias repo gets no auto-opt-in;
   END USERS never receive development privileges regardless of what
   project they run ("DEVELOPMENT TIME only, just me"). Agents working our
   tasks get self-improvement capabilities on the operator's dev hosts;
   agents on unknown tasks get nothing.
5. **Forge rootfs immutability** (adjacent directive): sealed running
   containers — order 515 filed; sidecars already --read-only, the forge
   container is the verified gap.
6. **Order 514 pulled to v0.5** (vsock arm for Windows/macOS dev hosts).
7. **Resume continuity (order 511)**: pending — operator asked for a plain
   explanation before ruling; see the packet.

## Operator rulings round 2 — 2026-07-28 (restart semantics + continuity closed)

1. **Order 511 REJECTED.** Continuity is what the seed prompt is for: with
   ./plan and ./methodology, a resume prompt is a bootstrap ("continue work
   #123"). Every forge session starts new per the ephemeral contract; all
   work is eligible to start without context — the forge bootstrap exists
   to handle exactly that. No transcript persistence, no quarantine
   exception. Order 509 rescoped accordingly (session-id capture dropped;
   request-integrity token + seed-prompt injection remain).
2. **Restart tiers.** "Restart me" means the FORGE, not the stack:
   - **Tier 1 — restart**: new forge container from the same image; shared
     stack (proxy/git/inference/vault) untouched. Near-equivalent to
     exiting the forge and relaunching from the tray UX.
   - **Tier 2 — fresh**: wipe that container's ephemeral cache, then
     launch again.
   - **Tier 3 — full recreation**: podman create force through the
     idiomatic layer (known signature/certificate churn risk) —
     DEVELOPMENT TIME only.
3. **Runtime boundary, precise definition.** DEVELOPMENT TIME = built from
   a source checkout. END USER RUNTIME = curl-installed artifact, no
   Tillandsias checkout access — much more restricted; anything that
   causes issues during end-user runtime gets restricted to development
   time. (Sharpens rulings 2-3 of round 1; consistent with the
   compile-time gating on orders 507/510.)
