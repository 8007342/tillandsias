# Sweep: fixtures that ran a Lua script outside any repository (2213-ag5u)

Host: lenovinha, 2026-11-22. Coordinator: macuahuitl-fedora asked for each
fixture that runs a Lua port in a scratch dir to be recorded as clean or fixed.

## The defect

Before 2213-ag5u, `tillandsias-plan script run` started from a cwd outside any
repository, on a script outside any repository, rooted the script at the
RUNNER BINARY's own checkout (the `current_exe` walk in `locate_repo_root`).
`fs.*`, `proc.run`'s default cwd and anything the script resolved then measured
the real tree, silently. Found when `scripts/test-plan-binary-runnability-precondition.sh`
reported the issue-capture port 27/27 with the base folding, where its dead ELF
should have made it skip (2212-2m8s, PR #1323).

After 2213-ag5u such a run refuses: `could-not-run:script-run:no-repository-root`,
exit 3, before any script code runs. A `--helper` still runs (the forge's ported
`lib-*.sh` bodies live under `/usr/local/lib` and need no repository).

## Method

The fallback fires only when BOTH the cwd and the script are outside every
repository. A fixture whose script stays in the checkout roots at the checkout
(now explicitly: the script's repository), and a Lua fixture whose scratch is
under `target/plan-scratch` is inside the checkout by construction.

1. Population: every `scripts/test-*.sh` and `scripts/lua/test-*.lua` naming
   `script run` and a temp directory (193 files).
2. Narrowed to the risky shape: a fixture that creates a `mktemp` tree AND
   copies a `.lua` into it (9 files).
3. Ran each of the 9 with the 2213-ag5u runner as the only resolvable plan
   binary and grepped its output for the new refusal token. A fixture still
   leaning on the fallback would now print it.

## Dispositions

| Fixture | rc | Refusal printed | Disposition |
|---|---|---|---|
| `scripts/test-centicolon-ratchet.sh` | 0 | no | clean |
| `scripts/test-check-installer-prompts.sh` | 0 | no | clean |
| `scripts/test-closure-evidence-survives-landing.sh` | 0 | no | clean (ported in 2208-vxb6, PR #1321) |
| `scripts/test-discipline-install-hooks.sh` | 0 | no | clean |
| `scripts/test-dispatch-reap.sh` | 0 | no | clean |
| `scripts/test-litmus-diff-scope.sh` | 0 | no | clean |
| `scripts/test-pilot-lua-ports.sh` | 0 | no | clean |
| `scripts/test-relay-preflight.sh` | 0 | no | clean |
| `scripts/test-script-run-verb.sh` | 0 | no | clean |
| `scripts/test-plan-binary-runnability-precondition.sh` | — | — | FIXED in 2212-2m8s (PR #1323): `git init` of its scratch checkout |
| every `scripts/lua/test-*.lua` with scratch under `target/plan-scratch` | — | — | clean by construction: the scratch is inside the checkout |

## Not covered

- Litmus commands run from the checkout root, so they are outside this shape.
- The narrowing in step 2 is a text match. A fixture that writes a `.lua` into
  a temp tree in some other way (for example a heredoc through a variable it
  builds) would be missed by it, but not by the runner: it now refuses by name
  at run time instead of passing on the real tree.
