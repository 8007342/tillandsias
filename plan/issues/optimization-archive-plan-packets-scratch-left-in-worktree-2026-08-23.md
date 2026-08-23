# optimization: archive-plan-packets.sh leaves plan_tmp/ scratch in the worktree after a green gate

- Filed: 2026-08-23 (UTC), by windows host **yolanda**. Class: optimization/.
- Related: scripts/archive-plan-packets.sh, scripts/check-archive-answerability.sh,
  meta-orchestration exit contract ("put every disposable diagnostic under
  $boundary_dir/tmp").

Measured this cycle: after `./build.sh --check` completed (both a red run and
a green 23/23 run), the worktree carried untracked `plan_tmp/` (a full
`cp -a plan/` copy, source mtimes preserved) plus `plan_tmp_addressed.txt`
and `plan_tmp_addressed_raw.txt`. `scripts/archive-plan-packets.sh` creates
all three and its abort paths `rm -rf` them, but at least one exit path taken
under `--check` on this host does not. `check-archive-answerability.sh`
already `--exclude=./plan_tmp`s its own grep, i.e. the leak is known enough
to be worked around rather than fixed.

Why it matters more than litter: on a boundary-guarded host every green gate
run ends the cycle DIRTY, so each meta-orchestration cycle must hand-remove
tool scratch before it can satisfy its own exit contract — and an unattended
cycle that doesn't will either fail its boundary verify or commit a 4MB copy
of plan/ by accident. Scratch belongs outside the worktree (mktemp), or at
minimum on every exit path of the script that made it.

Smallest next action: give archive-plan-packets.sh a trap-based cleanup (or
move its workspace to mktemp -d), and drop the now-unneeded exclude.
