## Why

The just-archived `cheatsheet-source-layer` mandates verbatim source storage in the repo, which (a) bloats git for material we have no clear redistribution rights to, (b) creates a license-compliance trap for any source NOT explicitly allowlisted, and (c) makes refresh a manual chore that drifts over time. We need a model where license-friendly material is bundled freely, non-redistributable material is *referenced and lazy-fetched*, and the cheatsheet itself stays a license-clean condensed summary regardless of upstream license.

## What Changes

- **Two cheatsheet redistribution tiers**, declared in each cheatsheet's frontmatter:
  - `tier: bundled` — license permits redistribution; full reference baked into forge image at build time.
  - `tier: pull-on-demand` — license forbids redistribution; only the *summary* and a deterministic **fetch recipe** (URL, archive layout, generation guidelines) are baked. Agents pull the live source through the proxy at runtime when they need depth.
- **Build-time fetch (slow path) → forge-image bake (hot path)** for the `bundled` tier. `scripts/build-image.sh forge` invokes `scripts/fetch-cheatsheet-sources.sh` to populate `/opt/cheatsheet-sources/` inside the image. Single-page-HTML official sources (e.g., JDK API single-page, SQL best-practices guides) are preferred — they double as the condensed reference.
- **Pull-on-demand stub format** for non-redistributable cheatsheets: each carries a `## Pull on Demand` section with: legal reason for non-bundling (license short ID + URL), upstream archive URL, extraction layout, and the agent-runnable steps to materialize content into a writable cache (`~/.cache/tillandsias/cheatsheets-pulled/<name>/`). The proxy handles fetch transparently — the agent does not need credentials.
- **Cheatsheets are summaries with provenance, never raw bytes.** Even bundled cheatsheets remain hand-curated condensed summaries; the bundled `cheatsheet-sources/` is supporting reference material an agent may consult for depth, not the cheatsheet itself. Provenance binds each cheatsheet to its underlying URL(s) + bundled-or-stub status.
- **Runtime-generated cheatsheets become the project-contextual layer.** When an agent generates a cheatsheet from a pulled source for a specific project's needs, it lands in the per-project hot path (`~/.cache/tillandsias/cheatsheets-pulled/`). Slow path → hot path is one-way, idempotent, and per-project so updates flow with upstream changes.
- **Tombstone the verbatim-bundle-everything model.** The just-archived `cheatsheet-source-layer` spec is superseded; its `Verbatim source storage` requirement is replaced by tier-gated storage. The license-allowlist concept survives but is reframed as a tier-classifier, not a bundling gate.
- **Drop the in-repo `cheatsheet-sources/` tree.** All currently-committed verbatim files become tombstoned: the cheatsheets that referenced them keep their URL provenance, the bytes move to build-time fetch.
- **Tighten provenance.** Every cheatsheet records: `tier`, `source_urls[]`, `last_verified` (date the summary was reconciled with the upstream URL), `summary_generated_by` (`hand-curated` / `agent-generated`), `bundled_into_image` (bool), and a **structural-drift fingerprint** (a stable SHA over the upstream's section headings) that CI can re-fetch and diff to flag silent upstream restructures.
- **@trace observability extends to cheatsheets.** Code that follows a cheatsheet pattern emits `cheatsheet = "<path>"` on log events; specs cite cheatsheets in `## Sources of Truth`; cheatsheets cite specs in their frontmatter. The triangle of code ↔ spec ↔ cheatsheet is queryable in both directions.

## Capabilities

### New Capabilities
- `cheatsheets-license-tiered`: tier system, fetch-at-build, pull-on-demand stub format, structural-drift fingerprinting, provenance schema v2.

### Modified Capabilities
- `cheatsheet-source-layer`: replace `Verbatim source storage` and `License allowlist gates bundling` requirements with tier-aware variants; soften `Hot/cold separation` to allow `/opt/cheatsheet-sources/` baked into forge image for the `bundled` tier (image-level redistribution only, never a host-mount).
- `agent-cheatsheets`: `## Provenance` section gains `tier:`, `bundled_into_image:`, and `summary_generated_by:` sub-fields; `local:` field becomes optional and gated on `tier: bundled`.
- `default-image`: forge build pipeline gains a fetch-and-bake stage gated on the cheatsheet tier.

## Impact

- **Repo size:** drops by the size of `cheatsheet-sources/` (currently 48 files across 16 publishers; future growth is upstream's image, not the repo).
- **Forge image size:** grows by the bundled-tier source set (bounded by license-friendly publishers — RFCs, MDN, OWASP, Rust docs, Python docs, etc.).
- **Build time:** `scripts/build-image.sh forge` adds a fetch step. Cached behind staleness check (re-fetch only if upstream URL list or `--max-age-days` flag changes).
- **Runtime:** new write path under `~/.cache/tillandsias/cheatsheets-pulled/` for agent-generated content; respects existing dual-cache architecture (per-project, never shared).
- **Code:** `scripts/fetch-cheatsheet-source.sh` extended with tier awareness; new `scripts/check-cheatsheet-drift.sh` for structural-drift fingerprinting; `scripts/regenerate-cheatsheet-index.sh` updated to label tiers in `INDEX.md`.
- **CI:** `scripts/check-cheatsheet-sources.sh` keeps `--no-sha` mode but adds tier-gated checks (only ERROR on missing bundled-tier files; pull-on-demand stubs validated for stub completeness instead).
- **Specs touched at archive time:** `cheatsheet-source-layer` (modify), `agent-cheatsheets` (modify), `default-image` (modify), plus new `cheatsheets-license-tiered`.
- **Tombstones:** `@tombstone superseded:cheatsheets-license-tiered` on the verbatim-storage code path and on the `## Hot/cold separation` requirement in the existing spec.
