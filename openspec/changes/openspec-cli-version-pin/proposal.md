# OpenSpec CLI version pin

Plan: order 1441-myz3 (stacked on 1422-w3p8 and 1440-w8g8).

## Why

The project recorded no openspec CLI version, while committing the files that
CLI generates (the `/opsx` commands and `openspec-*` skills under `.claude/`,
`.opencode/`, `.github/`, `.codex/`). Every forge launch ran
`npm install -g @fission-ai/openspec@latest` in the background, into the same
npm prefix its foreground `openspec init` used. So:

- the first launch after any openspec release rewrote tracked files, and the
  forge started dirty (18 files at t=0, measured twice on 2026-09-26/27);
- "updating openspec" meant committing that dirt (order 540's sync step, which
  the operator reversed on 2026-09-27);
- trunk ended up holding three generator versions at once: `.claude` 1.13.1,
  `.opencode` 1.13.2, `.codex`/`.github` 1.3.1.

The operator's direction (2026-09-27): the orchestrator running
meta-orchestration updates OpenSpec when there are updates, and a fresh forge's
openspec matches the project's own, so a fresh checkout never sees a dirty
refresh.

A deliberate `openspec update` at 1.13.2 produces files byte-identical to the
18-file launch dirt. A pinned, deliberately regenerated tree is therefore
exactly what a forge at that version writes, and launch has nothing to change.

## What changes

- **The pin.** `openspec/cli-version` holds the project's one openspec version.
- **The forge installs the pin.** `ensure_openspec_pinned` (lib-common.sh)
  installs exactly the pinned version into the global npm prefix every shell
  puts first on PATH, under the npm-update lock. It records the pin in a marker
  on the per-project cache, and every entrypoint calls it before
  `openspec_init_if_absent`.
- **The refresher stops moving it.** `ensure_forge_harnesses` skips its
  `@latest` openspec refresh while that marker exists. Unpinned projects keep
  today's behaviour.
- **The coordinator moves it deliberately.** `scripts/openspec-pin.sh`
  provides `pin`, `check`, `drift`, `install` and `bump`. meta-orchestration
  coordinator duty 6 runs `check`, and on `due:` runs `bump`, which regenerates
  every configured tool with an isolated openspec config. The result is
  committed as one `chore(openspec): bump CLI <old> -> <new>` change.
- **The first re-levelling is made by the step itself**, as its own commit
  (coordinator direction), so the step is proven by use.

## Non-goals

- Choosing which harnesses get openspec skills (Gemini, the `.codex` →
  `.agents` move beyond what the CLI itself supersedes) and the planning-boundary
  paragraph: 1253-nmmy.
- Changing the workflow profile. It is derived from the committed workflows,
  and changing it is its own decision.
- Baking openspec into the image. The pin is a project property, not an image
  property: two projects in one forge image can pin different versions.

## Impact

- `openspec/cli-version`, `scripts/openspec-pin.sh`, `scripts/test-openspec-pin.sh`
- `images/default/lib-common.sh`, the four forge entrypoints
- `skills/meta-orchestration/SKILL.md` (coordinator duty 6)
- `openspec/litmus-tests/litmus-openspec-cli-pin-shape.yaml`, bound to
  `meta-orchestration`
