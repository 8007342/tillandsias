## Why

`spec:project-summarizers` requires six language summarizers to be shipped
as standalone shell scripts and embedded in the forge at `/opt/summarizers/`
("Summarizers MUST be embeddable as shell scripts", scenario "Summarizer
embedded in binary": `include_str!`). That requirement was never wired.
Evidence on linux-next, 2026-11-19 (order 2114-sdj6):

- `git grep -n -E 'summarize-|summarizers' -- crates images` finds no
  `include_str!`, no Containerfile `COPY`, and no call site. The only hits are
  cheatsheet prose (`images/default/cheatsheets/...`) and an agent status
  note.
- `git grep -n 'opt/summarizers'` finds only the dispatcher's glob
  (`scripts/regenerate-readme.sh:30`) and cheatsheet prose. No image creates
  or populates `/opt/summarizers/`. `regenerate-readme.sh` itself is not
  shipped in any image.
- The scripts' only consumers were `litmus:project-summarizers-shape`, which
  greps their own source for `set -e`, `@trace` and `exit 2`, and
  `scripts/test-summarize-pubspec.sh`, which pins one of them.

Code that nothing runs is not a capability. In the tech-debt session
(coordinator ruling, macuahuitl-fedora, 2026-11-19, option (a)), the shipped
summarizers are deleted rather than ported to Lua, and the requirement is
withdrawn so the spec stops promising them.

## What Changes

- **REMOVED** from `project-summarizers`: the three requirements that mandate
  the shipped summarizers. These are "Summarizers MUST parse manifest files
  deterministically", "Summarizers MUST output structured, consistent data"
  and "Summarizers MUST be embeddable as shell scripts".
- **KEPT** in `project-summarizers`: "README dispatcher orchestrates all
  summarizers". The glob dispatcher in `scripts/regenerate-readme.sh` still
  runs any drop-in summarizer a project or image provides.
- **MODIFIED** in `project-bootstrap-readme`: the "Manifest summarizers
  extract project information" scenario no longer lists summarizers as
  shipped in this repository. It states that none are, and that adding them
  is new work.
- Deleted: `scripts/summarize-{cargo,go-mod,nix,package-json,pubspec,pyproject}.sh`,
  `scripts/test-summarize-pubspec.sh` and `litmus:project-summarizers-shape`,
  together with their binding and portability-floor rows.

## Impact

- No runtime behaviour changes: nothing invoked these scripts.
- If the forge later wants manifest summarizers, that is a new packet,
  implemented in Rust (coordinator ruling). It is not a revert of this
  change.
- This lands as its own PR, separate from the shell-to-lua batches, so it can
  be reverted alone.
