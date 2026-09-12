# Finding — land-merges-trunk ARM 3 reds on forge hosts with a global hooksPath — 2026-09-12

- **Classification**: bug (environmental, fixture harness)
- **Status**: completed (fix committed in this cycle)
- **Finder**: `forge-tillandsias-opencode-20260912t040719z`
- **Host**: `forge-tillandsias`
- **Component**: `scripts/test-land-merges-trunk.sh` (fixture, order 1064-r8fv)
- **Trace**: order:1064-r8fv, order:1064-r8fv's land-on-platform-branch.sh
  fixture arm 3

## Symptom

`./build.sh --check` gate on the forge host RED at `violation:land-merges-trunk:2
arm(s) failed`:

```
FAIL arm3-refuses-rather-than-claiming-success: expected [6] got [0]
FAIL arm3-names-the-relay-lane: expected [yes] got [no]
```

Reproduced deterministically: `bash scripts/test-land-merges-trunk.sh` →
`PASS: 6 FAIL: 2`, rc 1. ARM 3 relies on the fixture bare `origin`'s
`hooks/pre-receive` rejecting a push; the tool must refuse with rc 6 and name
the `refs/heads/work/` relay lane.

## Root cause — NOT a regression in land-on-platform-branch.sh

The `land-on-platform-branch.sh` logic is sound; ARM 1 and ARM 2 pass. The
fixture's rejection never happens on forge hosts because the forge sets
`core.hooksPath` GLOBALLY (measured: `~/.gitconfig` →
`/home/forge/.cache/tillandsias/git-hooks`). A global hooksPath REPLACES every
repo's local `hooks/` dir for the entire host — git simply never consults the
bare origin's `hooks/pre-receive`. The refused push SUCCEEDS (rc 0), so the
tool has nothing to refuse about and correctly says nothing about a lane: the
fixture misreports a tool that never saw the refusal.

This is the same interference `core.hooksPath` causes for other hermetic
fixtures on forge hosts; sibling fixtures (test-gate-stamp-scope.sh,
test-check-credential-channel.sh, test-sync-image-cheatsheets-for-commit.sh,
test-closure-evidence-survives-landing.sh) already carry the carve-out
`git config core.hooksPath .git/hooks` (repo-local override). This fixture is
the one that lacked it.

## Fix (committed this cycle)

`build_origin()` in `scripts/test-land-merges-trunk.sh` now configures the
bare origin with `git -C "$w/origin" config core.hooksPath hooks` (relative to
the bare repo root), so its local `hooks/pre-receive` fires again. On hosts
with no global override this is a harmless restatement of the git default.

Verified green after the fix: `PASS: 8 FAIL: 0`, `ok:land-merges-trunk:8
arm(s)`.

## Why the fixture's own comment invited this

The header's "NO NETWORK AND NO REAL GATE" promised hermiticity for the refs,
but hermiticity for HOOKS was assumed, not enforced. The fixture runs on
whatever git config the host carries; the fix makes the fixture hermetic about
hooks the way it already was about refs.