---
name: find-research
description: Use when a design question is about people rather than tools — attention, engagement, flow, tension and relaxation, animation timing, interaction, perceived performance — and you want a reputable answer instead of a guess ("is there research on this?", "what do the authorities say about loading spinners?", the user has adjusted one feature many times). Finds, vets, archives and records research as a provenance-backed record in the project's research/ store, in the same format as the shared library at $TILLANDSIAS_RESEARCH. Works for any project in a Tillandsias forge.
license: MIT
metadata:
  author: tillandsias
  trace: spec:research-records
---

# Find research

A research record is a claim with a complete provenance chain. This skill
produces one. It never produces a citation from memory.

## 1. Check what already exists

Before searching the web, read the indexes. Both are one line per record,
`<domain>/<slug>.md — <claim> [<authority>, <strength>]`:

```bash
lib="${TILLANDSIAS_RESEARCH:-/opt/research}"
[ -f "$lib/INDEX.md" ] || lib="research"      # hollow mount: fall back to the repo copy
rg -i '<topic words>' "$lib/INDEX.md" research/INDEX.md 2>/dev/null
```

If a shared record answers the question, pull it in (step 5) and stop. If a
project record answers it, cite it (`/cite-research`) and stop.

## 2. State the question as a claim to test

Write one sentence of the form "people <do/perceive/prefer> X when Y". That
sentence is what you search for and what the record's `claim:` will be, if
the research supports it. If the research contradicts it, the record says
what the research found, not what you hoped.

## 3. Search reputable sources first

In this order, stopping when you have a primary source:

1. Peer-reviewed work: a DOI you can resolve. Verify the metadata through
   the Crossref record, `https://api.crossref.org/works/<doi>` (free, no
   key), and keep the title, authors, venue and year it returns.
2. Standards bodies (W3C/WAI, ISO, IETF) and platform guidelines
   (Apple HIG, Material, GNOME HIG) for rules that are rules rather than
   findings.
3. Primary industry reports (a scanned original, a company's own research
   page) — grade `primary-report`.
4. Recognised expert syntheses (Nielsen Norman Group, Baymard, a
   university lab's summary) — grade `expert-secondary`.
5. Everything else is `tertiary` and is not enough on its own; use it only
   to find the primary.

Open the source. Read the part that supports the claim. If a page refuses
(403/429/502), try its archived copy; if neither opens, **drop it** and say so
in your reply. The ranitas field report lost half its citations to exactly
this rot, which is why `archived:` is mandatory.

## 4. Archive and cache

- Get a snapshot URL: `https://web.archive.org/web/2026/<url>` redirects to
  the latest snapshot (read the `Location` header with `curl -sI`). If none
  exists, request one with `https://web.archive.org/save/<url>` and record
  `archived: pending: save requested <date>` until it appears.
- Anything you download to read (PDF, page text) goes to the cache layer,
  never into the workspace or the record:
  `${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias/research/`. Check free space
  first (`df -h` on that path); a full disk is the most common overnight
  forge crash.

## 5. Write the record

Copy the template and fill every field; the validator refuses a record that
is missing any of them:

```bash
mkdir -p research/<domain>
cp "${TILLANDSIAS_RESEARCH:-research}/TEMPLATE.md" research/<domain>/<slug-author-year>.md
```

- `claim:` one sentence, the primary's wording, not a popular round number.
- `authority:` primary / secondary / tertiary — who said it.
- `strength:` established / replicated / single-study / expert-opinion /
  contested — how well it is known. A single paper is `single-study` even
  when famous.
- `## Evidence`: what was measured, on whom, and where the claim is weaker
  than it sounds. Where your design choice goes beyond the research (an
  exact duration, a colour), say that it is a design choice.
- `origin: project`.

To pull a shared record into the project instead, copy it from the library
and change `origin: shared` to `origin: project`; keep everything else.

Then validate and regenerate the project index:

```bash
# In a Tillandsias checkout the validator is scripts/lua/check-research-records.lua;
# in any other project, use the copy the forge ships beside this skill.
v=scripts/lua/check-research-records.lua
[ -f "$v" ] || v="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-/opt/skills/find-research/SKILL.md}")")/check-research-records.lua"
TILLANDSIAS_RESEARCH_DIR=research tillandsias-plan script run "$v" -- --write-index
```

The last line must be `ok:research-records:...`. A `violation:` line names
the record, the field and the reason. (Order 1809-apd2 replaces this with a
`research pull` / validate command.)

## 6. Report in one paragraph

Say what you looked for, which records you added or pulled in (by
`research:<id>`), which candidates you dropped and why, and what the research
says that changes the design. Then cite it in the work with
`/cite-research`.
