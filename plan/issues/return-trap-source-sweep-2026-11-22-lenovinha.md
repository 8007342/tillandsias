# Sweep: RETURN traps fired by a sourced file (2228-vt2z)

@trace order:2228-vt2z

Filed on the coordinator's direction after 2227-rqgw. In that bug, local-ci.sh's
`write_convergence_artifacts` set `trap 'rm -f …' RETURN`, then sourced
`plan-binary-probe.sh`. The trap fired when the sourced file finished, deleted
the residual-reasons file mid-function, and `top_residual_reasons` was `[]` on
every run since 977-j6qu.

## What fires a RETURN trap (measured, GNU bash 5.3.15, 2026-11-22)

A probe set a RETURN trap in a function and tried each shape:

| Shape | Fires? |
|---|---|
| A. `. file` inside the function, after the trap | **yes, early**, then again at the function's own return (the 2227 bug) |
| B. the function calls another function that sources | no (functions do not inherit RETURN traps without `functrace`) |
| C. the trap is never cleared, then a **top-level** `. file` after the function returned | **yes**: the trap outlives its function |
| D. `$(…)` of a sourcing function inside | no |
| E. a leaked trap (as in C), then a function that sources | no |

C is the dangerous one. The trap body then runs after the function's locals
are gone. Under `set -u`, `"$local_name"` becomes `unbound variable`, and a
non-interactive shell exits: a `set -euo pipefail` probe stopped with rc=1. The same class
aborted build.sh once already: 2026-08-16, recorded in the comment in
`scripts/with-tillandsias-builder.sh`.

So for each site, the questions were: does the function source a file after
setting the trap (A)? Can it return without clearing the trap (C)? If it can,
does its file then source anything at top level, or is the file itself
sourced by something else?

## Every site (`git grep -n "trap .*RETURN" -- '*.sh'`, 15 lines, 9 files)

| Site | A: sources after the trap | C: can leave the trap set | Then a top-level source? | Verdict |
|---|---|---|---|---|
| `scripts/local-ci.sh` `write_convergence_artifacts` (two traps) | **yes** (`. plan-binary-probe.sh`) | no | n/a | **2227-rqgw**. The function is ported to Lua in #1346 (2224-x32n), which removes the trap. #1347 fixes the empty list. |
| `build.sh` `ensure_dev_cache` | no | **yes**: the openssl-failure branch did `return 0` before `trap - RETURN` | not today. The only later source is inside `_gs_one`, a function (shape E). | **Latent, fixed here.** The early return now does `rmdir` + `trap - RETURN`. Red-first fixture: `scripts/lua/test-build-dev-cache-ca-trap-cleared.lua` (`litmus:build-dev-cache-ca-trap-cleared`). Before the fix it failed with `ca_lock: unbound variable`. |
| `images/default/codex-oauth-vault.sh` `restore_auth` | no | yes (`return 2`, `return 3`) | no: the file sources nothing, and nothing sources it (it is executed) | harmless |
| `images/default/provider-oauth-vault.sh` `restore_auth` | no | yes (`return 2`, `return 3`) | no: same as above | harmless |
| `scripts/check-deslop-sweep-health.sh` `_self_test` | no | yes (never cleared) | no: sources nothing, executed | harmless |
| `scripts/generate-repo-key.sh` `mode_deploy` | no | yes (never cleared) | no: sources nothing, executed | harmless |
| `scripts/mo-full-attest.sh` `fixture` | no | yes (never cleared) | no: its one source (`agent-identity.sh`) runs at the top, before `fixture` | harmless |
| `scripts/test-mirror-receive-wrapper.sh` `mode_vars_exported`, `mode_refusals` | no | yes (never cleared) | no: sources nothing, executed | harmless |
| `scripts/with-tillandsias-builder.sh`, `scripts/with-wsl2-builder.sh` (the `_tb_restore_caller_opts` note) | n/a | n/a | n/a | comments that record why these scripts do **not** use a RETURN trap |

There are no RETURN traps in non-`.sh` shell files. The one other match,
`openspec/litmus-tests/litmus-wsl2-builder-shell-options-shape.yaml`, is a
comment.

## Not done

There is no decider for the shape. One harmful hit (A) and one latent one (C)
in 15 lines does not yet justify a guard. A guard would have to follow
control flow (early returns, and whether a file is sourced) to be right,
because a grep for "trap RETURN without `trap - RETURN`" would flag the five
harmless sites. If the shape comes back, the decider is the follow-up this
row's `unscoreable` line names.
