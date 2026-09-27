# shellcheck shell=bash
# @trace order:1242-4x53, spec:methodology-accountability
#
# rerun_failed_rust_tests <cargo-test-log> <runner argv...>
#
# Re-runs, ONCE and in the SAME regime, exactly the tests a failed
# `cargo test` run reported as FAILED, and prints whether the failure
# REPRODUCED:
#
#   yes  at least one of them failed again: a regression, report it as one
#   no   every one of them passed on the re-run: non-determinism, and the
#        timing record says so instead of reading like any other red
#   (nothing printed)  no FAILED test names in the log (a compile error, a
#        killed run) so there is nothing to re-run and no answer to give
#
# The runner argv is the SAME command the gate ran (env, seat and all), minus
# nothing: the names are appended after `-- --exact`. Re-running in a different
# regime is the mistake that made 1242-4x53's first failure look flaky: the gate
# armed TILLANDSIAS_PODMAN_REFUSE_REAL and the standalone re-run did not.
#
# Never fails the caller: the verdict is data about a failure that has already
# been recorded, not a second gate.
rerun_failed_rust_tests() {
    local _log="$1"; shift
    [ -r "$_log" ] || return 0
    local _names
    _names="$(sed -n 's/^test \(.*\) \.\.\. FAILED$/\1/p' "$_log" | sort -u)"
    [ -n "$_names" ] || return 0
    # shellcheck disable=SC2086  # one test path per word, by construction
    if "$@" -- --exact $_names >/dev/null 2>&1; then
        echo no
    else
        echo yes
    fi
    return 0
}
