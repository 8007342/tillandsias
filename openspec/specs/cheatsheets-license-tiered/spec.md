<!-- @trace spec:cheatsheets-license-tiered -->

## Status

active

Promoted from: `openspec/changes/archive/cheatsheets-license-tiered/`
Annotation count: 61

## Requirements

### Three-tier classification of cheatsheets

Every cheatsheet under `cheatsheets/` MUST declare exactly one redistribution tier in its YAML frontmatter `tier:` field. The three permitted values are `bundled`, `distro-packaged`, and `pull-on-demand`. When `tier:` is omitted, the validator (`scripts/check-cheatsheet-sources.sh`) SHALL infer it from the first entry in `source_urls[]` by matching the URL's host against `cheatsheets/license-allowlist.toml`'s `default_tier` for that domain; if no domain match exists, the inferred tier SHALL default to `pull-on-demand` (the safe-default — never accidentally bundle an unaudited domain). The cheatsheet author MAY override the allowlist default by setting `tier:` explicitly and citing the per-document license in `## Provenance`.

#### Scenario: Bundled tier — explicit declaration

- **WHEN** a cheatsheet's frontmatter contains `tier: bundled` and `source_urls[0]` is `https://docs.python.org/3/library/asyncio.html`
- **THEN** the validator SHALL accept the declaration without warning
- **AND** the cheatsheet SHALL be included in the build-time fetch-and-bake stage
- **AND** the resolved tier in `cheatsheets/INDEX.md` SHALL be `[bundled, ...]`

#### Scenario: Distro-packaged tier — explicit declaration

- **WHEN** a cheatsheet's frontmatter contains `tier: distro-packaged` and `package: java-21-openjdk-doc`
- **THEN** the validator SHALL confirm `java-21-openjdk-doc` is present in the forge image's package manifest (extracted from `flake.nix` `contents` or `images/default/distro-packages.txt`)
- **AND** the cheatsheet SHALL NOT be included in the bundled fetch-and-bake stage
- **AND** the resolved tier in `INDEX.md` SHALL be `[distro-packaged: <package>]`

#### Scenario: Pull-on-demand tier — inferred from allowlist

- **WHEN** a cheatsheet's frontmatter omits `tier:` and `source_urls[0]` is `https://docs.oracle.com/en/java/javase/21/docs/api/`
- **AND** `cheatsheets/license-allowlist.toml` declares `[domains."docs.oracle.com"]` with `default_tier = "pull-on-demand"`
- **THEN** the validator SHALL infer `tier: pull-on-demand` and proceed
- **AND** the validator SHALL emit a WARN suggesting the author make the tier explicit in frontmatter

#### Scenario: Unknown domain — safe default to pull-on-demand

- **WHEN** a cheatsheet's frontmatter omits `tier:` and `source_urls[0]`'s host is NOT present in `cheatsheets/license-allowlist.toml`
- **THEN** the inferred tier SHALL be `pull-on-demand`
- **AND** the validator SHALL emit a WARN naming the missing allowlist entry

---

### Provenance schema v2 — frontmatter contract

Every cheatsheet's YAML frontmatter MUST carry the v2 schema fields below. Field presence is tier-conditional: the validator SHALL emit ERROR if a tier-required field is missing, and WARN if a tier-forbidden field is present.

| Field | bundled | distro-packaged | pull-on-demand |
|---|---|---|---|
| `tier` | required | required | required |
| `source_urls[]` | required (≥ 1) | required (≥ 1) | required (≥ 1) |
| `last_verified` (ISO date) | required | required | required |
| `summary_generated_by` | required (enum) | required (enum) | required (enum) |
| `bundled_into_image` | required: `true` | required: `true` | required: `false` |
| `image_baked_sha256` | required (build sets) | forbidden | forbidden |
| `structural_drift_fingerprint` | required (build sets) | optional | optional (agent sets) |
| `local` (path) | required | required | forbidden at author time |
| `package` | forbidden | required | forbidden |
| `pull_recipe` | forbidden | forbidden | required: `see-section-pull-on-demand` |
| `committed_for_project` | optional | optional | optional |

`summary_generated_by` SHALL be one of `hand-curated`, `agent-generated-at-build`, `agent-generated-at-runtime`. The pre-existing `## Provenance` markdown section is retained for human readability and SHALL agree with the frontmatter at validate time (URLs match, license names match).

#### Scenario: Bundled cheatsheet has full v2 frontmatter

- **WHEN** a `tier: bundled` cheatsheet is committed
- **THEN** its frontmatter SHALL contain `tier`, `source_urls`, `last_verified`, `summary_generated_by`, `bundled_into_image: true`, and `local`
- **AND** after the next `scripts/build-image.sh forge` run, `image_baked_sha256` and `structural_drift_fingerprint` SHALL be present (build-time injection)

#### Scenario: Pull-on-demand cheatsheet forbids bundled-only fields

- **WHEN** a `tier: pull-on-demand` cheatsheet's frontmatter contains `local:` or `image_baked_sha256:`
- **THEN** the validator SHALL emit ERROR identifying the forbidden field
- **AND** exit non-zero (subject to the pre-commit hook's non-blocking surfacing)

#### Scenario: Distro-packaged cheatsheet must name a package

- **WHEN** a `tier: distro-packaged` cheatsheet's frontmatter omits `package:`
- **THEN** the validator SHALL emit ERROR `MISSING package: for tier: distro-packaged`
- **AND** the cheatsheet SHALL NOT be considered valid for the build

#### Scenario: Frontmatter and Provenance markdown disagree

- **WHEN** a cheatsheet's frontmatter `source_urls[]` lists `https://example.com/a` but its `## Provenance` markdown section cites only `https://example.com/b`
- **THEN** the validator SHALL emit ERROR `PROVENANCE DRIFT: frontmatter vs markdown mismatch`

---

### Bundled-tier build-time fetch and image bake

`scripts/build-image.sh forge` MUST invoke a fetch-and-bake stage immediately before the existing cheatsheet staging step. The stage SHALL:

1. Read every cheatsheet's frontmatter under `cheatsheets/**/*.md` and filter to `tier: bundled`.
2. For each, derive the URL → `/opt/cheatsheet-sources/<host>/<path>` mapping (mirroring URL host structure).
3. Compute a cache key as `SHA-256( sorted(union(URLs)) || --max-age-days flag )`.
4. Look up the cache key in `$CACHE_DIR/cheatsheet-source-bake/<key>/`. On miss, invoke `scripts/fetch-cheatsheet-source.sh --tier=bundled` to populate that path.
5. Stage `<key>/` as the build context's `cheatsheet-sources/` subtree.
6. The forge image SHALL `COPY cheatsheet-sources/ /opt/cheatsheet-sources/` (image lower layer, RO at runtime, NOT a tmpfs view).
7. Inject `image_baked_sha256` and `structural_drift_fingerprint` into a side-channel `.cheatsheets-meta/<category>/<name>.frontmatter.json` so `populate_hot_paths()` can reflect the SHA in `INDEX.md` without rewriting the cheatsheet inside the image.

A `--refresh-sources` flag on `build-image.sh` SHALL force re-fetch regardless of cache hit. CI builds SHALL pass `--max-age-days 7`. **Network failure during fetch SHALL NOT fail the build** — the previous cache key (if any) is reused with a WARN, and the cheatsheet's `last_verified` is NOT bumped for failed fetches (preserves convergence-not-correctness).

#### Scenario: First-build cache miss triggers fetch

- **WHEN** `scripts/build-image.sh forge` runs and the computed cache key is absent from `$CACHE_DIR/cheatsheet-source-bake/`
- **THEN** `scripts/fetch-cheatsheet-source.sh --tier=bundled` SHALL run for every bundled cheatsheet's URLs
- **AND** the resulting `<key>/` directory SHALL be staged as the build context's `cheatsheet-sources/`
- **AND** the resulting forge image SHALL contain `/opt/cheatsheet-sources/<host>/<path>` for every fetched URL

#### Scenario: Cache hit on rebuild with no URL changes

- **WHEN** `scripts/build-image.sh forge` runs a second time with no changes to bundled-tier `source_urls[]`
- **THEN** the cache key SHALL match an existing `$CACHE_DIR/cheatsheet-source-bake/<key>/`
- **AND** the fetcher SHALL NOT be invoked
- **AND** the build SHALL complete without any network calls for cheatsheet sources

#### Scenario: Network failure preserves last-known-good and does not fail build

- **WHEN** `scripts/fetch-cheatsheet-source.sh --tier=bundled` is invoked and the network is unreachable
- **AND** a previous cache key directory exists under `$CACHE_DIR/cheatsheet-source-bake/`
- **THEN** the fetch step SHALL emit `WARN: network unreachable, reusing cache key <prev>`
- **AND** the build SHALL succeed using the previous cache
- **AND** no cheatsheet's `last_verified` field SHALL be bumped

#### Scenario: --refresh-sources forces re-fetch despite cache hit

- **WHEN** `scripts/build-image.sh forge --refresh-sources` runs
- **THEN** the fetcher SHALL be invoked even when the cache key matches an existing directory
- **AND** the directory SHALL be replaced with the freshly-fetched content

#### Scenario: Build does NOT fail on missing fingerprint pre-first-build

- **WHEN** a bundled cheatsheet has no `image_baked_sha256` (first build of a newly-added cheatsheet)
- **THEN** the validator SHALL emit WARN, not ERROR
- **AND** the build SHALL inject the SHA in this run

---

### Pull-on-demand stub format

A `tier: pull-on-demand` cheatsheet MUST include a `## Pull on Demand` section after `## See also`. The section SHALL contain three sub-headings in this exact order: `### Source`, `### Materialize recipe`, `### Generation guidelines`. The validator SHALL emit ERROR if any sub-heading is missing.

The `### Source` block SHALL list the upstream URL(s), the archive type (one of `single-html`, `zip`, `tar.gz`, `tar.xz`, `directory-recursive`), the expected size, the per-project cache target path under `~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>`, the SPDX or short license identifier, and the canonical license URL.

The `### Materialize recipe` block SHALL be a fenced bash code block (` ```bash ... ``` `) that an in-forge agent can `bash`-execute to populate the cache target. The recipe SHALL use only `curl`, `tar`, `unzip`, and POSIX shell builtins (every binary present in the forge image). The recipe SHALL respect the proxy via the existing `HTTP_PROXY=http://proxy:3128` env var without explicitly setting it (curl picks it up automatically).

The `### Generation guidelines` block SHALL describe how the agent produces a project-contextual cheatsheet from the pulled source, including frontmatter requirements (`summary_generated_by: agent-generated-at-runtime`, `tier: pull-on-demand`, `committed_for_project: true`).

#### Scenario: Stub with all three sub-headings is valid

- **WHEN** a `tier: pull-on-demand` cheatsheet contains a `## Pull on Demand` section with `### Source`, `### Materialize recipe`, `### Generation guidelines`
- **AND** the recipe is a non-empty fenced bash block
- **THEN** the validator SHALL accept the cheatsheet without ERROR

#### Scenario: Missing sub-heading emits ERROR

- **WHEN** a `tier: pull-on-demand` cheatsheet's `## Pull on Demand` section omits `### Materialize recipe`
- **THEN** the validator SHALL emit `ERROR: pull-on-demand stub missing sub-heading: ### Materialize recipe`
- **AND** exit non-zero

#### Scenario: Missing license declaration emits ERROR

- **WHEN** a `tier: pull-on-demand` cheatsheet's `### Source` block omits a license SPDX or canonical license URL
- **THEN** the validator SHALL emit ERROR identifying the missing field
- **AND** the cheatsheet SHALL NOT be considered valid

#### Scenario: pull_recipe frontmatter sentinel

- **WHEN** a `tier: pull-on-demand` cheatsheet's frontmatter contains `pull_recipe: see-section-pull-on-demand`
- **THEN** the validator SHALL accept the cross-reference
- **AND** any other value (e.g., a literal recipe in frontmatter) SHALL emit ERROR — recipes live in markdown, not YAML

---

### Pull-on-demand runtime cache topology

When an in-forge agent runs a `### Materialize recipe`, the materialized content MUST land under `~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>` (mirroring URL structure). This path SHALL be a subdirectory of the per-project cache mount governed by `forge-cache-dual` — project A SHALL NEVER see project B's pulled content.

The pull cache SHALL operate as a single LRU-managed pool with a tiered RAMDISK soft cap, auto-detected from `MemTotal` at tray startup:

| Host class | RAMDISK soft cap | Detection rule |
|---|---|---|
| Modest | 64 MB | `MemTotal < 8 GiB` |
| Normal | 128 MB | `8 GiB ≤ MemTotal < 32 GiB` |
| Plentiful | 1024 MB | `MemTotal ≥ 32 GiB` |

The cap SHALL be overridable via `forge.pull_cache_ram_mb` in `~/.config/tillandsias/config.toml`. Beyond the cap, content SHALL automatically spill to disk under the same path tree (the cap controls how much sits in tmpfs vs disk; agents see one unified path). LRU eviction SHALL operate within the per-project subtree only — never evicting content belonging to a different project (preserves the `forge-cache-dual` isolation invariant).

The agent's GENERATED summary cheatsheet SHALL land in `/opt/cheatsheets/` (the existing 8 MB tmpfs governed by `forge-hot-cold-split`) AND, if the agent decides to keep it across launches, in `<project>/.tillandsias/cheatsheets/<category>/<name>.md` on the project bind mount.

#### Scenario: Pulled content lands in per-project cache, not shared

- **WHEN** an in-forge agent attached to project `acme` runs the materialize recipe for `https://docs.oracle.com/en/java/javase/21/docs/api/`
- **THEN** the resulting bytes SHALL appear at `~/.cache/tillandsias/cheatsheets-pulled/acme/docs.oracle.com/en/java/javase/21/docs/api/`
- **AND** an agent attached to project `widget` SHALL NOT see those bytes — its own `cheatsheets-pulled/widget/` subtree is independent

#### Scenario: Modest host applies 64 MB RAMDISK cap

- **WHEN** the host's `MemTotal` reads as 6 GiB at tray startup
- **THEN** the pull cache RAMDISK cap SHALL be 64 MB
- **AND** the value SHALL be observable in the forge launch context as `forge.pull_cache_ram_mb = 64`

#### Scenario: Auto-spill to disk preserves single agent-visible path

- **WHEN** the in-forge agent pulls a 200 MB JDK doc archive and the RAMDISK cap is 128 MB
- **THEN** the first 128 MB SHALL land in tmpfs and the remainder SHALL spill to disk under the same `~/.cache/tillandsias/cheatsheets-pulled/<project>/...` path
- **AND** the agent SHALL access the content through the single path without distinguishing tmpfs vs disk

#### Scenario: LRU eviction respects per-project boundary

- **WHEN** the per-project pull cache fills and LRU eviction is required
- **THEN** only entries under that project's `cheatsheets-pulled/<project>/` subtree SHALL be candidates for eviction
- **AND** entries belonging to other projects SHALL NEVER be evicted by another project's pressure

---

### Distro-packaged tier — package validation

A `tier: distro-packaged` cheatsheet MUST declare `package: <name>` in its frontmatter, where `<name>` is the OS package providing the doc files. The cheatsheet SHALL also declare `local: <path>` pointing to the file inside the forge image (e.g., `/usr/share/javadoc/java-21-openjdk/api/index.html`). At validation time, `scripts/check-cheatsheet-sources.sh` SHALL confirm `<name>` is listed in the forge image's package manifest. The package manifest SHALL be discoverable via one of: `flake.nix` `contents` attribute, `images/default/Containerfile` `dnf install` lines, or a dedicated `images/default/distro-packages.txt` file (in that fallback order).

At runtime, the in-forge agent SHALL read the cheatsheet and follow the `local:` path directly — no fetch, no recipe, no proxy round-trip. The frontmatter `source_urls[]` records the upstream truth so structural-drift comparisons remain possible (host or in-forge agent SHALL be able to compare the package's local content against upstream).

#### Scenario: Validator confirms package presence in flake.nix

- **WHEN** a cheatsheet declares `tier: distro-packaged`, `package: java-21-openjdk-doc`
- **AND** `flake.nix`'s forge image `contents` attribute includes `java-21-openjdk-doc`
- **THEN** the validator SHALL accept the cheatsheet without ERROR

#### Scenario: Missing package emits ERROR + INDEX badge

- **WHEN** a `tier: distro-packaged` cheatsheet declares `package: nonexistent-pkg`
- **AND** the package is NOT in any of the discoverable manifests
- **THEN** the validator SHALL emit `ERROR: distro-packaged cheatsheet references missing package: nonexistent-pkg`
- **AND** the regenerated `INDEX.md` line SHALL show `[distro-packaged: MISSING]`

#### Scenario: Local path absent inside forge image

- **WHEN** `scripts/check-cheatsheet-sources.sh` runs in-image post-build
- **AND** a `tier: distro-packaged` cheatsheet's `local:` path does NOT exist on the image filesystem
- **THEN** the validator SHALL emit ERROR identifying the missing local path
- **AND** the cheatsheet's INDEX badge SHALL revert to `[distro-packaged: MISSING]`

---

### Structural-drift fingerprint

For `tier: bundled` cheatsheets, the build-time fetcher MUST compute a structural-drift fingerprint as `SHA256( join("\n", [h.text for h in <h1, h2, h3 elements>]) )` over the fetched HTML, and persist the first 16 hex chars to the cheatsheet's `structural_drift_fingerprint` frontmatter field. Word-level edits inside an unchanged outline SHALL NOT change the fingerprint. The implementation SHALL use `htmlq` if available, otherwise a self-contained Python heading extractor (no new heavyweight dependency).

For `tier: pull-on-demand` cheatsheets, the in-forge agent SHALL compute the same fingerprint after running the materialize recipe, and report it via the `cheatsheet-telemetry` channel as a `structural_drift` event. The host MAY compare fingerprints across forge launches to detect upstream restructures before the agent consults the cheatsheet again.

A fingerprint mismatch SHALL flag the cheatsheet for human review as a WARN — it SHALL NOT fail any build (semantic outline drift is informational, not a build error).

#### Scenario: Build computes and pins fingerprint for bundled cheatsheet

- **WHEN** `scripts/build-image.sh forge` runs the fetch-and-bake stage on a new bundled cheatsheet whose source has heading outline `H1: Foo, H2: Bar, H3: Baz`
- **THEN** the fingerprint SHALL be `SHA256("Foo\nBar\nBaz")[:16]`
- **AND** the value SHALL be written to the cheatsheet's `structural_drift_fingerprint` frontmatter field

#### Scenario: Word-level upstream edit does NOT trip fingerprint

- **WHEN** the upstream source is re-fetched and only paragraph text inside an unchanged outline has changed
- **THEN** the recomputed fingerprint SHALL match the persisted value
- **AND** no drift WARN is emitted

#### Scenario: Heading rename trips fingerprint, emits WARN

- **WHEN** the upstream re-fetched source's outline now reads `H1: Foo, H2: Bar (renamed from Quux), H3: Baz`
- **THEN** the recomputed fingerprint SHALL differ from the persisted value
- **AND** the build SHALL emit `WARN: structural drift in cheatsheets/<path>: outline changed`
- **AND** the build SHALL succeed (drift is human-triaged, not a build-blocker)

#### Scenario: Pull-on-demand fingerprint reported via telemetry

- **WHEN** the in-forge agent materializes a pull-on-demand source and computes its fingerprint
- **THEN** the agent SHALL emit a `cheatsheet-telemetry` event with `event = "structural_drift"`, `cheatsheet`, `fingerprint`, and `previous_fingerprint` (if known)

---

### CRDT override discipline for project-committed cheatsheets

When a project-committed cheatsheet at `<project>/.tillandsias/cheatsheets/<path>` shadows a forge-bundled cheatsheet at the same `<path>`, the project-committed file's frontmatter MUST contain four override fields: `shadows_forge_default: cheatsheets/<path>`, `override_reason: |`, `override_consequences: |`, and `override_fallback: |`. Each of `override_reason`, `override_consequences`, `override_fallback` SHALL be non-empty multi-line scalars. The validator SHALL emit ERROR if `shadows_forge_default` is set and any of the three other fields is missing or empty.

At forge launch, `populate_hot_paths()` (per `forge-hot-cold-split`) SHALL extend to merge `<project>/.tillandsias/cheatsheets/` into `/opt/cheatsheets/` (tmpfs view) AFTER the image-baked canonical, so project files override forge-shipped files at the same path. The merger SHALL emit one banner line per active shadow at forge launch:

```
[cheatsheet override] <path> → project version (reason: <first line of override_reason>)
```

At runtime, the agent reading a shadowed cheatsheet SHALL see the three override fields surfaced (e.g., as a frontmatter-derived header) BEFORE the cheatsheet body, so the override is reasoned, not silent.

A project-committed cheatsheet that does NOT shadow any forge default (a net-new cheatsheet for that project alone) SHALL NOT carry override fields — these fields are coupled to `shadows_forge_default` presence.

#### Scenario: Shadow with all four override fields is valid

- **WHEN** `<project>/.tillandsias/cheatsheets/languages/jdk-api.md` shadows `cheatsheets/languages/jdk-api.md`
- **AND** the project file's frontmatter contains all of `shadows_forge_default`, `override_reason`, `override_consequences`, `override_fallback` (each non-empty)
- **THEN** the validator SHALL accept the shadow
- **AND** `populate_hot_paths()` SHALL emit `[cheatsheet override] languages/jdk-api.md → project version (reason: ...)` at forge launch
- **AND** the agent reading `/opt/cheatsheets/languages/jdk-api.md` SHALL see the project version

#### Scenario: Shadow with missing override field is REJECTED

- **WHEN** a project-committed cheatsheet declares `shadows_forge_default: cheatsheets/languages/jdk-api.md` but omits `override_consequences:`
- **THEN** the validator SHALL emit `ERROR: shadow without override discipline: missing override_consequences`
- **AND** the validator SHALL exit non-zero (subject to the pre-commit hook's non-blocking surfacing)

#### Scenario: Net-new project cheatsheet does NOT require override fields

- **WHEN** `<project>/.tillandsias/cheatsheets/languages/proprietary-dsl.md` exists with no corresponding `cheatsheets/languages/proprietary-dsl.md` in the forge default
- **THEN** the cheatsheet's frontmatter SHALL omit `shadows_forge_default` and the three override fields
- **AND** the validator SHALL accept the cheatsheet
- **AND** the merger SHALL include it in `/opt/cheatsheets/` without emitting a shadow banner

#### Scenario: Override fields surfaced before cheatsheet body at runtime

- **WHEN** an agent reads a shadowed cheatsheet through `/opt/cheatsheets/<path>`
- **THEN** the rendered or baked content SHALL surface `override_reason`, `override_consequences`, `override_fallback` (e.g., as a header block) BEFORE the cheatsheet's `## Quick reference` section

---

### License-allowlist as a CRDT classifier

The repository MUST maintain `cheatsheets/license-allowlist.toml` (relocated from the legacy `cheatsheet-sources/license-allowlist.toml`). Each `[domains."<host>"]` entry SHALL declare: `publisher`, `license` (short identifier), `license_url`, `redistribution` (one of `bundled`, `attribute-only`, `do-not-bundle`), `default_tier` (one of `bundled`, `distro-packaged`, `pull-on-demand`), `last_evaluated` (ISO date), and `evaluated_by` (one of `hand-curated`, `agent-runtime-pull`, `host-refresh-script`).

The allowlist SHALL be treated as a CRDT: every pull-on-demand fetch by an in-forge agent SHALL re-evaluate the upstream's license declaration (the agent SHOULD `curl` the cited `license_url` and parse the SPDX or vendor-license identifier), and SHALL emit a `license_drift` event via `cheatsheet-telemetry` if the parsed declaration differs from the stored value. The host-side refresh script SHALL aggregate these events and surface drift for human triage; **the actual edit to the TOML stays manual through this change** (auto-merge of agent-proposed allowlist changes is deferred to v3).

When the validator infers a cheatsheet's tier from `source_urls[0]`'s host, it SHALL use the allowlist's `default_tier` for that host. A domain whose `default_tier` flips from `bundled` to `pull-on-demand` between releases SHALL trigger an automatic tier flip for all cheatsheets that previously inferred `bundled`, with a build-time WARN; the cheatsheet author confirms intent on the next refresh cycle.

#### Scenario: Allowlist provides default_tier for inference

- **WHEN** `cheatsheets/license-allowlist.toml` declares `[domains."docs.python.org"]` with `default_tier = "bundled"`
- **AND** a cheatsheet cites `https://docs.python.org/3/library/asyncio.html` as `source_urls[0]` and omits `tier:`
- **THEN** the inferred tier SHALL be `bundled`

#### Scenario: license_drift event emitted on agent re-evaluation

- **WHEN** an in-forge agent runs a pull-on-demand recipe for `docs.example.com` and parses the cited license URL
- **AND** the parsed license SPDX differs from the allowlist's stored `license` value
- **THEN** the agent SHALL emit a `cheatsheet-telemetry` event with `event = "license_drift"`, `domain`, `stored_license`, `observed_license`, `license_url`
- **AND** the allowlist TOML SHALL NOT be auto-edited — the host-side refresh script surfaces the drift for human triage

#### Scenario: default_tier flip propagates with WARN

- **WHEN** the allowlist's `default_tier` for `docs.example.com` changes from `bundled` to `pull-on-demand`
- **AND** an existing cheatsheet inferred `bundled` from that allowlist entry
- **THEN** the next `scripts/check-cheatsheet-sources.sh` run SHALL emit `WARN: tier auto-flipped to pull-on-demand for cheatsheets/<path> (allowlist change)`
- **AND** the cheatsheet's effective tier in the build SHALL be `pull-on-demand` until the author confirms or overrides

---

### cheatsheet-telemetry EXTERNAL log producer

A new EXTERNAL-tier producer role `cheatsheet-telemetry` MUST be defined per the `external-logs-layer` capability. The producer is the forge container itself; the manifest SHALL be baked at `images/default/external-logs.yaml` (a new file, parallel to `images/git/external-logs.yaml`). The manifest SHALL declare:

```yaml
role: cheatsheet-telemetry
files:
  - name: lookups.jsonl
    purpose: One event per cheatsheet consultation by an in-forge agent.
    format: jsonl
    rotate_at_mb: 10
    written_by: forge-agent (claude / opencode / opsx)
```

The forge container SHALL bind-mount `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/` RW at `/var/log/tillandsias/external/cheatsheet-telemetry/`. Each event SHALL be one JSON object per line with the schema:

| Field | Type | Notes |
|---|---|---|
| `ts` | ISO 8601 UTC | event timestamp |
| `project` | string | project name (from forge launch context) |
| `cheatsheet` | string | relative path under `cheatsheets/`, e.g. `languages/python.md` |
| `query` | string | free-form description of what the agent was looking for |
| `resolved_via` | enum | one of `bundled`, `distro-packaged`, `pulled`, `live-api`, `miss` |
| `pulled_url` | string | optional — set when `resolved_via = pulled` |
| `chars_consumed` | integer | optional — bytes of source the agent read |
| `event` | enum | optional — `lookup` (default), `structural_drift`, `license_drift` |
| `accountability` | bool | always `true` for telemetry events |
| `cheatsheet_field` | string | mirrors `cheatsheet` for cross-tier query parity |
| `spec` | string | always `cheatsheets-license-tiered` |

`resolved_via = miss` is the load-bearing case: it means the agent looked at the cheatsheet, did not find what it needed, and either pulled a deeper source or queried a live API. **v1 scope: emit only.** Host-side analytics (aggregating misses to drive refresh prioritization) is deferred to a follow-up change `cheatsheet-telemetry-analytics`.

#### Scenario: Manifest declared and bind-mount set up

- **WHEN** the forge container starts
- **THEN** `/etc/tillandsias/external-logs.yaml` (baked from `images/default/external-logs.yaml`) SHALL exist
- **AND** `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/` SHALL be bind-mounted RW at `/var/log/tillandsias/external/cheatsheet-telemetry/`
- **AND** the tray-side auditor (per `external-logs-layer`) SHALL recognize the new role within 60 seconds

#### Scenario: Lookup event emitted with full schema

- **WHEN** an in-forge agent reads `cheatsheets/languages/python.md` to answer a query about asyncio cancellation
- **THEN** one JSON line SHALL be appended to `/var/log/tillandsias/external/cheatsheet-telemetry/lookups.jsonl`
- **AND** the line SHALL contain `ts`, `project`, `cheatsheet = "languages/python.md"`, `query`, `resolved_via`, `accountability = true`, `spec = "cheatsheets-license-tiered"`

#### Scenario: Miss event names the gap

- **WHEN** the agent reads the cheatsheet but does not find what it needs and proceeds to pull a deeper source
- **THEN** an event SHALL be emitted with `resolved_via = "miss"`, `query` set to the gap description, and `pulled_url` set if a pull followed

#### Scenario: Manifest auditor LEAK alarm if forge writes outside manifest

- **WHEN** the forge container writes a file `lookups.jsonl.bak` to its EXTERNAL log directory
- **AND** that file is NOT in the manifest's `files[].name` set
- **THEN** the tray auditor SHALL emit `[external-logs] LEAK: cheatsheet-telemetry wrote lookups.jsonl.bak (not in manifest)` per the `external-logs-layer` invariant

---

### Tier-aware INDEX regeneration with badges

`scripts/regenerate-cheatsheet-index.sh` MUST emit one suffix per cheatsheet line in `cheatsheets/INDEX.md` based on tier and validation state:

| Tier and state | Suffix |
|---|---|
| `tier: bundled`, `image_baked_sha256` set | `[bundled, verified: <sha8>]` |
| `tier: bundled`, no fingerprint yet | `[bundled, partial-verify]` |
| `tier: distro-packaged`, package present in manifest | `[distro-packaged: <package>]` |
| `tier: distro-packaged`, package missing from manifest | `[distro-packaged: MISSING]` |
| `tier: pull-on-demand`, no project-commit | `[pull-on-demand: stub]` |
| `tier: pull-on-demand`, project-committed | `[pull-on-demand: project-committed]` |

Inside the forge, `populate_hot_paths()` SHALL re-run a stripped-down version of the index regeneration after merging project-committed cheatsheets and any pulled materializations, SO that `/opt/cheatsheets/INDEX.md` reflects the runtime-merged state. Pulled materializations under `~/.cache/tillandsias/cheatsheets-pulled/<project>/` SHALL appear in the runtime INDEX with a `[pulled]` badge.

#### Scenario: Bundled cheatsheet with pinned fingerprint shows verified badge

- **WHEN** `scripts/regenerate-cheatsheet-index.sh` runs and a cheatsheet has `tier: bundled` and `image_baked_sha256: d4760344...`
- **THEN** the INDEX line SHALL end with `[bundled, verified: d4760344]`

#### Scenario: Pull-on-demand stub badged at host build

- **WHEN** the host-side index regeneration encounters a `tier: pull-on-demand` cheatsheet with no project-commit
- **THEN** the INDEX line SHALL end with `[pull-on-demand: stub]`

#### Scenario: Runtime INDEX merges project-committed and pulled entries

- **WHEN** an in-forge agent has materialized `~/.cache/tillandsias/cheatsheets-pulled/acme/docs.oracle.com/...`
- **AND** has committed `<project>/.tillandsias/cheatsheets/languages/jdk-api.md`
- **THEN** the runtime `/opt/cheatsheets/INDEX.md` (after `populate_hot_paths()`) SHALL contain a line for the project-committed cheatsheet with `[pull-on-demand: project-committed]`
- **AND** SHALL contain a line for the pulled materialization with `[pulled]`

#### Scenario: Distro-packaged with missing package shows MISSING badge

- **WHEN** a `tier: distro-packaged` cheatsheet's `package:` is not in the discoverable forge image manifest
- **THEN** the INDEX line SHALL end with `[distro-packaged: MISSING]`
- **AND** the validator SHALL also emit ERROR (per the distro-packaged validation requirement)

---

### Cheatsheet lifecycle observability

Every transition in the cheatsheet lifecycle MUST emit a structured signal so that meaning converges across replicas (forge default, project override, agent-generated refinement) without requiring a central authority.

| Transition | Observable signal |
|---|---|
| AUTHORED → BUNDLED-BAKED | git commit history + frontmatter fields (`image_baked_sha256`, `structural_drift_fingerprint`) set by build |
| BUNDLED-BAKED → LOADED | `populate_hot_paths()` log line; INDEX badge update |
| LOADED → HIT | `cheatsheet-telemetry` event with `resolved_via` ∈ `{bundled, distro-packaged, pulled}` |
| LOADED → MISS | `cheatsheet-telemetry` event with `resolved_via = miss` and a `query` field |
| MISS → PULLED | `cheatsheet-telemetry` event with `resolved_via = pulled` and `pulled_url` set; license re-evaluation may emit `license_drift` |
| PULLED → REFINED | git commit under `<project>/.tillandsias/cheatsheets/`; cheatsheet frontmatter `summary_generated_by: agent-generated-at-runtime` |
| REFINED → PROMOTED | host-side `git mv` from `<project>/.tillandsias/cheatsheets/` to `cheatsheets/` (manual in v1; commit message convention `promote: <project> → <cheatsheet>`) |
| BUNDLED-BAKED → RE-VERIFIED | next `scripts/build-image.sh forge --refresh-sources` run; `last_verified` bumped; `image_baked_sha256` re-pinned; `structural_drift_fingerprint` diff emits WARN if changed |

The lifecycle SHALL be a CRDT, not a state machine: a single cheatsheet MAY simultaneously be LOADED in one forge instance, REFINED in another (different project), and being RE-VERIFIED on the host. Every transition is monotonic — information accumulates, never silently disappears.

#### Scenario: Build transition pins frontmatter fields

- **WHEN** `scripts/build-image.sh forge` runs and a bundled cheatsheet completes the BUNDLED-BAKED transition
- **THEN** the cheatsheet's frontmatter (or its `.cheatsheets-meta/<path>.frontmatter.json` side-channel) SHALL contain `image_baked_sha256` and `structural_drift_fingerprint`

#### Scenario: Runtime transitions emit telemetry events

- **WHEN** the in-forge agent walks LOADED → MISS → PULLED in a single session
- **THEN** at minimum two `cheatsheet-telemetry` events SHALL be appended to `lookups.jsonl` (one with `resolved_via = miss`, one with `resolved_via = pulled`)
- **AND** both events SHALL share the same `cheatsheet`, `project`, and a related `query` field

#### Scenario: REFINED transition is observable via project git history

- **WHEN** the in-forge agent writes `<project>/.tillandsias/cheatsheets/languages/jdk-api.md` and commits it
- **THEN** `git log <project>/.tillandsias/cheatsheets/` SHALL contain the commit
- **AND** the file's frontmatter SHALL declare `summary_generated_by: agent-generated-at-runtime`

#### Scenario: Replicas can converge via observable signals

- **WHEN** two forge instances on different hosts both pull the same upstream and emit `structural_drift` telemetry events with the SAME computed fingerprint
- **THEN** the host-side aggregation (in v2) SHALL recognize the converged observation as a confirmed structural state of the upstream
- **AND** v1 SHALL emit the events without consuming them — the data surface is created for v2 analytics

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-frontmatter-spec.md` — frontmatter v2 builds on this v1 schema; `tier`, `summary_generated_by`, `bundled_into_image`, `image_baked_sha256`, `structural_drift_fingerprint`, `pull_recipe`, `committed_for_project`, `shadows_forge_default`, override fields are additive extensions.
- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — the architectural rationale for cheatsheets as the active source of truth in the convergence loop.
- `cheatsheets/runtime/forge-hot-cold-split.md` — defines the `/opt/cheatsheets/` tmpfs view and the `populate_hot_paths()` contract that this change extends with project-committed merging.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — per-project ephemeral cache contract that pull-on-demand materializations respect.
- `cheatsheets/runtime/external-logs.md` — EXTERNAL-tier producer/consumer contract that the new `cheatsheet-telemetry` role implements.
- `cheatsheets/utils/jq.md` — JSON Lines processing for `lookups.jsonl` events; the schema is `jq -c`-friendly.
- `cheatsheets/build/nix-flake-basics.md` — `dockerTools.buildLayeredImage` `contents` path that lands `/opt/cheatsheet-sources/` in the image and discovers the package manifest for distro-packaged validation.
## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable

