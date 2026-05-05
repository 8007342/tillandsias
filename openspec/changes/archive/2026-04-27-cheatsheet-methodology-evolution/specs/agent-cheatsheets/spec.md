## ADDED Requirements

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

## MODIFIED Requirements

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

## Sources of Truth

- `cheatsheets/agents/openspec.md` (DRAFT) — workflow this change uses.
- `cheatsheets/runtime/forge-container.md` (DRAFT) — runtime context for the cheatsheets.
