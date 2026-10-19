# Design — observatorium-deploy-on-stable

Packet: `1798-khw6`. Code is cited by symbol or script name.

## Context

- Workers Builds triggers on branch pushes, filtered by branch name and by
  build watch paths. It cannot watch a tag, and stable promotion
  (`scripts/promote-stable.sh`) moves the annotated `stable` tag.
- The observatorium spec chose no GitHub Actions and no Cloudflare credential
  in GitHub (req `ecefcdde`). A Cloudflare API call from the promote script
  would need a token that can start builds on the promoting host. The tray's
  Cloudflare sign-in is read-only.
- The enclave git mirror's pre-receive rejects deletions and any
  `refs/heads/*` update whose old tip is not an ancestor of the new one.
- `pre-push-local-gate.sh` exempts a tag push from the gate stamp only when
  the tag's commit is already on `origin/main` (1768-2k56). Any other branch
  push needs a fresh `./build.sh --check` stamp.

## Decisions

### A deploy branch, written only by promotion

`refs/heads/deploy/observatorium` is the Worker's production branch. Cloudflare
builds when it moves, and only promotion moves it. No credential is added
anywhere. Each Worker that should follow the stable channel can get its own
`deploy/<name>` ref, and the hook exemption is written for `deploy/*`.

Watch paths stay at `*`. Every promotion should deploy, whatever the
promotion changed. The build reads `openspec/`, `plan/` and git history, not
just `observatorium/`.

### Forward-only, by restore commit

| Case | Push |
|---|---|
| ref absent (first seeding) | the release commit |
| old tip is an ancestor of the release | the release commit (fast-forward) |
| old tip already carries the release's tree | nothing (no build of identical bytes) |
| otherwise (demotion, older release) | `commit-tree <release>^{tree} -p <release> -p <old>` |

The release is the restore commit's FIRST parent, so the deployed history's
first-parent line is the release's. Verification compares trees on origin,
not shas, because a restore commit's sha is new.

### The gate exemption is judged by tree

A restore commit is exempt only when `tip^{tree} == tip^1^{tree}` and `tip^1`
is an ancestor of freshly fetched `main`. A child of `main` with a new tree
keeps the full gate (fixture case 16).

### Half-promotion is loud

Step 4 runs after the stable tag is verified. If it fails, the GitHub release
and the tag are already stable, so the script prints `HALF-PROMOTED`, the
remedy (`scripts/advance-deploy-ref.sh <commit> --label <tag>`), and a
`refused:deploy-ref-*` last line, and exits 1. That follows the 1768-2k56
stable-tag precedent.

## Risks

- `ref_grammar` is at `warn`, so `deploy/observatorium` prints a grammar
  warning on push. If the level ever goes to `enforced`, the seed needs a
  deploy-ref class.
- Workers Builds always builds a push of 20 or more commits, so a large jump
  still builds once. That is wanted here.
