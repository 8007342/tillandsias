## Cycle 2026-08-04T01:50Z (linux_mutable — v0.4.260804.1 release, trial by fire)

Released **v0.4.260804.1**. The release procedure was exercised end to end for
the first time since push CI was removed, and it broke in four places — none of
which were visible from reading the code.

**Both sibling hosts drained their bundles.** Windows (598-yhu5): six verdicts,
one staging defect fixed. macOS (598-kibt): M1-M5 evidence, 8 accel_probe lints
Linux could not enumerate, 11 macos-tray lints, `cloud_projects_loaded` wired
(the M5 empty-repo bug), a 13-failure litmus truth sweep, and 600-c266 filed.
Tray-parity is now **0 gaps on required rows across all three platforms**.

**macOS found a real bug in my gate-stamp, and it was worse than reported.**
`xargs ... 2>/dev/null` swallowed "Is a directory" for all 45 tracked directory
symlinks, so the stamp did not fail — it hashed a tree with 45 entries missing
and called it validated. My fixture used regular files only. Both hosts fixed it
independently; kept the single-pass version with explicit failures over the
multi-pass one with four suppressed-stderr sites.

**What the release run exposed, in order of appearance:**
- `litmus:local-ci-self-clean-evidence` was UNSATISFIABLE — the convergence
  dashboard embeds a wall-clock stamp and was written unconditionally, so
  `--ci-full` failed on dirt it had just created, forever. Now publishes only on
  substantive change.
- `--ci-full` (17 checks, 237 litmus) did NOT write the gate stamp; `--check`
  (6 checks) did. Passing more left you less able to push. One helper now.
- The VERSION guard and the release preflight DEADLOCKED: the preflight requires
  linux-next to carry main's post-release VERSION, the guard refused any commit
  touching VERSION there. Only exit was `--no-verify`, at the release, on the
  gate that replaced CI. Guard now names sync-forward and the bump branch.
- The release SKILL still said "wait for CI". `gh pr checks --watch` exits **0**
  on "no checks reported" — so it would have merged unverified while reading as
  a passing gate. Corrected an earlier claim of mine that it would refuse.

**Answer to "is the methodology up to date?"** It was not. It is now: step 3 of
`merge-to-main-and-release` gates on `./build.sh --ci-full` +
`scripts/release-preflight.sh`, `--auto` is dropped (it waits forever on a check
that never reports), and step 4's claims about required contexts are corrected.

**Filed:** 601-f6ci, 601-462g, 602-tfzg, 602-68gf (all Linux, closed except the
runbook audit), 603-wdu7 + 603-jn5m for Windows and macOS.

**Open:** the release build is still running; a Nix cache miss is expected now
that nix-cache-warm is gone. `600-c266` (append-event blind to fragment packets)
is real and unclaimed.
