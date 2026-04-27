# agent-cheatsheets — Delta spec (cheatsheet-source-layer change)

@trace spec:agent-cheatsheets, spec:cheatsheet-source-layer

## Purpose

This delta spec extends the existing `agent-cheatsheets` capability
(`openspec/specs/agent-cheatsheets/spec.md`) with one additional Requirement:
every cited URL in a cheatsheet's `## Provenance` section MUST include a
`local:` field pointing to the verbatim on-disk file, once that file has
been fetched into `cheatsheet-sources/`. This change is additive — existing
requirements are unchanged.

## CHANGED Requirements

### Requirement: Provenance section — `local:` field per cited URL (NEW)

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

- `openspec/specs/agent-cheatsheets/spec.md` — the base spec this delta modifies
- `openspec/changes/cheatsheet-source-layer/specs/cheatsheet-source-layer/spec.md` — the source layer spec that defines `local:` semantics
- `docs/strategy/cheatsheet-source-layer-plan.md` — §6 "Cheatsheet ↔ source binding" for the exact format
