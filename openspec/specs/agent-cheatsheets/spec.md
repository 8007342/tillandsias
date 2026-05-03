# agent-cheatsheets Specification

## Status

status: active

## Purpose
TBD - created by archiving change agent-source-of-truth. Update Purpose after archive.
## Requirements
### Requirement: Cheatsheets directory structure

The repository SHALL contain a top-level `cheatsheets/` directory organized into seven subdirectories: `runtime/`, `languages/`, `utils/`, `build/`, `web/`, `test/`, and `agents/`. Each subdirectory contains one cheatsheet per topic, named `<topic>.md` (lowercase, hyphenated).

#### Scenario: Subdirectory layout
- **WHEN** a contributor adds a new cheatsheet
- **THEN** they place it in the subdirectory that matches its primary use (`languages/python.md`, NOT `python/syntax.md`)

#### Scenario: Naming convention
- **WHEN** a cheatsheet covers a tool with a hyphenated name (e.g., `cargo-test`)
- **THEN** the filename uses the same hyphenation: `test/cargo-test.md`

### Requirement: Cheatsheet template

Every cheatsheet SHALL follow a fixed template with these sections in this order: title heading, `@trace spec:agent-cheatsheets` annotation, optional DRAFT banner, `**Version baseline**:` line, `**Use when**:` line, `## Provenance` section (mandatory), `## Quick reference`, `## Common patterns`, `## Common pitfalls`, `## See also`. Sections may be empty but the headings SHALL be present (except `## Provenance` which SHALL be populated to commit).

#### Scenario: Template enforcement
- **WHEN** a contributor or sub-agent writes a new cheatsheet
- **THEN** all required sections are present in the file
- **AND** the `@trace spec:agent-cheatsheets` line appears within the first five lines
- **AND** the `## Provenance` section contains at least one URL and a `**Last updated:**` line

#### Scenario: Length budget
- **WHEN** a cheatsheet is committed
- **THEN** its line count is ≤ 200 lines (a soft cap; longer cheatsheets SHOULD be split into multiple topic-scoped files instead)

### Requirement: INDEX.md is grep-friendly

The cheatsheets directory SHALL contain `cheatsheets/INDEX.md` listing every cheatsheet, grouped by category (one `## <category>` heading per subdirectory). Each entry is a single line of the form `- <filename>.md  — <one-line description>` (≤ 100 characters per line).

#### Scenario: INDEX format invariant
- **WHEN** an agent runs `cat /opt/cheatsheets/INDEX.md | rg '<topic>'`
- **THEN** the result is one line per matching cheatsheet, suitable for direct piping to `cut -d' ' -f2` to extract the filename

#### Scenario: Every cheatsheet is indexed
- **WHEN** `cheatsheets/<category>/<filename>.md` exists in the repository
- **THEN** `cheatsheets/INDEX.md` contains a corresponding line under the matching `## <category>` heading

### Requirement: Forge image bakes cheatsheets

The forge image SHALL maintain TWO views of the cheatsheets — an image-baked
canonical at `/opt/cheatsheets-image/` and a runtime tmpfs view at
`/opt/cheatsheets/` (8 MB cap). The agent-facing env var
`TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` is unchanged — agents observe no
behavioral difference.

> Delta: the single `/opt/cheatsheets` bake is replaced by a two-layer model.
> The image-build COPY lands at `/opt/cheatsheets-image/` (immutable lower layer).
> At container start, `populate_hot_paths()` copies the canonical content into
> `/opt/cheatsheets/` (runtime tmpfs, 8 MB cap).

| View | Path | Backing store | Populated by |
|------|------|---------------|--------------|
| Image-baked canonical | `/opt/cheatsheets-image/` | Image overlayfs lower layer (disk) | `COPY cheatsheets/ /opt/cheatsheets-image/` at build time |
| Runtime tmpfs view | `/opt/cheatsheets/` | Kernel tmpfs (RAM), 8 MB cap | `populate_hot_paths()` in every forge entrypoint |

#### Scenario: /opt/cheatsheets/ is the tmpfs view; /opt/cheatsheets-image/ is the immutable lower-layer copy

- **WHEN** a forge container starts and `populate_hot_paths()` completes
- **THEN** `findmnt /opt/cheatsheets -no FSTYPE` returns `tmpfs`
- **AND** `diff -r /opt/cheatsheets-image /opt/cheatsheets` returns exit 0
  (content is identical; the tmpfs is a complete copy of the image-baked layer)
- **AND** `/opt/cheatsheets-image/` is NOT a tmpfs — it is read-only overlayfs
  (image state)

#### Scenario: Environment variable is set to the tmpfs view (unchanged)

- **WHEN** an agent runs `echo $TILLANDSIAS_CHEATSHEETS` inside the forge
- **THEN** the output is `/opt/cheatsheets` — the RAM-backed view
- **AND** no agent code or cheatsheet reference requires updating

#### Scenario: Agent writes to /opt/cheatsheets are lost on container stop

- **WHEN** an agent writes to `/opt/cheatsheets/` (tmpfs is rw by default inside
  the container, though the 8 MB cap limits abuse)
- **THEN** the write is NOT visible in `/opt/cheatsheets-image/` and NOT
  persisted after container stop (tmpfs is ephemeral)
- **AND** the next forge container starts fresh from the image-baked canonical

### Requirement: RUNTIME_LIMITATIONS feedback channel

When an agent inside the forge encounters a missing tool, capability, or runtime constraint that prevented its task, it SHALL write a report to `<project>/.tillandsias/runtime-limitations/RUNTIME_LIMITATIONS_<NNN>.md` where `<NNN>` is the next sequential 3-digit number (zero-padded). The report SHALL include YAML front-matter with `report_id`, `tool`, `attempted`, `suggested_install`, and `discovered_at` fields, followed by a free-form body describing the gap.

#### Scenario: Sequential numbering
- **WHEN** an agent writes a new RUNTIME_LIMITATIONS report and the directory already contains `RUNTIME_LIMITATIONS_001.md` and `RUNTIME_LIMITATIONS_002.md`
- **THEN** the new file SHALL be `RUNTIME_LIMITATIONS_003.md`

#### Scenario: Front-matter is parseable
- **WHEN** a host-side script reads `<project>/.tillandsias/runtime-limitations/*.md`
- **THEN** each file's YAML front-matter contains the five required fields and the body is non-empty

#### Scenario: Reports survive forge stop via mirror sync
- **WHEN** the forge container stops after writing a RUNTIME_LIMITATIONS report
- **THEN** the report appears at `<host_watch_path>/<project>/.tillandsias/runtime-limitations/RUNTIME_LIMITATIONS_<NNN>.md` after the mirror-sync pass completes

### Requirement: Provenance section is mandatory

Every cheatsheet under `cheatsheets/` SHALL include a `## Provenance` section listing at least one URL pointing to a high-authority external source AND a `**Last updated:** YYYY-MM-DD` line indicating the date the cheatsheet was last verified against the cited URLs. The section is placed immediately below the title, `@trace` annotation, optional DRAFT banner, and `**Use when**:` line — before `## Quick reference`.

**Authority hierarchy** (preferences listed top-to-bottom):
1. Vendor / standards body — `python.org`, `rust-lang.org`, `oracle.com`, `microsoft.com`, `aws.amazon.com`, `cloud.google.com`, `redhat.com`, `kernel.org`, `w3.org`, `whatwg.org`, `ietf.org` (RFC), ISO, IEEE, official language reference docs from the maintainer.
2. Recognised community projects with high signal-to-noise — `mozilla.org/MDN`, `postgresql.org`, `sqlite.org`, `nginx.org`, `golang.org/doc`, etc.
3. Multiple sources are recommended for topics with no single source of truth (e.g., bash → cite GNU bash manual + POSIX + ShellCheck wiki + Greg's BashFAQ).

Stack Overflow, blogs, and AI-generated content are NEVER acceptable as primary provenance. They MAY appear as named secondary references. A cheatsheet citing only those is REJECTED at review.

#### Scenario: Cheatsheet with vendor docs as provenance
- **WHEN** an author writes a new cheatsheet for `cargo`
- **THEN** the file SHALL contain a `## Provenance` section with at least one URL under `doc.rust-lang.org/cargo/` (the vendor source)
- **AND** the section SHALL contain a `**Last updated:** YYYY-MM-DD` line with a date no later than the date the cheatsheet was committed

#### Scenario: Multi-source cheatsheet for a no-single-authority topic
- **WHEN** an author writes a cheatsheet for `bash`
- **THEN** the `## Provenance` section SHALL list at least two of: GNU bash manual (`gnu.org/software/bash/manual/`), POSIX shell spec (`pubs.opengroup.org`), ShellCheck wiki, Greg's BashFAQ
- **AND** each URL SHALL be on its own line with a one-line description of what it covers

#### Scenario: Cheatsheet with no high-authority source is REJECTED
- **WHEN** a reviewer evaluates a cheatsheet whose `## Provenance` section lists only Stack Overflow answers, blog posts, or AI-generated docs
- **THEN** the review SHALL reject the cheatsheet
- **AND** the cheatsheet SHALL NOT be merged in its current form

### Requirement: DRAFT banner for legacy or unverified cheatsheets

Cheatsheets that exist but lack verified provenance SHALL carry a DRAFT banner immediately after the `@trace` line:

```markdown
> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)
```

The banner serves two purposes: (a) honest signalling to readers that the cheatsheet is unverified; (b) machine-grep-able marker (`grep -l 'DRAFT — provenance pending' cheatsheets/`) so the retrofit sweep knows what's outstanding. When the cheatsheet is retrofitted with real provenance, the banner is REMOVED in the same commit that adds the `## Provenance` section.

#### Scenario: Existing cheatsheet without provenance carries banner
- **WHEN** a cheatsheet was authored before the provenance-mandatory rule and still lacks a `## Provenance` section
- **THEN** it SHALL contain the DRAFT banner directly below the `@trace` line
- **AND** an `openspec validate` warning is emitted on any spec citing the cheatsheet under `## Sources of Truth`

#### Scenario: Banner removed when provenance is added
- **WHEN** a retrofit commit adds a `## Provenance` section with verified URLs and a `Last updated:` date
- **THEN** the same commit SHALL remove the DRAFT banner
- **AND** the banner SHALL NOT be re-added in subsequent commits unless the provenance is invalidated

### Requirement: Cheatsheet citation traceability through code, logs, and specs

Code (Rust, shell, etc.) and log events whose behaviour was informed by a cheatsheet SHALL cite the cheatsheet by relative path the same way `@trace spec:` cites specs. Format:

- Rust: `// @cheatsheet <category>/<filename>.md` near the function
- Shell: `# @cheatsheet <category>/<filename>.md` near the relevant block
- Log events: `cheatsheet = "<category>/<filename>.md"` field on accountability-tagged events
- OpenSpec specs: cite under `## Sources of Truth` (existing requirement)

This creates a queryable graph: `git grep '@cheatsheet'` finds every code citation, `rg cheatsheet=` finds every log citation, and OpenSpec already lists per-spec citations. The cheatsheet→code→spec graph becomes navigable.

#### Scenario: Code function citing a cheatsheet
- **WHEN** a function in `src-tauri/src/handlers.rs` implements a behaviour documented in `cheatsheets/runtime/forge-container.md`
- **THEN** the function header (or the relevant code block) SHALL contain `// @cheatsheet runtime/forge-container.md`

#### Scenario: Log event with cheatsheet attribution
- **WHEN** an accountability-tagged log event emits because of cheatsheet-derived behaviour
- **THEN** the event SHALL include `cheatsheet = "<category>/<filename>.md"` as a structured field
- **AND** the field SHALL be queryable by log filtering tools

### Requirement: Refresh cadence and staleness signal

Each cheatsheet's `**Last updated:** YYYY-MM-DD` line drives a soft staleness check. Cheatsheets older than 90 days (project-defined; configurable in `scripts/check-cheatsheet-staleness.sh` when implemented) SHALL be flagged for re-verification. The check is a soft warning, not a build-blocker — staleness is informational.

The refresh action SHALL re-fetch every cited URL and confirm the cheatsheet content still matches what's on the source. Mismatches result in either a content update OR a switch to a different cited source. The `**Last updated:** YYYY-MM-DD` line is bumped only after re-verification — never blindly.

#### Scenario: Cheatsheet older than 90 days flagged
- **WHEN** the staleness check runs and finds a cheatsheet whose `**Last updated:**` date is more than 90 days old
- **THEN** the check emits a warning naming the cheatsheet and its age
- **AND** the warning is informational — does NOT fail any build

#### Scenario: Refresh updates the date
- **WHEN** an author or agent re-verifies a cheatsheet against its cited URLs
- **AND** the content still matches (or has been corrected to match)
- **THEN** the `**Last updated:** YYYY-MM-DD` line SHALL be bumped to today's date in the same commit
- **AND** the date SHALL NOT be bumped without re-verification

### Requirement: Provenance section — `local:` field per cited URL

Every URL citation in a cheatsheet's `## Provenance` section SHALL be accompanied
by a `local:` sub-field on the line immediately after the URL, once the URL has
been fetched and stored in `cheatsheet-sources/`. URLs that have NOT been
fetched (off-allowlist domains, pending manual review) SHALL be left as bare
URL lines with no `local:` field.

This extends the existing Requirement "Cheatsheet template" in the main
`agent-cheatsheets` spec. The template scenario "Provenance section SHALL
contain at least one URL and a `**Last updated:**` line" is unchanged; this
delta adds the `local:` sub-requirement.

#### Scenario: local: field present after fetch
- **GIVEN** a cheatsheet cites `https://doc.rust-lang.org/book/` in `## Provenance`
- **AND** `scripts/fetch-cheatsheet-source.sh` has fetched it
- **THEN** the Provenance entry looks like:
  ```
  - The Rust Programming Language (official): <https://doc.rust-lang.org/book/>
    local: `cheatsheet-sources/doc.rust-lang.org/book`
  ```

#### Scenario: bare URL remains for off-allowlist source
- **GIVEN** a cheatsheet cites `https://docs.oracle.com/...` in `## Provenance`
- **AND** that domain is off-allowlist (do-not-bundle)
- **THEN** the Provenance entry has NO `local:` field
- **AND** the cheatsheet MAY add a comment `# [unfetched: off-allowlist]` after the URL

#### Scenario: INDEX.md shows verify state
- **GIVEN** all of a cheatsheet's Provenance URLs have been fetched
- **WHEN** `scripts/regenerate-cheatsheet-index.sh` runs
- **THEN** the cheatsheet's line in `cheatsheets/INDEX.md` ends with
  `[verified: <sha8>]` where `<sha8>` is the first 8 hex chars of the
  first fetched source's SHA-256
- **GIVEN** only SOME Provenance URLs have been fetched
- **THEN** the line ends with `[partial-verify]`

## Sources of Truth

- `cheatsheets/agents/claude-code.md` — Agent framework and patterns
- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — Cheatsheet architecture and lifecycle

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
grep -rn "@trace spec:agent-cheatsheets" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
