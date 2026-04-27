# cheatsheet-source-layer Specification

## MODIFIED Requirements

### Requirement: Verbatim source storage

Verbatim source storage SHALL be tier-aware (per the `cheatsheets-license-tiered` capability). Only sources cited by `tier: bundled` cheatsheets SHALL be stored verbatim, and they SHALL live in the forge image at `/opt/cheatsheet-sources/<host>/<path>` (mirroring URL host structure), NOT in the host repository under `cheatsheet-sources/`. The host repository's `cheatsheet-sources/` directory SHALL be empty (gitignored) after this change; a single tombstone file (`cheatsheet-sources/.gitkeep-tombstone`) is committed for traceability through three releases.

For `tier: bundled` sources, the storage path is derived from the URL by the same mapping the legacy `scripts/fetch-cheatsheet-source.sh` already implements (host as the first directory component, path under it; GitHub blob URLs rewritten to raw form; IETF URLs prefer `.txt` over HTML). The build-time fetch-and-bake stage (per `cheatsheets-license-tiered`'s build-time fetch requirement) populates this path. Each bundled source SHALL carry a `.meta.yaml` sidecar baked alongside it (URL, content_sha256, fetched timestamp, license, fetcher_version).

For `tier: distro-packaged` sources, the OS package manager owns the bytes; no verbatim storage by Tillandsias is required. The cheatsheet's `local:` field points to the OS-installed path.

For `tier: pull-on-demand` sources, NO verbatim storage occurs at any time controlled by Tillandsias. The in-forge agent materializes content into `~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>` at runtime; this cache is per-project and ephemeral (governed by `forge-cache-dual`).

#### Scenario: bundled source stored at /opt/cheatsheet-sources/ inside the forge image

- **GIVEN** a `tier: bundled` cheatsheet cites `https://www.rfc-editor.org/rfc/rfc6265`
- **WHEN** `scripts/build-image.sh forge` runs the fetch-and-bake stage
- **THEN** the file lives at `/opt/cheatsheet-sources/www.rfc-editor.org/rfc/rfc6265` inside the resulting forge image
- **AND** the sidecar lives at `/opt/cheatsheet-sources/www.rfc-editor.org/rfc/rfc6265.meta.yaml`
- **AND** the sidecar's `content_sha256` matches the stored file
- **AND** NO bytes for that URL are committed to the host repository

#### Scenario: GitHub blob URL rewriting (preserved from legacy)

- **GIVEN** a `tier: bundled` cheatsheet cites `https://github.com/<owner>/<repo>/blob/<branch>/<path>`
- **WHEN** the build-time fetcher processes it
- **THEN** the URL is rewritten to `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`
- **AND** the in-image path uses the raw form (not the GitHub HTML wrapper)

#### Scenario: pull-on-demand cheatsheet has NO verbatim storage at any tier

- **GIVEN** a `tier: pull-on-demand` cheatsheet cites `https://docs.oracle.com/en/java/javase/21/docs/api/`
- **WHEN** `scripts/build-image.sh forge` runs
- **THEN** NO bytes for that URL appear under `/opt/cheatsheet-sources/` in the forge image
- **AND** NO bytes are written to the host repository
- **AND** the runtime materialization is the agent's responsibility via the cheatsheet's `## Pull on Demand` recipe

#### Scenario: distro-packaged tier defers storage to OS package

- **GIVEN** a `tier: distro-packaged` cheatsheet declares `package: java-21-openjdk-doc`
- **THEN** Tillandsias SHALL NOT fetch or store the package's content under `/opt/cheatsheet-sources/`
- **AND** the cheatsheet's `local:` path resolves to the OS-installed path inside the forge image (e.g., `/usr/share/javadoc/java-21-openjdk/api/index.html`)

#### Scenario: legacy host repo cheatsheet-sources/ is empty post-migration

- **WHEN** the migration to `cheatsheets-license-tiered` completes
- **THEN** the host repository's `cheatsheet-sources/` directory contains ONLY `.gitkeep-tombstone` (with a `@tombstone superseded:cheatsheets-license-tiered` header)
- **AND** all previously-committed verbatim files SHALL have been removed in the migration commit

### Requirement: License allowlist gates bundling

The license allowlist (relocated to `cheatsheets/license-allowlist.toml` from the legacy `cheatsheet-sources/license-allowlist.toml`) SHALL function as a tier-classifier: each `[domains."<host>"]` entry declares a `default_tier` that the validator uses when a cheatsheet's frontmatter omits an explicit `tier:`. The allowlist's pre-existing `redistribution` field (`bundled` | `attribute-only` | `do-not-bundle`) SHALL remain for human-readable license intent, but tier classification is the load-bearing field for build behavior.

A domain whose `default_tier = bundled` indicates Tillandsias asserts redistribution is permitted by that domain's license; cheatsheets citing such domains MAY bundle their sources at build time. A domain whose `default_tier = pull-on-demand` indicates Tillandsias asserts redistribution is NOT permitted (or is unclear); cheatsheets citing such domains SHALL NOT bundle and SHALL ship a `## Pull on Demand` stub instead. A domain whose `default_tier = distro-packaged` indicates the doc content is expected to be provided by an OS package shipped in the forge image.

The allowlist itself SHALL be treated as a CRDT (per the `cheatsheets-license-tiered` allowlist requirement): in-forge agent observations of license drift emit telemetry events; host-side TOML edits stay manual through this change.

#### Scenario: bundled-tier classification authorizes verbatim bundling

- **GIVEN** `cheatsheets/license-allowlist.toml` declares `[domains."developer.mozilla.org"]` with `default_tier = "bundled"` and `redistribution = "bundled"`
- **AND** a cheatsheet cites `https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies`
- **WHEN** the cheatsheet's frontmatter sets `tier: bundled` (or omits it; inferred from the allowlist)
- **THEN** the build-time fetch-and-bake stage SHALL fetch and bundle the source into `/opt/cheatsheet-sources/developer.mozilla.org/...`

#### Scenario: do-not-bundle classification blocks verbatim bundling

- **GIVEN** the allowlist declares `[domains."docs.oracle.com"]` with `default_tier = "pull-on-demand"` and `redistribution = "do-not-bundle"`
- **AND** a cheatsheet cites `https://docs.oracle.com/...`
- **WHEN** the cheatsheet's frontmatter sets `tier: bundled` (a forbidden override for a do-not-bundle domain)
- **THEN** the validator SHALL emit `ERROR: tier: bundled overrides do-not-bundle classification for docs.oracle.com`
- **AND** the build-time fetch-and-bake stage SHALL skip the URL

#### Scenario: allowlist relocated to cheatsheets/license-allowlist.toml

- **WHEN** the migration to `cheatsheets-license-tiered` completes
- **THEN** the file SHALL exist at `cheatsheets/license-allowlist.toml`
- **AND** the legacy path `cheatsheet-sources/license-allowlist.toml` SHALL be removed (under the `cheatsheet-sources/` tombstone sweep)
- **AND** all `[domains."..."]` entries SHALL gain `default_tier`, `last_evaluated`, `evaluated_by` fields per the CRDT classifier requirement

### Requirement: Provenance binding

Every cheatsheet's `## Provenance` section SHALL carry a `local:` sub-field next to each cited URL **if and only if** the cheatsheet's `tier:` is `bundled` or `distro-packaged`. For `tier: bundled`, the `local:` value SHALL point to `/opt/cheatsheet-sources/<host>/<path>` (the in-image path, set by the build-time fetch-and-bake stage). For `tier: distro-packaged`, the `local:` value SHALL point to the OS-installed path (e.g., `/usr/share/javadoc/...`). For `tier: pull-on-demand`, the URL line SHALL remain bare; the runtime materialization landing path is described under `## Pull on Demand` → `### Source` → `Cache target:`, NOT in `## Provenance`.

The `bind-provenance` step SHALL be folded into the build-time fetch-and-bake stage: the build (not a separate `scripts/bind-provenance-local-paths.sh` script) injects the in-image `local:` paths into the cheatsheet's `## Provenance` section (or its side-channel `.cheatsheets-meta/<path>.frontmatter.json`) so `populate_hot_paths()` reflects them at runtime.

#### Scenario: bundled local: points to /opt/cheatsheet-sources/ (in-image path)

- **GIVEN** a `tier: bundled` cheatsheet cites `https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies`
- **AND** the build-time fetch-and-bake stage has populated the source
- **THEN** the cheatsheet's `## Provenance` section (or its side-channel) SHALL contain, on the line immediately after the URL:
  ```
    local: `/opt/cheatsheet-sources/developer.mozilla.org/en-US/docs/Web/HTTP/Cookies`
  ```

#### Scenario: distro-packaged local: points to the OS-installed path

- **GIVEN** a `tier: distro-packaged` cheatsheet declares `package: java-21-openjdk-doc`
- **THEN** the `## Provenance` section SHALL contain:
  ```
    local: `/usr/share/javadoc/java-21-openjdk/api/index.html`
  ```
- **AND** the path SHALL exist inside the built forge image

#### Scenario: pull-on-demand URLs remain bare

- **GIVEN** a `tier: pull-on-demand` cheatsheet cites `https://docs.oracle.com/...`
- **THEN** the `## Provenance` URL line SHALL have NO `local:` field
- **AND** the materialization target SHALL be declared under `## Pull on Demand` → `### Source` → `Cache target:` instead

#### Scenario: build-time meta injection is idempotent

- **WHEN** `scripts/build-image.sh forge` runs the fetch-and-bake stage twice with no source URL changes
- **THEN** the second run SHALL detect the cache key match and SHALL NOT re-inject `local:` paths
- **AND** the resulting forge image SHALL be byte-identical for the cheatsheet meta side-channel

### Requirement: Validator invariants

`scripts/check-cheatsheet-sources.sh` SHALL enforce tier-aware checks. Check violations at ERROR level cause `exit 1` (in non-pre-commit invocation); WARN-level violations print but exit 0. The pre-commit hook continues to run with `--no-sha` and SHALL surface ERRORs as non-blocking warnings (CRDT-convergence philosophy).

| Tier | Check | Severity |
|---|---|---|
| `bundled` | post-build, `/opt/cheatsheet-sources/<host>/<path>` exists for every cited URL | ERROR |
| `bundled` | `image_baked_sha256` matches the file's actual SHA-256 | ERROR (without `--no-sha`) |
| `bundled` | `structural_drift_fingerprint` present | WARN if missing pre-first-build, ERROR otherwise |
| `bundled` | first-build of newly-added cheatsheet (no fingerprint yet) | WARN, not ERROR |
| `distro-packaged` | `package` is in the forge image's package manifest | ERROR |
| `distro-packaged` | `local:` path exists in the image (post-build) | ERROR |
| `pull-on-demand` | `## Pull on Demand` section present with `### Source`, `### Materialize recipe`, `### Generation guidelines` | ERROR if any sub-heading missing |
| `pull-on-demand` | `### Materialize recipe` is a non-empty fenced bash block | ERROR if empty |
| `pull-on-demand` | `pull_recipe: see-section-pull-on-demand` in frontmatter | ERROR if any other value |
| any | `tier:` declared OR inferable from allowlist | WARN if inferred (suggest making explicit) |
| project-shadow | `shadows_forge_default` set with all three override fields non-empty | ERROR if any override field missing or empty |

#### Scenario: ERROR — bundled cheatsheet missing in-image source

- **GIVEN** a `tier: bundled` cheatsheet cites a URL
- **AND** the post-build forge image has NO file at `/opt/cheatsheet-sources/<host>/<path>` for that URL
- **WHEN** `scripts/check-cheatsheet-sources.sh` runs against the image
- **THEN** it emits `ERROR: MISSING bundled source: <path>` and exits 1

#### Scenario: ERROR — pull-on-demand stub missing sub-heading

- **GIVEN** a `tier: pull-on-demand` cheatsheet's `## Pull on Demand` section omits `### Materialize recipe`
- **WHEN** `scripts/check-cheatsheet-sources.sh` runs
- **THEN** it emits `ERROR: pull-on-demand stub missing sub-heading: ### Materialize recipe`
- **AND** exits 1

#### Scenario: ERROR — distro-packaged references missing package

- **GIVEN** a `tier: distro-packaged` cheatsheet declares `package: nonexistent-pkg`
- **AND** no discoverable forge image manifest contains that package
- **WHEN** the validator runs
- **THEN** it emits `ERROR: distro-packaged cheatsheet references missing package: nonexistent-pkg`

#### Scenario: ERROR — project shadow without override discipline

- **GIVEN** a project-committed cheatsheet declares `shadows_forge_default: cheatsheets/languages/jdk-api.md` and omits `override_consequences:`
- **WHEN** the validator runs
- **THEN** it emits `ERROR: shadow without override discipline: missing override_consequences`

#### Scenario: WARN — bundled cheatsheet missing fingerprint pre-first-build

- **GIVEN** a newly-added `tier: bundled` cheatsheet whose frontmatter has no `image_baked_sha256` or `structural_drift_fingerprint` (the fields are set by the build, not the author)
- **WHEN** the validator runs against the source tree pre-build
- **THEN** it emits WARN, not ERROR, and exits 0

#### Scenario: pre-commit hook surfaces ERRORs as non-blocking warnings

- **WHEN** the developer commits a change
- **THEN** `scripts/hooks/pre-commit-openspec.sh` runs `check-cheatsheet-sources.sh --no-sha`
- **AND** any ERRORs are surfaced as non-blocking warnings in the hook output
- **AND** the commit proceeds regardless (CRDT-convergence philosophy)

### Requirement: Hot/cold separation

`/opt/cheatsheet-sources/` SHALL be permitted as image-baked content for the `tier: bundled` lane only — image-level redistribution (the bytes ride with the forge image) is allowed because the build-time bake gates on the license-allowlist's `default_tier = bundled` classification. The directory SHALL be a read-only image lower layer at runtime, NOT a tmpfs (RAM cost would be unjustified for bulk reference material) and NOT a host-mount (the bytes belong to the image, not to host state).

The cheatsheets themselves (the curated `.md` summaries at `/opt/cheatsheets/`) SHALL remain the tmpfs HOT lane per `forge-hot-cold-split` — only the *summaries* need lightning-fast access; their underlying bulk *sources* are fine on disk.

For `tier: pull-on-demand`, the per-project pull cache (`~/.cache/tillandsias/cheatsheets-pulled/<project>/`) SHALL respect the `forge-cache-dual` per-project boundary — never bind-mounted across projects, never shared. The tiered RAMDISK soft cap (per the `cheatsheets-license-tiered` runtime cache topology) governs how much of the pull cache sits in tmpfs vs disk; auto-spill to disk preserves the single agent-visible path.

#### Scenario: /opt/cheatsheet-sources/ baked into image, RO at runtime

- **WHEN** the forge image is built via `scripts/build-image.sh forge` with bundled cheatsheets
- **THEN** the image SHALL contain `/opt/cheatsheet-sources/<host>/<path>` for every bundled URL
- **AND** at runtime, `findmnt /opt/cheatsheet-sources -no FSTYPE` SHALL NOT return `tmpfs` (it is overlayfs lower layer, RO)
- **AND** the forge user (UID 1000) SHALL be unable to write to it (EACCES)

#### Scenario: agents read bundled sources without proxy round-trip

- **WHEN** an in-forge agent reads `/opt/cheatsheet-sources/<host>/<path>` for a bundled source
- **THEN** the read SHALL succeed locally with no network call
- **AND** no proxy hit SHALL appear in `~/.local/state/tillandsias/external-logs/proxy/` for that read

#### Scenario: pull cache respects per-project boundary

- **WHEN** an in-forge agent attached to project `acme` materializes a pull-on-demand source
- **THEN** the bytes SHALL land under `~/.cache/tillandsias/cheatsheets-pulled/acme/...` only
- **AND** an agent attached to project `widget` SHALL NOT see those bytes (per `forge-cache-dual`)

#### Scenario: legacy host-mount opt-in is removed

- **WHEN** the migration to `cheatsheets-license-tiered` completes
- **THEN** the legacy `forge.mount_source_layer = true` config option SHALL be removed (the bind-mount path is superseded by image-baked + per-project pull cache)
- **AND** any project config that still sets the option SHALL be ignored with a WARN log line

## REMOVED Requirements

### Requirement: Refresh behaviour

**Reason**: The standalone `scripts/refresh-cheatsheet-sources.sh` workflow is superseded by two independent flows in `cheatsheets-license-tiered`: (a) build-time fetch-and-bake with cache-key + `--max-age-days` invalidation for the `bundled` tier, and (b) agent-driven materialization via the `## Pull on Demand` recipe for the `pull-on-demand` tier. Drift detection moves to the structural-drift fingerprint emitted at build (bundled) or via `cheatsheet-telemetry` events (pull-on-demand). Sidecar `staleness` field semantics (`drift`, `gone`) are no longer load-bearing because (a) bundled sources are re-baked from scratch on cache-key invalidation, and (b) pull-on-demand sources are ephemeral per-project caches that get re-pulled on demand.

**Migration**: Local builds SHALL run `scripts/build-image.sh forge` (cache-or-fetch, default 30-day max age); CI SHALL pass `--max-age-days 7`. Explicit `--refresh-sources` forces re-fetch. The legacy `scripts/refresh-cheatsheet-sources.sh` SHALL be tombstoned (`@tombstone obsolete:cheatsheet-source-layer — kept for traceability through 0.1.<N+3>.x`) for three releases before final deletion. Sidecar `staleness` field is dropped — drift signal moves to `structural_drift_fingerprint` mismatches (build-time WARN) and `cheatsheet-telemetry` events (`event = "structural_drift"`, `event = "license_drift"`).

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — the architectural rationale for tiered source storage (forge image as the bundled-tier redistribution boundary).
- `cheatsheets/runtime/forge-hot-cold-split.md` — `/opt/cheatsheets/` is HOT (tmpfs), `/opt/cheatsheet-sources/` is COLD (image lower layer).
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — per-project pull cache lives on the project bind mount; `forge-cache-dual` per-project isolation invariant.
- `cheatsheets/build/nix-flake-basics.md` — `dockerTools.buildLayeredImage` `contents` path that lands `/opt/cheatsheet-sources/` and the package manifest discovery for distro-packaged validation.
