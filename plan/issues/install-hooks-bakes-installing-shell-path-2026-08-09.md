# Generated git hooks baked the installing shell's absolute path (order 632-retq)

- Date: 2026-08-09
- Host: windows (windows-next)
- Class: `optimization/` — blocked every commit and push from the Windows shell
- Status: fixed in this commit, pinned by a new litmus

## What happened

The first `git commit` of the cycle died:

```
bash: /mnt/c/Users/bullo/claudia/tillandsias/scripts/hooks/pre-commit-openspec.sh: No such file or directory
bash: /mnt/c/Users/bullo/claudia/tillandsias/scripts/hooks/pre-push-version-guard.sh: No such file or directory
error: failed to push some refs
```

`scripts/install-hooks.sh` interpolated `$REPO_ROOT` — the path as the
*installing* shell saw it — into each generated hook body. The hooks had been
installed from the WSL side, where the checkout is `/mnt/c/Users/...`. Git Bash
addresses the same bytes on disk as `/c/Users/...`, so every hook pointed at a
path that does not exist in the shell actually running git.

One checkout, two true paths. The installer assumed there was one.

## Why it was worse than a broken hook

The meta-orchestration exit contract requires that every meaningful result be
committed and pushed before exit — local state is treated as volatile. A hook
that cannot run means no commit, which means no push, which means the cycle's
entire output is stranded in a worktree the contract assumes will be lost. The
failure surfaced *after* the work was done, at the one step that makes work
durable.

The same trap fires for a moved or renamed checkout, and for a container that
mounts the repo under a different prefix — WSL just made it reproducible.

## Fix

Hook bodies now resolve the root at **run** time instead of install time:

```bash
HOOK_ROOT="$(git rev-parse --show-toplevel)" || exit 1
bash "$HOOK_ROOT/scripts/hooks/pre-commit-openspec.sh"
```

Git runs hooks with the working directory at the top level, and `--show-toplevel`
answers in whatever path vocabulary the *current* shell speaks. One subprocess,
correct under every view of the checkout, no host path baked in anywhere.

All three markers are bumped so existing broken hooks are replaced rather than
skipped as "already installed" — `openspec-pre-commit-hook-v2`,
`tillandsias-pre-push-v4`, `dashboard-refresh-hook-v2`. Idempotency was the
reason the bug persisted: a re-run of the installer reported success and changed
nothing. The two non-marker hook branches now also refuse to append to an
unrecognized hook instead of silently concatenating.

## Pinned by

`openspec/litmus-tests/litmus-hook-install-portability-shape.yaml` — asserts no
generated hook invokes an absolute path, that each resolves the root at run time,
that installation is idempotent, and that every delegate script exists.

The assertion is deliberately **structural, not behavioural**. A test asking
"does `git commit` work here?" passes on the machine that installed the hooks —
which is exactly the machine where the bug is invisible. The defect is the baked
path itself, regardless of whether it happens to resolve locally.
