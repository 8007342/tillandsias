# Research records: a provenance-backed research system for forges

@trace spec:research-records

## Why

Projects built in Tillandsias forges (ranitas, arabiya, cannonball,
demon_attack) found good research online — Valve-style GameFlow work,
attention and engagement studies, flow, animation timing, change blindness —
and had nowhere durable to keep it. The ranitas field report
(`FORGE_DIAGNOSTICS.md`, `docs/quiet-awakening.md`) records that several of
the pages it cited were already 403/502/503 a week later, and that it had to
separate "what the research says" from "what we chose for artistic reasons"
by hand. The cheatsheet system solves exactly this for technical knowledge
(provenance chain, authority grade, freshness date, index, shipped in the
image) and nothing does it for research that is about people rather than
tools.

Operator direction, 2026-10-26: build a RESEARCH system analogous to
cheatsheets. Agents cite research in what they build ("as per <research>,
these two forms are related as <relationship> because <explanation>"); when a
user fine-tunes a feature at length the agent offers to look for research
from reputable authorities instead of ad-libbing; research skills are
preloaded in the forge; a new project starts with a research pass.

## What changes

- **Record format.** `research/<domain>/<slug>.md`: YAML frontmatter with a
  one-sentence claim, `applies_to`, sources (url, kind, DOI where one exists,
  archived snapshot, retrieval date), authority and strength grades, dates,
  status and origin; a body with Claim / Evidence / How it applies /
  Provenance. `research/TEMPLATE.md` is the canonical block.
- **Validator.** `scripts/lua/check-research-records.lua` refuses a record
  without provenance, without an archived link, without a claim, or whose id
  does not match its path; `--write-index` generates `research/INDEX.md`.
  `scripts/lua/test-research-records.lua` executes it on constructed records.
  `litmus:research-records-shape` binds both to this spec.
- **Shared library.** Eight seeded records with verified provenance (GameFlow,
  flow, Nielsen's response-time limits, Fitts's law, the Doherty threshold
  from the IBM primary, NN/g animation guidance, Simons et al. change
  blindness, WCAG 2.3.3). Shipped in the image at `/opt/research`
  (`TILLANDSIAS_RESEARCH`).
- **Citation convention.** `research:<id>` everywhere; `@research <id>` in
  code beside `@cheatsheet`; `Research: <id>` commit trailer.
- **Forge skills.** `find-research` (find, vet, pull in, archive, record) and
  `cite-research` (cite correctly; the fine-tuning trigger that offers a
  research search after repeated adjustments to one feature).
- **Start-of-project hook.** `start-a-new-project` does a research pass
  before scaffolding and the scaffold creates `research/README.md`.
- **Disk awareness.** Fetched sources go to the cache layer, never to the
  tmpfs workspace or the committed store.

## What does not change

- Cheatsheets stay the home of technical ground truth; a research record
  that is really a vendor-docs fact belongs in a cheatsheet.
- No new service, no network at validation time, no commercial dependency.
  DOIs resolve through the public Crossref registry; archives are the
  Internet Archive's Wayback Machine, which is free and has no cap.

## Impact

- New: `research/`, two skills, one validator, one fixture, one litmus, one
  spec, one Containerfile COPY + ENV line.
- Changed: `skills/start-a-new-project/`, `openspec/litmus-bindings.yaml`.
- Follow-up packets: 1809-dwqf (this slice), 1809-37hs (skills preload and
  `tellme research`), 1809-apd2 (per-project store tooling and the project
  pull-in command), 1809-tx7k (fine-tuning trigger instrumentation and a
  negative control), 1809-3kyb (cache-layer source fetcher).
