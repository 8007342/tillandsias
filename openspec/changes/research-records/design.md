# Design: research records

@trace spec:research-records

## Prior art (read 2026-10-26)

- **Cheatsheets** (`methodology/cheatsheets.yaml`, `cheatsheets/TEMPLATE.md`,
  `scripts/check-cheatsheet-tiers.sh`, `images/default/cli/tellme`). Provenance
  must come from the technology owner or a standards body; project-local
  inference is a derived note. Frontmatter carries `sources`, `authority`,
  `last_verified`, `status`, `tier`; the index is generated; the image copies
  the tree to `/opt/cheatsheets-image` and a hot mount at `/opt/cheatsheets`,
  and `tellme` falls back to the image bundle when the mount is hollow
  (920-tqhs). Research records copy every one of these shapes so an agent who
  knows one system knows the other.
- **Atomic research** (Pidcock, UX Brighton 2018): a research repository is a
  set of *nuggets* — an observation, the evidence behind it, and tags for
  retrieval — rather than reports nobody re-reads. Our record is a nugget:
  `claim` + `sources` + `applies_to`/`tags`.
- **Evidence grading** (GRADE, Oxford CEBM levels): rate the strength of a
  body of evidence separately from who said it. Hence two axes: `authority`
  (who: primary / secondary / tertiary) and `strength` (how well established:
  established / replicated / single-study / expert-opinion / contested).
  Both vocabularies are closed so the validator can refuse a typo.
- **Persistent identifiers and archives.** A DOI (resolved through
  `https://doi.org/` and verifiable through the public Crossref API) is the
  stable name for a paper; a Wayback Machine snapshot is the stable copy of a
  page. Both are free with no commercial cap. The record carries the DOI
  where one exists and an `archived` URL always; `pending: <reason>` is
  allowed so a record can be filed before the archive catches up, but the
  field cannot be omitted.
- **ranitas field report.** Half the cited pages rotted within days; the
  project had to label artistic timing choices apart from measured
  thresholds. The `## Evidence` section exists for that labelling, and the
  Doherty record is the worked example: the primary says "rises dramatically
  below one second", the popular 400 ms is secondary.

## Decisions

1. **One record per claim, Markdown with YAML frontmatter.** Same parser path
   as cheatsheets (`yaml.parse` on the frontmatter), readable on GitHub,
   greppable with `rg`.
2. **Id equals path.** `research:<domain>/<slug>` resolves to a file by
   construction; no registry to drift.
3. **Validator in Lua on the plan binary's `script run`.** No Python, no jq.
   Verdict grammar matches the other deciders (`ok:` / `violation:` /
   `could-not-run:` with exit 0 / 1 / 3). An empty population is
   could-not-run, not ok (a hollow mount must not read as green).
4. **Shared library and project store share one format.** `origin: shared`
   ships in the image; `origin: project` lives in the project's `research/`.
   Pulling in is copying the file and flipping `origin`; the shared copy in
   `/opt/research` is read-only.
5. **Citation grammar mirrors cheatsheets.** `@research <id>` beside
   `@cheatsheet <path>`; prose "as per research:<id>, <decision> because
   <explanation>"; trailer `Research: <id>`. A later guard can resolve every
   `research:` token against the two stores the way order citations are
   resolved today.
6. **Skills are two, not one.** Finding and vetting is a long, networked
   task; citing is a short, local one that must fire inside other work
   (including the fine-tuning trigger). Preloading both is a packet
   (1809-37hs) because the skills tree already ships to `/opt/skills`.
7. **Caches in the cache layer.** `${XDG_CACHE_HOME:-~/.cache}/tillandsias/research/`
   per the 2026-10-25 storage direction: survives restarts, wiped on
   corruption, never on the RAM tmpfs.

## Alternatives considered

- A single `RESEARCH.md` per project: cannot be validated per claim, cannot
  be indexed, cannot be pulled in piecemeal.
- BibTeX / CSL-JSON: machine-exact citation formats, but they have no place
  for the claim, the applies-to or the strength grade, and agents would not
  read them. A record can carry a `bibtex:` field later without changing the
  validator.
- A hosted research tool (Dovetail, Notion, Zotero cloud): commercial caps,
  no provenance enforcement, not readable inside an offline forge.

## Open questions

- Whether `tellme research <topic>` should be a subcommand of `tellme` or a
  separate CLI (packet 1809-37hs decides after reading `tellme`'s hot-path
  fixture).
- A guard that refuses a `research:` citation that resolves to no record
  (the cheatsheet system has no such guard either; file when the first
  dangling citation appears).
