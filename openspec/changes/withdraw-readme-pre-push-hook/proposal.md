## Why

`spec:project-bootstrap-readme` requires a git pre-push hook that
regenerates the README. It names `scripts/install-readme-pre-push-hook.sh`
as the hook and says the forge image ships it (archived change
`project-bootstrap-readme-applied-2026-04-27`: "The forge image SHALL ship
`scripts/install-readme-pre-push-hook.sh` at `/usr/local/bin/`"). That was
never wired. Evidence on linux-next, 2026-11-20 (order 2118-kaeq):

- `git grep -n 'install-readme-pre-push-hook' -- images skills crates .claude`
  finds no Containerfile `COPY`, no skill, and no crate reference. The single
  `images/` hit is the derived cheatsheet copy
  (`images/default/cheatsheets/welcome/readme-discipline.md`), which is
  prose.
- Outside `plan/` and the archive, the only references are that cheatsheet
  (both copies) and the two scenarios of the requirement withdrawn here.
- Nothing calls the script. The repository's real pre-push hook is
  `scripts/hooks/pre-push-local-gate.sh`, installed by `scripts/install-hooks.sh`,
  and it does not regenerate READMEs.

This follows the coordinator's summarizer rule (macuahuitl-fedora,
2026-11-20; precedent `withdraw-shipped-project-summarizers`, order
2114-sdj6): code that a spec names but nothing wires is withdrawn, not
ported.

## What Changes

- **REMOVED** from `project-bootstrap-readme`: "Pre-push hook auto-regenerates
  README".
- Deleted: `scripts/install-readme-pre-push-hook.sh`.
- The readme-discipline cheatsheet stops listing the hook as a regeneration
  trigger. The `/bootstrap-readme` skill and `regen-trigger` lines remain.

## Impact

- No runtime behaviour changes: no image, skill or hook installs it.
- If automatic README regeneration on push is wanted later, it is a new
  packet wired into the real hook chain (`scripts/install-hooks.sh`). It is
  not a revert of this change.
- This lands as its own PR, separate from the summarizer withdrawal
  (2114-sdj6) and the shell-to-lua batches, so it can be reverted alone.
