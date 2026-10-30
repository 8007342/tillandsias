# Research Records Specification

@trace spec:research-records

## Status

active (order 1809-dwqf, 2026-10-26; sibling of spec:cheatsheet-tooling for
non-technical, provenance-backed research)

## Purpose

Projects built in Tillandsias forges find good research — GameFlow, flow
theory, response-time limits, change blindness — and have nowhere durable to
keep it, so the next session re-derives requirements from taste. This spec
defines the research record: a claim, its sources with an archived link, an
authority and strength grade, the retrieval date and where it applies. It
defines the shared library that ships in the forge image, the per-project
store, the citation grammar (the same shape as cheatsheet citations) and the
validator that refuses a record without provenance.

## Requirements

### Requirement: A research record is a claim with a complete provenance chain
<!-- req-id: 969f6b3e -->

A research record SHALL be a Markdown file at `research/<domain>/<slug>.md`
with YAML frontmatter carrying: `id` equal to `<domain>/<slug>`; a one-sentence
`claim`; a non-empty `applies_to` list; a non-empty `sources` list in which
every entry carries `url`, `kind` (peer-reviewed | standard | primary-report |
expert-secondary | tertiary), `retrieved` (ISO date) and `archived` (an
archive URL, or `pending: <reason>`); `authority` (primary | secondary |
tertiary); `strength` (established | replicated | single-study |
expert-opinion | contested); `since` and `last_verified` (ISO dates); `status`
(current | superseded | retracted); and `origin` (shared | project). The body
SHALL carry a `## Provenance` section. `research/TEMPLATE.md` SHALL carry
this block and the owner trace.

#### Scenario: A record without sources is refused
- **WHEN** `scripts/lua/check-research-records.lua` reads a record whose
  frontmatter has no `sources` list
- **THEN** it exits 1 and its verdict names the record path and
  `sources:missing-provenance`

#### Scenario: A source without an archived link is refused
- **WHEN** a source entry has `url` and `retrieved` but no `archived`
- **THEN** the validator exits 1 naming `sources[<n>].archived:missing-archived-link`

#### Scenario: An empty store is not a green store
- **WHEN** the research directory holds no `<domain>/<slug>.md`
- **THEN** the validator exits 3 with `could-not-run:research-records:empty-population`

### Requirement: The shared library ships in the forge image beside the cheatsheets
<!-- req-id: c74b20e3 -->

The repository SHALL keep the shared library at top-level `research/`, grouped
by domain, with a generated `research/INDEX.md` (written by the validator's
`--write-index`, never hand-edited). The forge image SHALL copy `research/` to
`/opt/research` and export `TILLANDSIAS_RESEARCH=/opt/research`. Agents SHALL
treat `$TILLANDSIAS_RESEARCH/INDEX.md` as the discovery surface and fall back
to the repository-local `research/INDEX.md` when the mounted copy lacks an
index (the hollow-mount shape `tellme` guards against for cheatsheets).

#### Scenario: The library validates in the pre-build suite
- **WHEN** `litmus:research-records-shape` runs
- **THEN** every shipped record passes the validator and the Containerfile
  carries the copy and the environment variable

### Requirement: Every seeded entry has real, verified provenance
<!-- req-id: 54a04708 -->

A record in the shared library SHALL cite a source the author actually opened
(a DOI resolved through its registry, a standards-body page, or a primary
report), with an archive snapshot URL. An entry whose source cannot be
verified SHALL be dropped, not graded down. The record's `## Evidence`
section SHALL say what the source measured and where the claim is weaker
than it sounds (for example, a popular round number that the primary does
not state).

#### Scenario: A popular figure is not promoted over the primary
- **WHEN** a record's primary source states a qualitative finding and
  secondary sources attach a round number to it
- **THEN** the record's `claim` carries the primary's wording and `## Evidence`
  labels the round number as secondary

### Requirement: Research is cited the way cheatsheets are cited
<!-- req-id: 8f7c7c61 -->

Agents SHALL cite a record, not a paper, in the grammar `research:<id>`:
`@research <id>` in a code comment (beside `@cheatsheet`), "as per
research:<id>, ..." in spec and design prose, and a `Research: <id>` commit
trailer. A citation asserts that the record's `claim` supports the decision;
the sentence that cites it SHALL say what the decision is and why the claim
supports it.

#### Scenario: A design decision carries its research
- **WHEN** an agent decides that two forms must be related in a given way
- **THEN** the design says "as per research:<id>, these forms are related as
  <relationship> because <explanation>" rather than describing the forms
  alone

### Requirement: Caches follow the storage direction
<!-- req-id: 2f6918a8 -->

Fetched page text, PDFs and search results SHALL be written under the cache
layer (`${XDG_CACHE_HOME:-~/.cache}/tillandsias/research/`), never into
`research/` and never onto the forge's RAM tmpfs. The committed record carries
only the claim, the metadata and the archive URL.

#### Scenario: A pulled-in PDF is not committed
- **WHEN** the find-research skill downloads a source to read it
- **THEN** the file lands in the cache layer and `git status` in the project
  shows only the new record
