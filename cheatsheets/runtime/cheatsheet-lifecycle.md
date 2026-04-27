---
tags: [meta, cheatsheet-system, lifecycle, crdt, convergence, telemetry, observability]
languages: []
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://en.wikipedia.org/wiki/Conflict-free_replicated_data_type
  - https://lamport.azurewebsites.net/pubs/time-clocks.pdf
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Cheatsheet lifecycle — the convergence loop

@trace spec:cheatsheets-license-tiered, spec:agent-cheatsheets, spec:external-logs-layer
@cheatsheet runtime/cheatsheet-tier-system.md, runtime/cheatsheet-crdt-overrides.md

**Use when**: You're reasoning about how cheatsheets converge across forge launches, project commits, and host refreshes — or implementing any of the eight states.

## Provenance

- Wikipedia, Conflict-free replicated data type: <https://en.wikipedia.org/wiki/Conflict-free_replicated_data_type> — convergence semantics this lifecycle inherits
- Lamport, "Time, Clocks, and the Ordering of Events in a Distributed System" (1978): <https://lamport.azurewebsites.net/pubs/time-clocks.pdf> — commit history as Lamport clock for the lifecycle's causal ordering
- `openspec/specs/cheatsheets-license-tiered/spec.md` — normative spec (lifecycle observability requirement)
- `openspec/changes/archive/2026-04-27-cheatsheets-license-tiered/design.md` "Cheatsheet Lifecycle" section — full diagram + per-transition signals
- **Last updated:** 2026-04-27

## Quick reference — the eight states

| State | What's true |
|---|---|
| **AUTHORED** | A `.md` exists under `cheatsheets/` (or `<project>/.tillandsias/cheatsheets/`) with v2 frontmatter. Tier set or inferable. |
| **BUNDLED-BAKED** | (bundled tier only) source fetched at forge build, SHA-pinned, structural-drift fingerprint stored. |
| **STUB-VALID** | (pull-on-demand tier only) `## Pull on Demand` section validated for required structure. |
| **LOADED** | Forge launched. `/opt/cheatsheets/` populated by `populate_hot_paths()`; `INDEX.md` regenerated with tier badges. |
| **HIT** | Agent read the cheatsheet; cheatsheet-telemetry event emitted with `resolved_via=bundled\|distro-packaged\|cached-pull`. |
| **MISS** | Agent read the cheatsheet but needed depth not present; cheatsheet-telemetry event emitted with `resolved_via=miss` and a `query` field. |
| **PULLED** | (pull-on-demand only) agent ran the recipe; source materialized at `~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>`; license re-evaluated; structural-drift fingerprint computed; license_drift event emitted if changed. |
| **REFINED** | Agent generated a project-contextual cheatsheet at `<project>/.tillandsias/cheatsheets/<name>.md`. If shadowing a forge default, CRDT override discipline applies. |
| **PROMOTED** | Manual `git mv` from `<project>/.tillandsias/cheatsheets/` to `cheatsheets/`. Phase 4 / future change scope. |
| **RE-VERIFIED** | Next bundled-tier rebuild OR scheduled refresh re-fetches source; structural-drift fingerprint diffed; `last_verified` bumped; `image_baked_sha256` re-pinned. |

## The loop diagram

```
AUTHORED ──build──▶ BUNDLED-BAKED / STUB-VALID ──launch──▶ LOADED
                                                              │
                                            ┌─────agent reads─┴───────┐
                                            ▼                         ▼
                                          HIT                        MISS
                                            │                         │
                                            └────► (loop)             │
                                                                      ▼
                                                                   PULLED ──license re-eval──▶ license_drift event
                                                                      │                       (host triages → manual TOML edit)
                                                                      ▼
                                                                   REFINED ── if shadows ──▶ CRDT override discipline
                                                                      │   ── if portable ──▶ PROMOTED (manual git mv)
                                                                      │
                                            next forge build ◀────────┘
                                                      │
                                                      ▼
                                                RE-VERIFIED ──▶ back to BUNDLED-BAKED ──▶ (loop)
```

## Common patterns

### Build-time observability (commit history + frontmatter)

Build-time transitions (`AUTHORED → BUNDLED-BAKED → RE-VERIFIED`) leave evidence in:
- The cheatsheet's frontmatter — `last_verified`, `image_baked_sha256`, `structural_drift_fingerprint` (bundled tier).
- Git commit history — `@trace spec:cheatsheets-license-tiered` annotations on commits that bake or refresh.
- Forge image metadata — `.cheatsheets-meta/<category>/<name>.frontmatter.json` side-channel for the SHA + fingerprint without rewriting the cheatsheet inside the image.

```bash
# When was this cheatsheet last verified?
yq '.last_verified' cheatsheets/runtime/cheatsheet-tier-system.md

# What's the build-pinned SHA inside the forge image?
podman run --rm tillandsias-forge cat /opt/.cheatsheets-meta/runtime/cheatsheet-tier-system.frontmatter.json
```

### Runtime observability (cheatsheet-telemetry EXTERNAL log)

Runtime transitions (`HIT`, `MISS`, `PULLED`, `license_drift`, `structural_drift`) emit JSONL events to the EXTERNAL log producer `cheatsheet-telemetry`. Schema:

```json
{
  "ts": "2026-04-27T10:23:11Z",
  "project": "<project>",
  "cheatsheet": "languages/jdk-api.md",
  "query": "asyncio cancellation semantics",
  "resolved_via": "bundled" | "distro-packaged" | "pulled" | "live-api" | "miss",
  "pulled_url": "https://docs.oracle.com/...",
  "chars_consumed": 4823,
  "spec": "cheatsheets-license-tiered",
  "accountability": true
}
```

```bash
# What's the agent missing in this project's cheatsheets?
jq -c 'select(.resolved_via == "miss")' \
  ~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/lookups.jsonl
```

The host-side `cheatsheet-telemetry` aggregator (v2 work) consumes these events to drive refresh prioritization. v1 emits only — the data accumulates so v2 can act.

### Refinement observability (project git history)

`REFINED` and `PROMOTED` transitions live in git:
- `<project>/.tillandsias/cheatsheets/` is project-tracked. Commits there show what the agent learned about this project's deviations.
- `git log` on the project bind mount surfaces refinement velocity.
- Promoted cheatsheets carry the convention: `promote: <project> → cheatsheets/<path>` in the commit message.

## Common pitfalls

- **Treating the lifecycle as a state machine** — it's a CRDT. A single cheatsheet can simultaneously be LOADED in forge instance A, REFINED in project B (different project), and being RE-VERIFIED on the host. Multiple states across replicas converge by structured discipline (override fields, manifest contracts, fingerprint comparisons).
- **Skipping RE-VERIFIED** — without periodic re-fetch, drift accumulates. The spec requires `Last updated:` ≤ 90 days; CI builds pass `--max-age-days 7` to enforce regular re-verification.
- **Silent project-committed REFINED that shadows a forge default** — without the four CRDT override fields, the validator emits ERROR. Refinement that changes project context MUST declare `override_reason`, `override_consequences`, `override_fallback`. See `runtime/cheatsheet-crdt-overrides.md`.
- **Trying to PROMOTE automatically across project boundaries** — `forge-cache-dual` per-project isolation forbids automatic cross-project visibility. Promotion is manual (`git mv` by the user or a host-side helper) and intentional.
- **Confusing PULLED with REFINED** — PULLED is just bytes-on-disk in the per-project pull cache. REFINED is the agent generating a project-contextual SUMMARY in the project bind mount. PULLED can repeat freely; REFINED is the durable artifact.
- **Forgetting that telemetry consumption is v2** — v1 emits events only. Don't author tooling that depends on host-side aggregation in the v1 timeframe.

## See also

- `runtime/cheatsheet-tier-system.md` — three tiers; lifecycle behaves slightly differently per tier
- `runtime/cheatsheet-pull-on-demand.md` — PULLED state mechanics
- `runtime/cheatsheet-crdt-overrides.md` — REFINED state with shadow discipline
- `runtime/cheatsheet-frontmatter-spec.md` — fields that record lifecycle state
- `runtime/external-logs.md` — EXTERNAL log producer/consumer contract
- `runtime/forge-hot-cold-split.md` — `populate_hot_paths()` is the LOADED transition's mechanism
