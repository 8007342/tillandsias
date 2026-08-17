---
# Copy this block VERBATIM and fill it in. Every field below is read by a gate
# or by the expert system; a cheatsheet without frontmatter is invisible to
# scripts/check-cheatsheet-tiers.sh and to every provenance check, which means
# its claims are uncitable — the experts treat cheatsheets as ground truth
# (methodology.yaml -> cheatsheets_are_ground_truth_and_enforced_by_local_experts),
# so an unclassifiable sheet is worse than a missing one.
# Canon: methodology/cheatsheets.yaml -> cheatsheet_binding + storage_and_authority.

# Discovery tags for RAG/expert retrieval. 3-8 kebab-case terms an agent would
# actually search. Do NOT ship an empty list.
tags: [example-tag, another-tag]
# Languages this sheet is about, for retrieval filtering. [] if not language-specific.
languages: [bash]
# ISO date this sheet was first authored.
since: YYYY-MM-DD
# ISO date the provenance chain below was last re-checked against upstream.
# This is the staleness signal the freshness audit reads — bump it when you
# actually re-read the sources, never as a formality.
last_verified: YYYY-MM-DD
# The provenance chain: upstream URLs owned by the technology provider or a
# standards body. Project-local inference is NOT provenance (canon:
# cheatsheets.provenance.rule) — label derived notes as derived, or move them
# into the owning spec.
sources:
  - https://example.com/official-docs
# Trust level of those sources: high | medium | low.
authority: high
# Lifecycle: current | deprecated | obsolete.
status: current
# Distribution tier — bundled | distro-packaged | pull-on-demand. When omitted
# the validator infers it from cheatsheets/license-allowlist.toml and
# SAFE-DEFAULTS to pull-on-demand, so set it explicitly if the sheet must be
# baked into the image. A domain absent from the allowlist needs an explicit
# `tier: bundled` (see cheatsheets/concurrent-git/git-mirror-enterprise-practices.md
# for the precedent).
tier: pull-on-demand
# hand-curated, or the model/order that generated the summary.
summary_generated_by: hand-curated
# Is this sheet baked into the forge image?
bundled_into_image: false
# Is this sheet committed for this project (as opposed to pulled on demand)?
committed_for_project: true
---
# <Tool/Language Name>

@trace spec:cheatsheet-tooling

**Version baseline**: <version pinned in the forge>  
**Use when**: <one-line elevator pitch — the situation this cheatsheet covers>

## Quick reference

[scannable table or short bullet list of the most-used commands/syntax]

## Common patterns

[3–5 idiomatic snippets agents will write all the time]

## Common pitfalls

[3–10 traps — wrong defaults, deprecated flags, gotchas]

## Provenance

<!-- REQUIRED. cheatsheet-source-layer "Provenance binding": every cited URL
     that has been FETCHED carries a `local:` line immediately after it,
     pointing at the verbatim on-disk copy, so a maintainer can re-verify
     offline with `cat`. An off-allowlist URL with no committed copy stays
     bare (no `local:`) but still needs its sidecar in cheatsheet-sources/.
     Project-local inference is NOT provenance (methodology/cheatsheets.yaml
     -> provenance.rule): label derived notes as derived, or move the claim
     into the owning spec. Restored 2026-08-17 — 782-avtk removed this
     section while making the template "satisfy the canon", which reded
     litmus:cheatsheet-source-layer-shape STEP 6 and
     litmus:cheatsheet-tooling-structure STEP 2 fleet-wide. -->

- <https://upstream.example.org/docs/thing>
  local: `cheatsheet-sources/upstream.example.org/docs/thing`
- <https://off-allowlist.example.com/reference> (do-not-bundle; sidecar only)

## See also

- `<category>/<other-cheatsheet>.md`
- `<category>/<other-cheatsheet>.md`
