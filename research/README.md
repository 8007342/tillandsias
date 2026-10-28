# Research library

@trace spec:research-records

Curated, provenance-backed research that agents cite when they design things
for people: attention, engagement, flow, perception, response time, animation,
interaction and performance. The sibling of `cheatsheets/` (technical ground
truth) for claims that are about humans rather than tools.

- **Shared library** (this directory): ships in the forge image at
  `$TILLANDSIAS_RESEARCH` (`/opt/research`), one record per claim, grouped by
  domain. Every record carries a claim, its sources with an archived link, an
  authority and strength grade, the retrieval date and where it applies.
- **Per-project store**: a project keeps its own records in `research/` at its
  root, in the same format, with `origin: project`. The shared library is
  read-only inside a forge; a project pulls a shared record in by copying it.
- **Caches** (downloaded PDFs, fetched page text) are never committed here.
  They go in the cache layer (`~/.cache/tillandsias/research/`), which
  survives restarts and is wiped and rebuilt on corruption.

## Citing

Same grammar as cheatsheets:

| Where | Form |
| --- | --- |
| code comment | `// @research interaction/response-time-limits-nielsen-1993` |
| spec or design prose | `as per research:interaction/fitts-law-1954, the targets are ...` |
| commit trailer | `Research: interaction/fitts-law-1954` |

A citation is a claim that the record's `claim:` line supports the decision.
Cite the record, not the paper; the record carries the provenance.

## Authoring

Copy `TEMPLATE.md` into the right domain directory, fill every frontmatter
field, then run the validator:

```bash
"$(. scripts/plan-binary-probe.sh && resolve_plan_binary)" script run scripts/lua/check-research-records.lua
"$(. scripts/plan-binary-probe.sh && resolve_plan_binary)" script run scripts/lua/check-research-records.lua -- --write-index
```

Never invent a citation. A record whose source you could not open gets
`strength: expert-opinion` at best and says so under `## Evidence`; a record
with no source at all is refused.

`INDEX.md` is generated. Do not hand-edit it.
