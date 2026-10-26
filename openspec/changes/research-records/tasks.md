# Tasks: research records

@trace spec:research-records

## Slice 1 — record format, validator, seeded library (order 1809-dwqf) — done in this change

- [x] `research/TEMPLATE.md`, `research/README.md`
- [x] `scripts/lua/check-research-records.lua` (+ `--write-index`)
- [x] `scripts/lua/test-research-records.lua` (7 arms; arm 2 fails on a record without sources)
- [x] `openspec/litmus-tests/litmus-research-records-shape.yaml`, bound in `openspec/litmus-bindings.yaml`
- [x] `openspec/specs/research-records/spec.md`
- [x] Eight seeded records with verified DOIs / standards pages / primary scan and Wayback snapshots
- [x] `research/INDEX.md` generated
- [x] `images/default/Containerfile`: `COPY research/ /opt/research/`, `TILLANDSIAS_RESEARCH=/opt/research`
- [x] `skills/find-research/SKILL.md`, `skills/cite-research/SKILL.md`
- [x] `skills/start-a-new-project`: research pass first; scaffold creates `research/README.md`

## Slice 2 — preload and discovery in the forge (order 1809-37hs)

- [ ] `tellme research <topic>` (or `tellme about` reading both indexes), with the hollow-mount fallback `tellme` already has for cheatsheets
- [ ] `.forge-startup-context.md` names `$TILLANDSIAS_RESEARCH` and the two skills
- [ ] litmus arm: inside the image, `tellme research fitts` answers from `/opt/research`

## Slice 3 — per-project store tooling (order 1809-apd2)

- [ ] `research pull <id>` (Lua on the plan binary): copies a shared record into the project's `research/`, flips `origin: project`, re-validates, regenerates the project index
- [ ] project-discipline: a project with `research/` gets the validator in its pre-push hook set

## Slice 4 — the fine-tuning trigger, measured (order 1809-tx7k)

- [ ] a counter the agent can consult: N adjustments to one feature within a session
- [ ] a negative control: the trigger does not fire on the first adjustment, nor on unrelated features
- [ ] forge diagnostics prompt asks whether the trigger fired and whether the user accepted

## Slice 5 — cache-layer source fetcher (order 1809-3kyb)

- [ ] `research fetch <url>`: saves page text / PDF under `${XDG_CACHE_HOME:-~/.cache}/tillandsias/research/<sha>` and requests a Wayback snapshot (`https://web.archive.org/save/<url>`), returning the archived URL for the record
- [ ] disk check before the download; refuse on a full cache layer with the remedy
