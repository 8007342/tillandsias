# agent-cheatsheets Specification

## MODIFIED Requirements

### Requirement: Cheatsheet template

Every cheatsheet SHALL follow a fixed template with these sections in this order: YAML frontmatter (v2 schema, see below), title heading, `@trace spec:agent-cheatsheets` annotation, optional DRAFT banner, `**Version baseline**:` line, `**Use when**:` line, `## Provenance` section (mandatory), `## Quick reference`, `## Common patterns`, `## Common pitfalls`, `## See also`. For `tier: pull-on-demand` cheatsheets, a final `## Pull on Demand` section SHALL follow `## See also`. Sections may be empty but the headings SHALL be present (except `## Provenance` which SHALL be populated to commit, and `## Pull on Demand` which is mandatory for the pull-on-demand tier).

The YAML frontmatter SHALL conform to the v2 schema. The schema's `tier` field is one of `bundled`, `distro-packaged`, `pull-on-demand`. Tier-conditional fields (per the `cheatsheets-license-tiered` capability):

| Field | Required for | Forbidden for |
|---|---|---|
| `tier` | all tiers | — |
| `source_urls[]` | all tiers (≥ 1 entry) | — |
| `last_verified` | all tiers | — |
| `summary_generated_by` | all tiers (enum: `hand-curated`, `agent-generated-at-build`, `agent-generated-at-runtime`) | — |
| `bundled_into_image` | all tiers (`true` for bundled+distro, `false` for pull-on-demand) | — |
| `local` | bundled, distro-packaged | pull-on-demand (set at runtime in pulled cache, not at author time) |
| `package` | distro-packaged | bundled, pull-on-demand |
| `image_baked_sha256` | bundled (set by build) | distro-packaged, pull-on-demand |
| `structural_drift_fingerprint` | bundled (set by build) | — (optional elsewhere) |
| `pull_recipe` | pull-on-demand (sentinel: `see-section-pull-on-demand`) | bundled, distro-packaged |
| `committed_for_project` | optional, all tiers (`true` iff under `<project>/.tillandsias/cheatsheets/`) | — |
| `shadows_forge_default` | only project-committed cheatsheets that shadow a forge default | — |
| `override_reason`, `override_consequences`, `override_fallback` | required iff `shadows_forge_default` is set; each is a non-empty multi-line scalar | — |

The pre-existing `## Provenance` markdown section SHALL agree with the frontmatter at validate time (URLs match, license names match) — the markdown is the eyeball contract; the frontmatter is the machine contract.

#### Scenario: Template enforcement

- **WHEN** a contributor or sub-agent writes a new cheatsheet
- **THEN** all required sections are present in the file
- **AND** the `@trace spec:agent-cheatsheets` line appears within the first five lines AFTER the YAML frontmatter
- **AND** the `## Provenance` section contains at least one URL and a `**Last updated:**` line
- **AND** the YAML frontmatter declares `tier:` (or omits it for inference)

#### Scenario: Length budget

- **WHEN** a cheatsheet is committed
- **THEN** its line count is ≤ 200 lines (a soft cap; longer cheatsheets SHOULD be split into multiple topic-scoped files instead)
- **AND** for `tier: pull-on-demand` cheatsheets, the `## Pull on Demand` section is excluded from the soft cap

#### Scenario: Tier-conditional fields enforced

- **WHEN** a `tier: bundled` cheatsheet is committed without a `local:` field
- **THEN** the validator emits ERROR identifying the missing required field
- **WHEN** a `tier: pull-on-demand` cheatsheet contains `local:` or `image_baked_sha256:` set by the author
- **THEN** the validator emits ERROR identifying the forbidden field

#### Scenario: Pull-on-demand cheatsheet has the mandatory section

- **WHEN** a `tier: pull-on-demand` cheatsheet is committed
- **THEN** the file SHALL contain a `## Pull on Demand` section after `## See also`
- **AND** the section SHALL contain `### Source`, `### Materialize recipe`, and `### Generation guidelines` sub-headings

### Requirement: Provenance section — `local:` field per cited URL

Every URL citation in a cheatsheet's `## Provenance` section SHALL be accompanied by a `local:` sub-field on the line immediately after the URL **if and only if** the cheatsheet's `tier:` is `bundled` or `distro-packaged`. For `tier: pull-on-demand`, the URL line SHALL remain bare (no `local:` field at author time) — the runtime materialization landing path is described in the cheatsheet's `## Pull on Demand` → `### Source` → `Cache target:` line, NOT in `## Provenance`.

For `tier: bundled`, the `local:` value SHALL point to the in-image path under `/opt/cheatsheet-sources/<host>/<path>` (set at build time). For `tier: distro-packaged`, the `local:` value SHALL point to the OS-installed path provided by the package (e.g., `/usr/share/javadoc/java-21-openjdk/api/index.html`).

#### Scenario: bundled tier — local: field present after build

- **GIVEN** a `tier: bundled` cheatsheet cites `https://doc.rust-lang.org/book/` in `## Provenance`
- **AND** the build-time fetch-and-bake stage has populated `/opt/cheatsheet-sources/doc.rust-lang.org/book`
- **THEN** the Provenance entry looks like:
  ```
  - The Rust Programming Language (official): <https://doc.rust-lang.org/book/>
    local: `/opt/cheatsheet-sources/doc.rust-lang.org/book`
  ```

#### Scenario: distro-packaged tier — local: points to OS path

- **GIVEN** a `tier: distro-packaged` cheatsheet declares `package: java-21-openjdk-doc`
- **THEN** the Provenance entry includes:
  ```
  - JDK 21 API (official): <https://docs.oracle.com/en/java/javase/21/docs/api/>
    local: `/usr/share/javadoc/java-21-openjdk/api/index.html`
  ```
- **AND** the `local:` path SHALL exist inside the built forge image

#### Scenario: pull-on-demand tier — bare URL, no local:

- **GIVEN** a `tier: pull-on-demand` cheatsheet cites `https://docs.oracle.com/en/java/javase/21/docs/api/` in `## Provenance`
- **THEN** the Provenance entry has NO `local:` field at author time
- **AND** the cheatsheet's `## Pull on Demand` → `### Source` block declares `Cache target: ~/.cache/tillandsias/cheatsheets-pulled/<project>/docs.oracle.com/...`

#### Scenario: INDEX.md shows tier-aware verify state

- **GIVEN** a `tier: bundled` cheatsheet whose build pinned `image_baked_sha256: d4760344...`
- **WHEN** `scripts/regenerate-cheatsheet-index.sh` runs
- **THEN** the cheatsheet's line in `cheatsheets/INDEX.md` ends with `[bundled, verified: d4760344]`
- **GIVEN** a `tier: pull-on-demand` cheatsheet
- **THEN** the line ends with `[pull-on-demand: stub]` (or `[pull-on-demand: project-committed]` for runtime-merged entries)

## ADDED Requirements

### Requirement: Project-committed cheatsheet override discipline

The cheatsheet authoring contract SHALL admit a project-committed layer at `<project>/.tillandsias/cheatsheets/<category>/<name>.md`. Project-committed cheatsheets SHALL follow the same template and frontmatter v2 schema as forge-default cheatsheets. When a project-committed cheatsheet's relative path matches a forge-default cheatsheet's relative path, the project-committed file SHALL declare `shadows_forge_default: cheatsheets/<path>` in its frontmatter AND SHALL declare three non-empty override fields: `override_reason`, `override_consequences`, `override_fallback`. The validator SHALL emit ERROR if `shadows_forge_default` is set and any of the three fields is missing or empty.

A net-new project cheatsheet (no shadow) SHALL omit `shadows_forge_default` and the three override fields. The agent MAY annotate net-new cheatsheets that would benefit other projects with the comment `<!-- promotion-candidate: this cheatsheet is forge-agnostic and could be promoted to cheatsheets/ -->`. Promotion is intentionally manual: the host user (or a host-side script) `git mv`s the file from `<project>/.tillandsias/cheatsheets/` to `cheatsheets/` to promote it.

#### Scenario: Project shadow with full override discipline

- **WHEN** `<project>/.tillandsias/cheatsheets/languages/jdk-api.md` exists alongside the forge default `cheatsheets/languages/jdk-api.md`
- **AND** the project file's frontmatter contains `shadows_forge_default: cheatsheets/languages/jdk-api.md` plus non-empty `override_reason`, `override_consequences`, `override_fallback`
- **THEN** the validator SHALL accept the file
- **AND** the project version SHALL win at runtime (per the `cheatsheets-license-tiered` merging rule)

#### Scenario: Project shadow without override fields is REJECTED

- **WHEN** a project-committed cheatsheet declares `shadows_forge_default: cheatsheets/languages/jdk-api.md` but omits `override_fallback:`
- **THEN** the validator SHALL emit `ERROR: shadow without override discipline: missing override_fallback`
- **AND** the validator SHALL exit non-zero (subject to the pre-commit hook's non-blocking surfacing)

#### Scenario: Net-new project cheatsheet — no override fields needed

- **WHEN** `<project>/.tillandsias/cheatsheets/languages/proprietary-dsl.md` exists with no corresponding forge-default cheatsheet at the same path
- **THEN** the cheatsheet's frontmatter SHALL omit `shadows_forge_default` and the three override fields
- **AND** the cheatsheet MAY include the `<!-- promotion-candidate: ... -->` comment if forge-agnostic

#### Scenario: Promotion via git mv

- **WHEN** the host user runs `git mv <project>/.tillandsias/cheatsheets/languages/proprietary-dsl.md cheatsheets/languages/proprietary-dsl.md` and commits with message starting `promote: <project> →`
- **THEN** the file SHALL appear under the forge-default `cheatsheets/` tree
- **AND** the promoted file SHALL drop `committed_for_project: true` from its frontmatter (now a forge default, no longer a project artifact)

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-frontmatter-spec.md` — v1 schema this delta extends with the v2 tier and override fields.
- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — architectural rationale for cheatsheets as a CRDT across the forge default + project override + agent-generated layers.
- `cheatsheets/runtime/forge-hot-cold-split.md` — `populate_hot_paths()` contract extended to merge project-committed cheatsheets.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — `<project>/.tillandsias/cheatsheets/` is on the project bind mount (persistent across container restarts within the same project).
