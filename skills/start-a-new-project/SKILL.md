---
name: start-a-new-project
description: Use when the user wants to start a new project, asks how to begin, or is in an empty or nearly empty repository ("how do I start?", "I want to build an app", "help me set up a new project"). Guides them, in plain language, to describe the app as specs first (spec-driven development with OpenSpec), recommends Flutter (and the Flame engine for games and graphics), and sets up specs, a plan folder for longer work, and a README. Works for any project, not only Tillandsias.
license: MIT
metadata:
  author: tillandsias
---

# Start a new project

The user is starting something new. Help them get from an idea to a running
app quickly, with a project shape that keeps working as the app grows.

Speak plainly. The user may not be a developer. Do not explain how this
environment works behind the scenes; just help them build their app.

## 1. Ask what they want to build

Ask one short question: what is the app, and who is it for? If they already
said, restate it in one sentence and confirm. Do not ask a list of questions.

## 1b. Start with the research

Before writing specs, look for research that applies to this kind of app and
keep it next to the project. Nothing to explain to the user yet; one short
sentence is enough ("I'm checking what's known about <games / forms /
onboarding> first").

```bash
lib="${TILLANDSIAS_RESEARCH:-/opt/research}"
[ -f "$lib/INDEX.md" ] || lib="research"
rg -i '<two or three words for the app: game, form, loading, animation>' "$lib/INDEX.md"
```

Pull each relevant record into the project: copy
`$lib/<domain>/<slug>.md` to `research/<domain>/<slug>.md` and change
`origin: shared` to `origin: project`. For a game, that is at least
`games/gameflow-sweetser-wyeth-2005` and
`psychology/flow-nakamura-csikszentmihalyi-2014`; for anything with buttons
and waits, `interaction/fitts-law-1954` and
`interaction/response-time-limits-nielsen-1993`. If the library has nothing
for this kind of app, use the `find-research` skill once the first spec names
the behaviour that matters most.

When you write the specs in step 2, cite what you pulled in ("as per
research:<id>, ... because ...") — see the `cite-research` skill. Research
goes in `research/`; the scaffold below creates its README.

## 2. Recommend spec-driven development

Suggest writing down what the app should do before writing code, as short
specs the agent and the user both keep up to date. Say why in one or two
sentences: the specs become the shared memory of the project, so later
sessions (and other agents) pick up exactly where the last one stopped, and
changes are proposed and reviewed before they are built.

Recommend OpenSpec for this (it is already installed here). Ask for a yes.
If they decline, skip the specs and keep going; never insist.

## 3. Recommend a stack

- **Apps (web, mobile, desktop): strongly recommend Flutter.** One codebase
  runs on phones, tablets, desktop and the web, and you can preview it right
  here on several phone sizes at once.
- **Games, animations, anything graphics-heavy: Flutter plus the Flame
  engine.**
- If the user already has a preference (a plain website, React, something
  else), follow it. The recommendation is a suggestion, not a rule.

Before promising Flutter works, check: `command -v flutter`. If it is not
available, say so honestly in one sentence ("Flutter support in this
environment is still being set up; I can start with the specs and plan now,
or build a plain web version first") and let the user choose. Never claim a
tool works without having run it.

## 4. Set the project up

Once the user agrees, run the setup script from this skill's directory:

```bash
bash "<this skill's directory>/scaffold.sh" --name "<App Name>" --summary "<one-sentence description>" [--stack flutter|flutter-flame|web|other] [--no-specs]
```

It creates only what is missing and never overwrites the user's files:

- `openspec/` with a first spec describing the app (unless `--no-specs`),
- `plan/` with a `README.md` and a `roadmap.md` for work that spans sessions,
- `research/` with a `README.md` saying how records are kept and cited,
- `README.md` with the app's name and summary.

Then fill in the first spec together with the user: three to five
requirements in their own words, each with one concrete example.

## 5. Build the first version

Start with the smallest version that runs. For Flutter:
`flutter create .` (or `flutter create --platforms web,android,ios .`), add
Flame with `flutter pub add flame` for a game, then build and show it. When
it runs, offer to open it on a couple of phone sizes side by side.

Commit and push after each working step, with a short message saying what
the user can now do. Unpushed work is lost when the session ends.

## 6. Keep the plan current

When a task will take more than one session, add it to `plan/roadmap.md` as
one line: what is left, not what was done. At the end of a session, update
the line so the next session can start from it.
