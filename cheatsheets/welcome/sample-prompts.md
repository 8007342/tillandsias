---
tags: [empty-project, onboarding, prompts, welcome]
languages: []
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://github.com/8007342/tillandsias
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Empty Project Sample Prompts

@trace spec:project-bootstrap-readme @cheatsheet welcome/sample-prompts.md

**Version baseline**: Tillandsias v0.1.170+
**Use when**: Helping users understand what an in-forge agent + Flutter/Nix/Flame defaults can build from a cold start. Displayed on first attach to an empty project.

## Provenance

- <https://github.com/8007342/tillandsias> — Tillandsias forge methodology and capabilities
- **Last updated:** 2026-04-27

## Tier classification

`bundled` — these prompts ship with every forge image and are edited without rebuild via the cheatsheet refresh path.

## Sample Prompts

> Curated prompts that showcase what an in-forge agent + ollama + the bundled Flutter / Nix / Flame defaults can do from cold start. The user's empty-project welcome screen displays the first three (or three random ones — see "Selection").

- **Build a Pong web app.** "Build me a single-page web Pong game using Flutter web and the Flame engine, with WASD vs arrow-keys two-player local play and a simple scoreboard."

- **Inventory for my business.** "Help me build an inventory app for my small business — items have a name, photo, quantity, and a 'reorder when below' threshold. Local-first, sqlite backend, Flutter UI."

- **Calculus tutor.** "Design a single-page web app that helps me understand derivatives — interactive graph, drag the function, see the derivative graph update live."

- **Roguelike weekend.** "Make me a tiny roguelike in Flutter + Flame: 20×20 grid, one player @, three monsters M, walls #, food F, hjkl movement."

- **Knowledge garden.** "I want a markdown wiki I run locally — files in a folder, a Flutter web frontend that renders them with hyperlinks between [[notes]]."

- **My day in three numbers.** "Build me an app where I log three numbers a day (mood, sleep hours, focus minutes) and it shows me a 30-day trend graph."

### Selection

The empty-project welcome flow displays the **first three** by default. The agent MAY randomize selection if `RANDOM` is desired (`shuf -n 3` on the markdown list); the user's direction was for "at least three, generic and significantly different in domain." Three is a minimum; the cheatsheet may grow.

### Rationale per prompt

Each prompt was chosen to:
- Show a different domain (game / business / education / personal-tracking).
- Land cleanly on the methodology defaults (Flutter web, Flame for games, sqlite for storage, Nix for reproducibility) so a competent in-forge agent can converge a spec + implementation without external help.
- Be expressible in one sentence by AJ (the non-technical primary user).

## See also

- `welcome/readme-discipline.md` — the README structural contract that incorporates these prompts
- `agents/opencode.md` — OpenCode skill file convention used by the `/bootstrap-readme-and-project` skill
