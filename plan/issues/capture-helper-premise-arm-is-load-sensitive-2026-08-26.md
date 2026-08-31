# `test-capture-helper.sh`'s premise arm is a race, and it reds the trunk's only gate under load

- Date: 2026-08-26
- Host: calmecacpilli, `linux_immutable`, `linux-next`
- Class: `optimization` (flaky gate arm)
- Relates to: order 899-6pwv, commit `442adf05f`
- Owner: unassigned (author of 899-6pwv has the context)

## What happened

`./build.sh --check` failed on this host with:

    FAIL: the tee|head idiom no longer truncates — capture.sh's premise needs
          rechecking on this platform
    capture-helper: 9 passed, 1 failed
    capture.sh regressed — evidence files can be silently truncated by the
    excerpt that displays them

The change under test was a markdown edit to a `plan/issues/` file, which cannot
affect this. Re-run standalone immediately afterwards: **10 passed, 0 failed.**
Re-run inside the `tillandsias-builder` toolbox (where the gate actually
executes): **10 passed, 0 failed.** So it is neither the change, nor
host-versus-container.

## Measured: it is load-sensitive, and reproducibly so

    12 consecutive runs, idle host ............ 0 failures
     8 consecutive runs, 4 CPU spinners ....... 3 failures

Same binary, same tree, same container, one variable. The failing arm is the
same one every time.

## Why it fails

The arm asserts that the `tee | head` idiom truncates — that is `capture.sh`'s
stated premise, and the arm exists to detect the premise silently ceasing to
hold. Truncation there depends on `head` exiting and the writer then taking
`SIGPIPE`. **Under load the producer can finish writing before `head` exits, so
no `SIGPIPE` is delivered, nothing truncates, and the arm concludes the premise
is broken.** The premise is fine; the arm is racing.

This matters beyond one flaky test: **the arm is wired into `./build.sh
--check`, which is the trunk's only remaining gate.** A loaded host therefore
reds the gate at random and cannot push, with a verdict that points at a
platform regression. Any host running a parallel build, a smoke test, or
several agents is in the failure regime.

## The verdict names the wrong layer

`"needs rechecking on this platform"` states a *platform property*. The
measurement says it is a *timing race*. A reader following that verdict goes to
check coreutils behaviour on their distro — and will find, correctly, that the
idiom works fine, which makes the verdict look like a mystery rather than a
race.

This is the fourth instance this week of a signal attributing a failure to the
layer it observed rather than the layer that failed (gh naming the keyring when
GitHub had rejected the token; the lane fixture naming the lane when the base
was unfoldable; a stale spawn comment naming the wrong process). It is worth
noting that the pattern recurs inside *diagnostic* code specifically.

## Smallest next action

Not fixed here — this is the 899-6pwv author's code and the right fix depends on
what they intended the arm to guarantee. Two candidates:

1. Make the arm deterministic rather than timed: force the producer to outlive
   the consumer (e.g. a writer that blocks until the reader has exited) so
   `SIGPIPE` delivery is not a function of scheduler luck.
2. If the premise genuinely cannot be checked without a race, the arm should not
   gate the trunk — demote it to advisory and report, rather than refusing.

Do NOT simply retry the arm on failure. A retry loop around a race hides the
regime rather than removing it, and the arm's whole purpose is to notice a
premise quietly ceasing to hold.
