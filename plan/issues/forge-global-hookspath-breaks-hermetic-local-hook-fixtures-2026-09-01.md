# Forge global `core.hooksPath` breaks hermetic local-hook fixtures

Order: 953-e4fb
Found: 2026-09-01 (forge cycle, linux-next @ ddb7a9e81)
Kind: bug
Priority: p2
Capability tags: forge, litmus, fail-loud, shell
Pickup role: any (observable in the forge; physics reproduced on linux)

## Finding

`./build.sh --check` fails the `test-pre-push-empty-ref-list` fixture in the
forge on an otherwise-clean tree — reproduced identically on the pristine base
HEAD `983d0b3b7` (my `lib-common.sh` change did not cause it). The fixture
reports `6 passed, 5 failed`; the five failures all come from `refbytes()`
returning `<none>`, i.e. the spy pre-push hook's `REFBYTES=` line never appears
in the push output.

## Root cause

The forge image installs an agent commit-attribution hook via a **global**
`core.hooksPath`:

- `images/default/lib-common.sh:367`
  `git config --global core.hooksPath "$hooks_dir"` (in `install_agent_hooks`)
- points at `~/.cache/tillandsias/git-hooks`, and `~/.gitconfig` is effectively
  read-only in the forge (writes return `Device or resource busy`).

Git's `core.hooksPath` **replaces** per-repository `.git/hooks/` entirely. When a
hermetic fixture such as `scripts/test-pre-push-empty-ref-list.sh` installs a
local spy at `$W/wc/.git/hooks/pre-push`, that hook is silently never executed,
because git consults the global hooksPath directory instead. The measurement arm
(`refbytes`, which greps the push output for `^REFBYTES=`) therefore returns
nothing, and arms 1–5 fail.

## Reproduction (hermetic, no network)

```bash
# In the forge (or any host whose global core.hooksPath is set):
TILLANDSIAS_SKIP_VERSION_BUMP=1 ./scripts/test-pre-push-empty-ref-list.sh
# -> "6 passed, 5 failed"; arms 1-5 fail with 'got <none>'

# Control: isolate HOME so no global hooksPath is read -> fixture passes 11/11:
TMPHOME=$(mktemp -d)
HOME="$TMPHOME" TILLANDSIAS_SKIP_VERSION_BUMP=1 ./scripts/test-pre-push-empty-ref-list.sh
# -> "11 passed, 0 failed"
```

## Why it matters

- Every forge cycle on a host with this global hooksPath reports a red
  `./build.sh --check`, which the meta-orchestration Finalization requires
  green before any push. It also misleads: the fixture's guard logic (arms 6–9)
  is correct, but the red verdict looks like a regression.
- It is a `fail-loud` defect: the emissive layer of the forge (global hooks) is
  invisible to the hermetic fixtures that assume per-repo hooks, and the only
  signal is 5 phantom test failures.
- The pattern generalizes: any fixture or check that relies on a repository-local
  pre-push/pre-commit hook will silently not run in a host with a global
  `core.hooksPath`.

## Suggested remediation (smallest slice)

In the forge, either:
- expose the global hooksPath such that fixtures can override it (e.g. set it
  per-invocation from `GIT_CONFIG_GLOBAL`, or make the forge skip the
  commit-attribution global hook and scope attribution to the checkout only);
- or teach `test-pre-push-empty-ref-list.sh` (and siblings that install local
  spies) to `git config --local core.hooksPath` / run with an isolated
  `GIT_CONFIG_GLOBAL` so the local spy is honored.

Whichever way, the fact must be made observable: a forge whose fixtures cannot
depend on local hooks should detect the global `core.hooksPath` and either
accommodate it or fail loudly with a named reason rather than reporting five
phantom `FAIL` lines.
