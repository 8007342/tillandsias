# Tasks — cheatsheets-license-tiered

Phase 0 of the design's Migration Plan. Each task is verifiable in a single PR; tasks are ordered by dependency. Items deferred to Phase 1+ (telemetry consumption, auto-promotion, license-allowlist auto-merge, cross-project sharing) are explicitly OUT of scope.

## 1. Frontmatter schema v2 (the contract everything else depends on)

- [x] 1.1 Update `cheatsheets/runtime/cheatsheet-frontmatter-spec.md` to v2: add `tier`, `summary_generated_by`, `bundled_into_image`, `image_baked_sha256`, `structural_drift_fingerprint`, `local`, `package`, `pull_recipe`, `committed_for_project`, `shadows_forge_default`, `override_reason`, `override_consequences`, `override_fallback` to the schema; document the tier-conditional matrix (which fields are required/forbidden per tier); bump `last_verified` and add provenance entry for the v2 schema.
- [x] 1.2 Update `cheatsheets/TEMPLATE.md` to reflect the v2 frontmatter (default tier left blank for inference; commented placeholder fields for each tier-conditional field).
- [x] 1.3 Author `cheatsheets/runtime/cheatsheet-tier-system.md` describing the three tiers, their contracts, and worked examples for each (with full provenance per the cheatsheet provenance rule).
- [x] 1.4 Author `cheatsheets/runtime/cheatsheet-pull-on-demand.md` documenting the stub format (`### Source`, `### Materialize recipe`, `### Generation guidelines`); include a worked recipe for `docs.oracle.com` JDK API as the canonical example.
- [x] 1.5 Author `cheatsheets/runtime/cheatsheet-crdt-overrides.md` documenting the project-committed shadow flow, the four required override fields, and the runtime banner contract.
- [x] 1.6 Author `cheatsheets/runtime/cheatsheet-lifecycle.md` rendering the AUTHORED → BUNDLED-BAKED → LOADED → HIT/MISS → PULLED → REFINED → PROMOTED → RE-VERIFIED loop diagram; cite the `cheatsheets-license-tiered` spec.

## 2. Allowlist relocation and CRDT repurpose

- [x] 2.1 `git mv cheatsheet-sources/license-allowlist.toml cheatsheets/license-allowlist.toml` (preserves history).
- [x] 2.2 Add `default_tier`, `last_evaluated`, `evaluated_by` fields to every existing `[domains."..."]` entry in the relocated TOML; default the inference for currently-allowlisted bundleable domains to `default_tier = "bundled"`; default off-allowlist or do-not-bundle entries to `default_tier = "pull-on-demand"`.
- [x] 2.3 Add new `[domains."docs.oracle.com"]` entry with `default_tier = "pull-on-demand"`, `evaluated_by = "hand-curated"`, `license = "oracle-ftc"`, `redistribution = "do-not-bundle"`.
- [x] 2.4 Update header comment in the TOML to document the CRDT semantics (`evaluated_by`, `last_evaluated`, telemetry `license_drift` events).

## 3. Bundled-tier infrastructure

- [x] 3.1 Extend `scripts/fetch-cheatsheet-source.sh` with a `--tier=bundled` mode: read the cheatsheet frontmatter to filter by tier, output to a cache-key-named directory under `$CACHE_DIR/cheatsheet-source-bake/<key>/`, write `.meta.yaml` sidecars per file (preserving existing fetch semantics: GitHub blob rewrite, IETF .txt preference).
- [x] 3.2 Add structural-drift fingerprint computation to the fetcher: extract `<h1>+<h2>+<h3>` text via `htmlq` (preferred; check availability) or a 30-line Python helper; output `SHA256(joined)[:16]`; store in the cache-key directory's per-file sidecar.
- [x] 3.3 Implement the cache-key derivation: `SHA-256( sorted(union(URLs)) || --max-age-days flag )`; document the algorithm in a comment block at the top of the new code.
- [ ] 3.4 Add the fetch-and-bake stage to `scripts/build-image.sh forge` immediately before the existing `cheatsheets/` COPY: invoke `scripts/fetch-cheatsheet-source.sh --tier=bundled` on cache miss, stage `<key>/` as the build context's `cheatsheet-sources/` subtree, COPY into the image at `/opt/cheatsheet-sources/`.
- [ ] 3.5 Wire the `--max-age-days N` and `--refresh-sources` flags through `build-image.sh` to the fetcher; default 30 days for local builds; CI passes 7.
- [ ] 3.6 On every successful bundled fetch, write `image_baked_sha256` and `structural_drift_fingerprint` to `<build-context>/.cheatsheets-meta/<category>/<name>.frontmatter.json` (side-channel; avoids rewriting the cheatsheet inside the image).
- [ ] 3.7 Implement network-failure-non-blocking behaviour: on fetch failure, reuse the previous cache key directory if any; emit `WARN: network unreachable, reusing cache key <prev>`; do NOT fail the build; do NOT bump `last_verified`.

## 4. Distro-packaged tier infrastructure

- [x] 4.1 Add package-manifest discovery to `scripts/check-cheatsheet-sources.sh`: try `flake.nix` `contents` parsing first, then `images/default/Containerfile` `dnf install` lines, then `images/default/distro-packages.txt`; accept the first source that succeeds.
- [x] 4.2 Add `package:` validation: for each `tier: distro-packaged` cheatsheet, confirm the declared package is in the discovered manifest; emit ERROR if missing with `ERROR: distro-packaged cheatsheet references missing package: <name>`.
- [ ] 4.3 Add post-build in-image validation: confirm the `local:` path (e.g., `/usr/share/javadoc/...`) exists inside the built forge image; emit ERROR if missing.
- [x] 4.4 Author `cheatsheets/build/distro-packaged-cheatsheets.md` (with full provenance) describing how to add a new distro-packaged cheatsheet (pick a doc package, add to forge image manifest, author cheatsheet with `tier: distro-packaged`).

## 5. Pull-on-demand tier infrastructure

- [x] 5.1 Add stub-completeness validation to `scripts/check-cheatsheet-sources.sh`: confirm `## Pull on Demand` section exists with `### Source`, `### Materialize recipe`, `### Generation guidelines` sub-headings; confirm `### Materialize recipe` is a non-empty fenced bash block; confirm frontmatter contains `pull_recipe: see-section-pull-on-demand` (any other value = ERROR).
- [x] 5.2 Add license declaration validation: confirm `### Source` block contains a license SPDX or short identifier AND a canonical license URL; emit ERROR if missing.
- [ ] 5.3 Define the per-project pull cache layout (`~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>`) in shell helper code under `images/default/lib-common.sh` — agents read the path via an exported env var (e.g., `TILLANDSIAS_PULL_CACHE`).
- [ ] 5.4 Implement the tiered RAMDISK soft-cap detection at tray startup: read `/proc/meminfo` `MemTotal`; classify as Modest (<8 GiB → 64 MB) / Normal (8–32 GiB → 128 MB) / Plentiful (≥32 GiB → 1024 MB); emit the resolved cap to the forge launch context as `forge.pull_cache_ram_mb`.
- [ ] 5.5 Wire `forge.pull_cache_ram_mb` override from `~/.config/tillandsias/config.toml` (override wins over auto-detection).
- [ ] 5.6 Implement tmpfs-with-disk-spillover for the pull cache: tmpfs under `~/.cache/tillandsias/cheatsheets-pulled/<project>/` capped at the soft cap; auto-spill to disk under the same path when cap is exceeded; LRU eviction operates within the per-project subtree only.

## 6. CRDT override discipline + project-committed cheatsheets

- [ ] 6.1 Extend `populate_hot_paths()` in `images/default/lib-common.sh` to merge `<project>/.tillandsias/cheatsheets/` into `/opt/cheatsheets/` AFTER copying `/opt/cheatsheets-image/`; project-committed files at the same path overwrite forge defaults.
- [ ] 6.2 Add shadow detection to `populate_hot_paths()`: for each project-committed file, check if a same-pathed file exists in `/opt/cheatsheets-image/`; if yes, parse the project frontmatter and emit one banner line per shadow: `[cheatsheet override] <path> → project version (reason: <first line of override_reason>)`.
- [ ] 6.3 Add shadow validation to `scripts/check-cheatsheet-sources.sh`: for each cheatsheet under `<project>/.tillandsias/cheatsheets/` (or `cheatsheets/`-relative paths in project artifacts), check `shadows_forge_default` presence; if set, ERROR if any of `override_reason`, `override_consequences`, `override_fallback` is missing or empty.
- [ ] 6.4 Add a runtime renderer (in `populate_hot_paths()` or a small helper) that surfaces `override_reason`, `override_consequences`, `override_fallback` as a header block at the top of every shadowed cheatsheet's body inside `/opt/cheatsheets/<path>` (e.g., as a fenced `> [!OVERRIDE]` callout block before `## Quick reference`).

## 7. cheatsheet-telemetry EXTERNAL log producer

- [ ] 7.1 Author `images/default/external-logs.yaml` declaring `role: cheatsheet-telemetry` with `lookups.jsonl` (format `jsonl`, `rotate_at_mb: 10`, `written_by: forge-agent (claude / opencode / opsx)`).
- [ ] 7.2 Update `images/default/Containerfile` (and/or `flake.nix`) to bake `external-logs.yaml` at `/etc/tillandsias/external-logs.yaml` per the `external-logs-layer` contract.
- [ ] 7.3 Update the forge `ContainerProfile` in `src-tauri/src/profile.rs` (or wherever profile types live) to set `external_logs_role: Some("cheatsheet-telemetry")`.
- [ ] 7.4 Update the launcher (`src-tauri/src/handlers.rs` or `runner.rs`) to bind-mount `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/` RW at `/var/log/tillandsias/external/cheatsheet-telemetry/` inside every forge container (preserves the existing producer-mount pattern from `git-service`).
- [ ] 7.5 Extend `cheatsheets/runtime/external-logs.md` with the `cheatsheet-telemetry` role's JSONL schema (every field documented with type and meaning); add an example event for each `resolved_via` value.
- [ ] 7.6 Document the agent-side write contract (where in opencode/claude/opsx instructions to land the "emit a JSONL line for every cheatsheet consultation" guidance) — add to `cheatsheets/agents/opencode.md` and `cheatsheets/agents/claude-code.md` under a new "Telemetry obligations" section.

## 8. Tier-aware INDEX regeneration

- [ ] 8.1 Update `scripts/regenerate-cheatsheet-index.sh` to read each cheatsheet's frontmatter `tier` and validation state and append the correct badge: `[bundled, verified: <sha8>]`, `[bundled, partial-verify]`, `[distro-packaged: <package>]`, `[distro-packaged: MISSING]`, `[pull-on-demand: stub]`, `[pull-on-demand: project-committed]`.
- [ ] 8.2 Add a stripped-down shell version of the index regeneration to `populate_hot_paths()` (or call a small in-image helper) so `/opt/cheatsheets/INDEX.md` is re-rendered post-merge with project-committed entries and pulled-materialization `[pulled]` lines.
- [ ] 8.3 Update `cheatsheets/INDEX.md` (the host-tracked file) once after the new badges land so the diff is one focused commit.

## 9. Migration of existing cheatsheets to v2

- [ ] 9.1 Classify every existing cheatsheet under `cheatsheets/**/*.md` by tier: bundleable (allowlist `default_tier = bundled` and license permits) vs pull-on-demand. Output the classification as a CSV in the migration commit message for review.
- [ ] 9.2 Add `tier:` to every cheatsheet's frontmatter (matching the classification); add `summary_generated_by: hand-curated` (default for existing); add `bundled_into_image: true|false` per tier.
- [ ] 9.3 Author `## Pull on Demand` sections for each cheatsheet that classifies as pull-on-demand: copy from the cheatsheet's existing `## Provenance` URL list into the new `### Source`; author a minimal `### Materialize recipe` (curl + tar/unzip as appropriate); fill `### Generation guidelines` with per-cheatsheet hints; set frontmatter `pull_recipe: see-section-pull-on-demand`.
- [ ] 9.4 Run `scripts/build-image.sh forge` to populate `image_baked_sha256` and `structural_drift_fingerprint` for every bundled cheatsheet (build-time injection); verify the side-channel `.cheatsheets-meta/` is produced.
- [ ] 9.5 Re-run `scripts/regenerate-cheatsheet-index.sh` and commit the updated `cheatsheets/INDEX.md`.

## 10. Tombstones for superseded behaviour

- [ ] 10.1 Empty the host repo's `cheatsheet-sources/` directory: `git rm -r cheatsheet-sources/*` excluding `.gitkeep-tombstone`; commit `cheatsheet-sources/.gitkeep-tombstone` with header `@tombstone superseded:cheatsheets-license-tiered — the verbatim host-bundled source layer is replaced by image-baked /opt/cheatsheet-sources/ for the bundled tier and per-project pull cache for the pull-on-demand tier. Kept for traceability through 0.1.<N+3>.x. Final removal in 0.1.<N+3>.x per the three-release retention rule.`
- [ ] 10.2 Add `cheatsheet-sources/` to `.gitignore` (covers any local cache pollution).
- [ ] 10.3 Add `@tombstone obsolete:cheatsheet-source-layer — superseded by build-time fetch-and-bake in scripts/build-image.sh forge. Safe to delete after 0.1.<N+3>.x.` to `scripts/regenerate-source-index.sh`; comment out the script body but keep the file for three releases.
- [ ] 10.4 Add `@tombstone obsolete:cheatsheet-source-layer — superseded by build-time meta side-channel injection in build-image.sh. Safe to delete after 0.1.<N+3>.x.` to `scripts/bind-provenance-local-paths.sh`; comment out the body but keep the file.
- [ ] 10.5 Add `@tombstone obsolete:cheatsheet-source-layer — refresh moves to build-time --refresh-sources for bundled tier and agent-driven materialization for pull-on-demand. Safe to delete after 0.1.<N+3>.x.` to `scripts/refresh-cheatsheet-sources.sh`; comment out the body.
- [ ] 10.6 Audit `src-tauri/src/handlers.rs` and any other Rust code for references to a `forge.mount_source_layer` config option (the legacy host-mount opt-in); add `// @tombstone obsolete:cheatsheet-source-layer` markers and remove the option's effect (parsing it WARNs and ignores).

## 11. Forge image build validation

- [ ] 11.1 Build the forge image via `scripts/build-image.sh forge`; capture the size delta against the previous version (target ≤ +300 MB per the design's open question 1 resolution).
- [ ] 11.2 Confirm `/opt/cheatsheet-sources/<host>/<path>` exists for every bundled cheatsheet's cited URL: `podman run --rm <image> find /opt/cheatsheet-sources -maxdepth 3 -type f | wc -l` ≥ expected count.
- [ ] 11.3 Confirm `/opt/cheatsheets/INDEX.md` (post-`populate_hot_paths()`) renders the tier-aware badges correctly inside the forge: launch a forge container, `cat /opt/cheatsheets/INDEX.md | grep -E '\[bundled|distro-packaged|pull-on-demand|pulled\]' | wc -l` matches the cheatsheet count.
- [ ] 11.4 Confirm `/etc/tillandsias/external-logs.yaml` is baked: `podman run --rm <image> cat /etc/tillandsias/external-logs.yaml | grep '^role: cheatsheet-telemetry$'` exits 0.
- [ ] 11.5 Confirm the forge launch banner emits `[cheatsheet override]` lines when project-committed shadows are present (test with a fixture project under a temp dir).

## 12. Pre-commit hook + validator integration

- [ ] 12.1 Update `scripts/hooks/pre-commit-openspec.sh` (or the cheatsheet-specific hook) to run `scripts/check-cheatsheet-sources.sh --no-sha` and surface ERRORs as non-blocking warnings.
- [ ] 12.2 Confirm the hook still exits 0 even when ERRORs are present (CRDT-convergence philosophy preserved).
- [ ] 12.3 Add a CI job (or extend an existing one) that runs `scripts/check-cheatsheet-sources.sh` (with SHA check enabled) and FAILS on ERROR; this is the gating check for releases.

## 13. Trace annotations and commit hygiene

- [ ] 13.1 Add `# @trace spec:cheatsheets-license-tiered` to every shell file modified by this change (`scripts/build-image.sh`, `scripts/fetch-cheatsheet-source.sh`, `scripts/check-cheatsheet-sources.sh`, `scripts/regenerate-cheatsheet-index.sh`, `images/default/lib-common.sh`).
- [ ] 13.2 Add `// @trace spec:cheatsheets-license-tiered` to every Rust function modified by this change (`src-tauri/src/handlers.rs` external-logs role wiring, profile changes, `populate_hot_paths()` invocation if any).
- [ ] 13.3 Add `# @cheatsheet runtime/cheatsheet-tier-system.md` (and the other new cheatsheets) to the same files where they informed implementation.
- [ ] 13.4 Confirm `git grep '@trace spec:cheatsheets-license-tiered'` returns hits in shell, Rust, and markdown; commit message includes the GitHub search URL `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Acheatsheets-license-tiered&type=code` per the project commit convention.

## 14. Verify and archive prep

- [ ] 14.1 Run `openspec validate cheatsheets-license-tiered --strict`; fix every reported issue.
- [ ] 14.2 Run `/opsx:verify cheatsheets-license-tiered` and address gaps; confirm spec, design, tasks, and implementation converge.
- [ ] 14.3 Run `cargo test --workspace` and `./build.sh --test` to confirm no regression in the existing test suite.
- [ ] 14.4 Build the forge image one final time, run a smoke test (launch forge, `cat /opt/cheatsheets/INDEX.md`, materialize one pull-on-demand recipe, confirm `lookups.jsonl` records the events), then archive via `/opsx:archive cheatsheets-license-tiered` and run `./scripts/bump-version.sh --bump-changes`.
