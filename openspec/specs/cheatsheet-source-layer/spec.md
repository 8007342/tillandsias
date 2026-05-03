# cheatsheet-source-layer Specification

## Status

status: active

## Purpose
TBD - created by archiving change cheatsheet-source-layer. Update Purpose after archive.
## Requirements
### Requirement: Verbatim source storage

Every cited URL SHALL have a deterministic on-disk path derived from the URL.
The stored content SHALL be content-hashed (SHA-256) and accompanied by a
per-file YAML sidecar (`.meta.yaml`) and an entry in the central
`cheatsheet-sources/INDEX.json`.

#### Scenario: URL to path mapping
- **GIVEN** a URL `https://www.rfc-editor.org/rfc/rfc6265`
- **WHEN** the fetcher stores it
- **THEN** the file lives at `cheatsheet-sources/www.rfc-editor.org/rfc/rfc6265`
- **AND** the sidecar lives at `cheatsheet-sources/www.rfc-editor.org/rfc/rfc6265.meta.yaml`
- **AND** the `content_sha256` field in the sidecar matches the stored file

#### Scenario: GitHub blob URL rewriting
- **GIVEN** a URL `https://github.com/<owner>/<repo>/blob/<branch>/<path>`
- **WHEN** the fetcher processes it
- **THEN** it rewrites to `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`
- **AND** the on-disk path uses the raw form (not the GitHub HTML wrapper)

#### Scenario: INDEX.json is the union of all sidecars
- **WHEN** `scripts/regenerate-source-index.sh` runs
- **THEN** `cheatsheet-sources/INDEX.json` contains one entry per `.meta.yaml` sidecar
- **AND** `scripts/regenerate-source-index.sh --check` exits non-zero if INDEX.json is stale

#### Scenario: Stored format precedence
- **WHEN** the fetcher retrieves content from an IETF URL
- **THEN** it prefers `.txt` (RFC canonical form) over HTML
- **WHEN** the fetcher retrieves from any other URL
- **THEN** it prefers single-page HTML, then Markdown (raw GitHub), then PDF

#### Scenario: Sidecar YAML schema
- **WHEN** a source is fetched
- **THEN** the sidecar MUST contain: `url`, `fetched` (ISO 8601 UTC), `fetcher_version`,
  `content_sha256`, `content_length`, `content_type`, `http_status`, `final_redirect`,
  `publisher`, `license`, `redistribution`, `allowlist_match`, `render`, `cited_by`, `notes`

### Requirement: License allowlist gates bundling

Only sources from allowlisted domains SHALL be committed verbatim to the
repository. Off-allowlist sources get a `.norepublish`-suffixed filename and
are gitignored; the sidecar IS committed so CI can validate structure without
requiring redistribution of content we may not have rights to bundle.

#### Scenario: Allowlisted source is committed
- **GIVEN** a URL from `developer.mozilla.org` (allowlisted, `cc-by-sa-2.5`)
- **WHEN** the fetcher stores it
- **THEN** the verbatim file is committed (redistribution: `bundled`)
- **AND** the sidecar's `redistribution` field is `bundled`

#### Scenario: Off-allowlist source is NOT committed
- **GIVEN** a URL from `docs.oracle.com` (not on the allowlist)
- **WHEN** the fetcher stores it with `--manual-review`
- **THEN** the verbatim file is stored with `.norepublish` suffix
- **AND** the `.norepublish` file is gitignored
- **AND** the sidecar (without `.norepublish`) is committed
- **AND** the sidecar's `redistribution` field is `do-not-bundle`

#### Scenario: allowlist is `license-allowlist.toml`
- **WHEN** a maintainer adds a new domain to the allowlist
- **THEN** they edit `cheatsheet-sources/license-allowlist.toml` with publisher,
  license SPDX identifier, and redistribution (`bundled` | `attribute-only` | `do-not-bundle`)
- **AND** the fetcher respects the updated allowlist on next run

### Requirement: Provenance binding

Every cheatsheet's `## Provenance` section SHALL carry a `local:` field next
to each cited URL that has been fetched, pointing to the verbatim on-disk file.
This allows maintainers to `cat cheatsheet-sources/...` to re-verify offline.

#### Scenario: local: field format
- **GIVEN** a cheatsheet that cites `https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies`
- **WHEN** that URL has been fetched and stored locally
- **THEN** the cheatsheet's `## Provenance` section SHALL contain, on the line
  immediately after the URL, exactly:
  ```
    local: `cheatsheet-sources/developer.mozilla.org/en-US/docs/Web/HTTP/Cookies`
  ```

#### Scenario: Off-allowlist URLs remain bare (no local:)
- **GIVEN** a cheatsheet that cites an off-allowlist URL (e.g., `https://docs.oracle.com/...`)
- **WHEN** no verbatim file has been committed (do-not-bundle)
- **THEN** the Provenance URL line has NO `local:` field
- **AND** the sidecar (`.meta.yaml`) still exists in `cheatsheet-sources/`

#### Scenario: bind-provenance-local-paths.sh is idempotent
- **WHEN** `scripts/bind-provenance-local-paths.sh` is run twice
- **THEN** the second run makes no modifications (detects existing `local:` fields)

#### Scenario: last_verified bumped on rewrite
- **WHEN** `scripts/bind-provenance-local-paths.sh` injects `local:` lines into a cheatsheet
- **AND** the cheatsheet's frontmatter `last_verified` date is older than the fetch date
- **THEN** `last_verified` is bumped to the fetch date

### Requirement: Validator invariants

`scripts/check-cheatsheet-sources.sh` SHALL enforce four checks. Check violations
at ERROR level cause `exit 1`. WARN-level violations print but exit 0.

#### Scenario: ERROR — missing INDEX.json entry for cited URL
- **GIVEN** a cheatsheet that cites a URL in `## Provenance`
- **AND** that URL is not in `cheatsheet-sources/INDEX.json` (not fetched)
- **WHEN** `scripts/check-cheatsheet-sources.sh` runs
- **THEN** it emits a `WARN: UNFETCHED: ...` line (non-blocking during migration)

#### Scenario: ERROR — local: path points to missing file
- **GIVEN** a cheatsheet's Provenance section contains `local: \`cheatsheet-sources/...\``
- **AND** neither the verbatim file NOR its `.meta.yaml` sidecar exists
- **WHEN** `scripts/check-cheatsheet-sources.sh` runs
- **THEN** it emits `ERROR: MISSING: ...` and exits 1

#### Scenario: WARN — orphan INDEX entry
- **GIVEN** an entry in `cheatsheet-sources/INDEX.json` with an empty `cited_by: []`
- **AND** no cheatsheet has a `local:` path referencing it
- **WHEN** `scripts/check-cheatsheet-sources.sh` runs
- **THEN** it emits `WARN: ORPHAN: ...` (non-blocking)

#### Scenario: ERROR — SHA mismatch
- **GIVEN** a verbatim file has been modified since it was fetched
- **WHEN** `scripts/check-cheatsheet-sources.sh` runs (without `--no-sha`)
- **THEN** it emits `ERROR: SHA MISMATCH: ...` and exits 1

#### Scenario: pre-commit integration
- **WHEN** the developer commits a change
- **THEN** `scripts/hooks/pre-commit-openspec.sh` runs `check-cheatsheet-sources.sh --no-sha`
- **AND** any ERRORS are surfaced as non-blocking warnings in the hook output
- **AND** the commit proceeds regardless (CRDT-convergence philosophy)

### Requirement: Hot/cold separation

`cheatsheet-sources/` SHALL be COLD storage — host disk only. It MUST NOT be
baked into any container image and MUST NOT be bind-mounted into forge
containers by default. Agents inside the forge see only `[verified: <sha8>]`
markers in `INDEX.md`, never the verbatim source bytes.

#### Scenario: cheatsheet-sources is not included in forge image
- **WHEN** the forge image is built (`scripts/build-image.sh forge`)
- **THEN** `cheatsheet-sources/` is NOT copied into the image
- **AND** `/opt/cheatsheet-sources/` does NOT exist inside the forge container

#### Scenario: agents see verified markers, not bytes
- **WHEN** an agent reads `$TILLANDSIAS_CHEATSHEETS/INDEX.md` inside the forge
- **THEN** it sees `[verified: <sha8>]` markers on cheatsheet lines (from INDEX.md)
- **AND** it does NOT have access to the verbatim source bytes by default

#### Scenario: maintainer opt-in mount (future)
- **GIVEN** `forge.mount_source_layer = true` in the project config
- **WHEN** a forge container starts
- **THEN** `cheatsheet-sources/` is bind-mounted read-only at `/opt/cheatsheet-sources/`
- **AND** the mount is logged via the `accountability` channel

### Requirement: Refresh behaviour

`scripts/refresh-cheatsheet-sources.sh` SHALL re-fetch stored sources and
surface drift (SHA mismatch) or removal (HTTP 404) by updating the sidecar's
`staleness` field. It MUST never delete the last known good bytes — drift is
human-triaged, not auto-resolved.

#### Scenario: Drift detection on re-fetch
- **WHEN** `scripts/refresh-cheatsheet-sources.sh` runs and re-fetches a URL
- **AND** the new content's SHA-256 differs from the stored SHA-256
- **THEN** the sidecar's `staleness` field is set to `drift`
- **AND** the maintainer is shown both SHAs for comparison

#### Scenario: 404 on re-fetch
- **WHEN** `scripts/refresh-cheatsheet-sources.sh` encounters an HTTP 404
- **THEN** the sidecar's `staleness` field is set to `gone`
- **AND** the last known good bytes remain on disk (not deleted)

#### Scenario: --max-age-days filters refreshes
- **WHEN** `scripts/refresh-cheatsheet-sources.sh --max-age-days 90` runs
- **THEN** only sources with `fetched` date older than 90 days are re-fetched


## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:cheatsheet-source-layer" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
