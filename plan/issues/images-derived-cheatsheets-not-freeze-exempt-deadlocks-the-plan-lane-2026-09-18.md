# images/default/cheatsheets/ is not freeze-exempt, and that deadlocks the plan-only lane

- filed: 2026-09-18
- host: lenovinha-silverblue
- trace: order:1238-u84w, order:1253-nmmy
- requested by: macuahuitl-fedora, during the 2026-09-18 trunk-red incident

## The rule today

`scripts/hooks/pre-push-local-gate.sh`:

```sh
_freeze_path_is_exempt() { # <path> -> 0 when a freeze does not hold it
    case "$1" in
        plan/*|docs/*|skills/*|cheatsheets/*) return 0 ;;
        *) return 1 ;;
    esac
}
```

`images/default/cheatsheets/` is DERIVED from `cheatsheets/` by
`scripts/stage-image-cheatsheets.sh`. It is not authored. But it does not match
the exempt set, so under a freeze it counts as CODE.

## Four locks from one commit, measured on 2026-09-18

This is not hypothetical; it is the sequence that blocked every hooked host for
roughly an hour while linux-next was frozen.

1. An authored cheatsheet lands WITHOUT its derived copy. (A host pushing
   without hooks, or any path that skips the stager, is enough.) Three entries
   were missing on trunk: `architecture/cpu-only-model-tier-ladder.md` and
   `runtime/silverblue-updates.md` as INDEX.md rows, and
   `tooling/recursive-grep-symlinks.md` whose derived copy was never tracked.
2. Every hooked host is now refused on EVERY push, `cheatsheet-image-sync:drift
   derived-tree-index-stale` — INCLUDING plan-only pushes. The plan lane is
   explicitly the lane that is supposed to keep coordination moving during a cut.
3. The remedy the hook itself prints —
   `scripts/stage-image-cheatsheets.sh --stage && git add -f images/default/cheatsheets`
   — puts `images/` in the push, which the freeze then refuses as code.
4. With `images/` in the push the full gate is required, and on that day the
   gate was red for a completely unrelated reason (`51db2c14c`, the skills
   single-source guard). So the escape from lock 3 was closed too.

Reproduced on a pristine detached worktree at the trunk tip with no local
state, so it was every host's refusal and not one checkout's.

The only lane that still worked was `scripts/salvage-dirty-worktree.sh`, which
the hook exempts by design (872-c9nd). Note that the `work/<order>` lane does
NOT help here: it is the GATED hand-off and demands a stamp, and it inherits
the stale derived tree from its base like any other ref.

## What should change

Add the derived cheatsheet tree — `images/default/cheatsheets/` specifically,
NOT all of `images/` — to `_freeze_path_is_exempt`.

The argument is that the freeze exists to hold CODE during a cut, and this
directory is generated output whose content is already exempt at its source.
Holding the derived copy while exempting the thing it is derived from cannot
protect anything: the two are required to be equal by a guard that runs on
every push.

Scope deliberately narrow. `images/` at large carries real build inputs and
must stay held.

## Exit criteria

- `_freeze_path_is_exempt` returns exempt for `images/default/cheatsheets/*`
  and NOT for other `images/*` paths. Both arms tested; a widening that exempts
  `images/*` wholesale is the failure mode to guard against.
- A test arm reproducing the deadlock: under a live freeze, with the derived
  tree stale, a plan-only push is ADMITTED. Pre-fix it must be REFUSED — a fix
  whose test passes before the fix is not evidence.
- `scripts/test-pre-push-honours-a-live-freeze.sh` still green; its case 3
  (plan-only admitted under a live marker) must not regress.

## What this does NOT fix, stated so nobody reads it as closed

The underlying generator drift — an authored cheatsheet reaching trunk without
its derived copy — is a separate defect. This row only stops that drift from
DEADLOCKING the plan lane during a freeze. Whatever lets step 1 happen is still
open and is worth its own row: a host that can push without the hook can always
re-introduce the drift.
