---
# Copy this block VERBATIM and fill it in. Every field is read by
# scripts/lua/check-research-records.lua; a record that fails it is uncitable.
# Canon: openspec/specs/research-records/spec.md. Sibling system: cheatsheets/
# (technical ground truth). Research records hold NON-technical ground truth:
# what people do, feel and perceive, measured by someone reputable.

# Path-shaped id, equal to <domain>/<filename-without-.md>.
id: domain/slug-author-year
# ONE sentence. The thing an agent will cite. No hedging prose here; put the
# nuance under ## Evidence.
claim: >
  What the research found, as a single falsifiable sentence.
# Situations this applies to: 2-8 kebab-case terms an agent building something
# would recognise (form-layout, loading-feedback, game-difficulty, ...).
applies_to: [situation-one, situation-two]
# Discovery tags for search. 3-8 kebab-case terms.
tags: [example-tag, another-tag]
# Provenance chain. At least one source. Each needs url + kind + retrieved +
# archived. `archived` is a Wayback (or other archive) URL, or
# `pending: <reason>` when no archive exists yet — never omitted.
sources:
  - url: https://doi.org/10.0000/example
    doi: 10.0000/example
    kind: peer-reviewed   # peer-reviewed | standard | primary-report | expert-secondary | tertiary
    title: Full title of the work
    authors: Surname, A.; Surname, B.
    year: 2000
    venue: Journal or publisher
    archived: https://web.archive.org/web/20260101000000/https://doi.org/10.0000/example
    retrieved: YYYY-MM-DD
# Authority of the BEST source above: primary (the people who did the work or
# the standards body) | secondary (a reputable expert summarising primary work)
# | tertiary (encyclopaedias, aggregator sites, blog posts).
authority: primary
# How strong the evidence is: established (textbook, replicated for decades) |
# replicated (independent replications exist) | single-study | expert-opinion
# | contested (serious published disagreement — say so under ## Evidence).
strength: established
# ISO date this record was first authored.
since: YYYY-MM-DD
# ISO date the sources were last re-read. Bump only when you re-read them.
last_verified: YYYY-MM-DD
# current | superseded | retracted
status: current
# shared (ships in the image library) | project (lives in this project only)
origin: shared
---
# <Short human title>

@trace spec:research-records

## Claim

Restate the claim in one or two sentences, in plain language.

## Evidence

What was measured, on whom, how. Numbers with their units. Where the evidence
is weaker than the claim sounds, say so here. Where later work disagrees,
say so here.

## How it applies

Two to five bullets: the concrete design decisions this research supports,
written the way an agent should cite them ("as per research:<id>, ...").

## Provenance

- <https://doi.org/10.0000/example>
  archived: <https://web.archive.org/web/20260101000000/https://doi.org/10.0000/example>
  retrieved: YYYY-MM-DD

## See also

- `research:domain/other-record`
- `cheatsheet:category/related-sheet.md`
