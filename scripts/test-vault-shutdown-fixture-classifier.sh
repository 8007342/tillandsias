#!/usr/bin/env bash
# @trace order:1140-i6ct, spec:tillandsias-vault
#
# The guard 1140-i6ct's `unscoreable: unpinnable-until-the-guard-exists` was
# waiting on. HERMETIC: sources the classifier out of
# scripts/test-vault-shutdown-forwards-sigterm.sh and drives it with injected
# values. No podman, no container, no clock — so it is safe to wire into the
# gate, which the live fixture is not and must not be.
#
# WHAT IT EXISTS TO PREVENT, in yoga's words on the row: "a vintage check that
# short-circuits the measurement would make the fixture unable to fail at all,
# which is worse than the defect it fixes". Arm 3 below is that negative
# control, and it is the reason this file is not optional — every other arm
# could pass with a classifier that returns 4 unconditionally.
#
# Exit: 0 all arms pass | 1 an arm failed | 3 the classifier could not be loaded
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

FIXTURE="scripts/test-vault-shutdown-forwards-sigterm.sh"
[ -r "$FIXTURE" ] || { echo "could-not-run:no-fixture:$FIXTURE (1140-i6ct)"; exit 3; }

# The LIB guard is what makes this hermetic. If it ever stops working the
# source below runs the live fixture, so assert the function arrived and
# nothing else did.
TILLANDSIAS_VAULT_FIXTURE_LIB=1 . "$FIXTURE" || {
    echo "could-not-run:fixture-would-not-source (1140-i6ct)"; exit 3; }
command -v vault_shutdown_classify >/dev/null 2>&1 || {
    echo "could-not-run:classifier-absent — the LIB guard sourced nothing usable (1140-i6ct)"
    exit 3; }

pass=0; fail=0
arm() {  # arm <name> <want-rc> <want-substring> <elapsed> <budget> <exit_code> <entrypoint>
    local name="$1" want_rc="$2" want_txt="$3"; shift 3
    local out rc
    out="$(vault_shutdown_classify "$@" 2>&1)"; rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        echo "  bad  $name: rc=$rc, want $want_rc"; echo "       $out"; fail=$((fail + 1)); return
    fi
    case "$out" in
        *"$want_txt"*) echo "  ok   $name (rc=$rc)"; pass=$((pass + 1)) ;;
        *) echo "  bad  $name: rc correct but the verdict does not say why"
           echo "       want substring: $want_txt"; echo "       got: $out"; fail=$((fail + 1)) ;;
    esac
}

echo "vault-shutdown classifier — four outcomes, four exit codes (1140-i6ct)"

# ARM 1: the green. 1s against a 15s budget, exit 0, this tree's entrypoint.
arm "green/match -> 0"          0 "SIGTERM is forwarded"        1 15 0 match

# ARM 2: 1134-u934 as it was actually measured — the full grace and a SIGKILL.
#        THIS TREE's entrypoint, so the source IS indicted.
arm "stall+137/match -> FAIL"   1 "1134-u934 defect"           30 15 137 match

# ARM 3: THE NEGATIVE CONTROL. Same red as arm 2, same entrypoint verdict.
#        A classifier that consulted vintage FIRST, or that treated any red as
#        a stale image, returns 4 here — and the fixture could then never fail.
#
#        DO NOT DELETE THIS AS A DUPLICATE OF ARM 2. It is written to look like
#        one, and that is the point (yoga, 1140-i6ct): the wrong fix it catches
#        — check the image vintage BEFORE measuring — passes every other arm in
#        this file, and it is attractive because it reads as an optimisation
#        rather than as a bug. An arm whose only job is to fail for the
#        seductive wrong answer is exactly the arm a cold reader deletes as
#        redundant. Arm 2 asserts the verdict; arm 3 asserts the verdict is
#        still REACHABLE. Losing it costs nothing visible and silently makes
#        the live fixture unable to fail at all.
arm "regression still fails"    1 "FAIL:"                      30 15 137 match

# ARM 4: yoga's case. Red, but the container is not running this tree's
#        entrypoint: the host is behind, the source is not indicted.
arm "stall+137/differs -> 4"    4 "stale-image"                30 15 137 differs

# ARM 5: red and unattributable. 965-sxec — no verdict about a thing the check
#        could not evaluate. Distinct from 4 so the two never blur.
arm "stall+137/unknown -> 3"    3 "cannot-attribute"           30 15 137 unknown

# ARM 6: a green on a stale image is STILL a green — but it passes the image,
#        not the checkout, and must say so rather than claiming the tree.
arm "green/differs -> 0, noted" 0 "passes the IMAGE"            1 15 0 differs

# ARM 7: the exit-code half alone. Fast stop, non-zero status — a container
#        that exits quickly for a bad reason must not read as a pass.
arm "fast but non-zero -> FAIL" 1 "ExitCode 1"                  1 15 1 match

# ARM 8: the elapsed half alone. Exit 0, but it burned the grace to get there.
arm "slow but zero -> FAIL"     1 "did not reach"              30 15 0 match

echo "vault-shutdown-fixture-classifier: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
    echo "fail:vault-shutdown-fixture-classifier:$fail"
    exit 1
fi
echo "ok:vault-shutdown-fixture-classifier:$pass"
