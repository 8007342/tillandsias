#!/usr/bin/env bash
# @trace spec:init-command, spec:cli-diagnostics
#
# test-spawn-failure-names-program.sh — ORDER 1277-g5k9.
#
# WHAT THIS PINS. "Failed to spawn build process: program not found" named
# neither the program nor the PATH it searched, so the operator's transcript on
# esme (v56.9.19.2) carried EIGHT identical lines for ONE absent podman, and a
# summary naming eight images and no program. One cause read as eight.
#
# TWO ARMS, matching this row's closure:
#   arm 1 — the spawn failure names the program and where it looked, AND a
#           non-NotFound failure keeps its original wording (the negative
#           control: a build that spawns and then fails is unchanged).
#   arm 2 — the collapse is STRICT: only a real spawn miss is collapsible, so a
#           build's own stderr cannot be swallowed and the per-image list, which
#           is the information in a mixed run, survives.
#
# WHY THIS DELEGATES TO THE UNIT TESTS rather than driving the binary. The
# condition is "the executable is absent", and arranging that end-to-end means
# either removing podman from the host or shipping a PATH sandbox the build lane
# does not support. The two facts that were dropped — io::ErrorKind::NotFound
# and the command's program name — are both at the mapping, so the mapping is
# where they are asserted. An end-to-end arm would test the harness more than
# the fix.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:spawn-failure-names-program:[0-9]+/2|violation:spawn-failure-names-program:[0-9]+/2|skip:no-cargo)$
# Exit 0 on the ok and on the skip; 1 on a violation.
#
# `skip:no-cargo` is NOT a pass dressed up as one — a caller that wants
# enforcement should treat it as "install a toolchain and re-run".

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

if ! command -v cargo >/dev/null 2>&1; then
    echo "skip:no-cargo"
    exit 0
fi

ARM1="a_spawn_failure_names_the_program_and_the_path"
ARM2="only_a_real_spawn_miss_is_collapsible"

passed=0
for arm in "$ARM1" "$ARM2"; do
    # --exact so a rename of the test cannot silently reduce the arm count by
    # matching nothing while still exiting 0.
    if out="$(cargo test -p tillandsias-headless --offline --bin tillandsias \
                 -- --exact "tests::$arm" 2>&1)"; then
        if printf '%s' "$out" | grep -qE "test result: ok\. 1 passed"; then
            passed=$((passed + 1))
        else
            echo "arm '$arm' did not run (no single passing test matched)" >&2
            printf '%s\n' "$out" | tail -5 >&2
        fi
    else
        echo "arm '$arm' FAILED" >&2
        printf '%s\n' "$out" | tail -20 >&2
    fi
done

if [ "$passed" -eq 2 ]; then
    echo "ok:spawn-failure-names-program:2/2"
    exit 0
fi

echo "violation:spawn-failure-names-program:$passed/2"
exit 1
