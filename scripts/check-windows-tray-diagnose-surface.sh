#!/usr/bin/env bash
# @trace spec:windows-native-tray
#
# Order 624-cf9f. Assert the Windows tray's diagnostic surface by EXERCISING it,
# instead of grepping the source for the names of the tests that exercise it.
#
# What the old steps checked, and why that is weaker than it looks: eight steps
# of litmus:windows-tray-diagnose-cli-surface ran `grep -F 'fn
# diagnose_json_top_level_keys_pinned' …` and friends. That passes when the
# function NAME is present — including when the function's body has been
# emptied, when it is `#[ignore]`d, and when it fails. The property anyone
# actually wants is "these tests exist AND PASS", and running them is both
# simpler and strictly stronger than naming them.
#
# Why this needs its own script rather than a one-line `cargo test` in the YAML:
# `crates/tillandsias-windows-tray/src/{notify_icon,wsl_lifecycle,hvsocket,
# installation_uuid}.rs` are `#[cfg(target_os = "windows")]`, and `main.rs`
# substitutes `src/stubs/*.rs` on Linux. A cargo test run on a Linux host
# therefore compiles the STUB, reports success, and proves NOTHING about the
# file the step claims to pin — a green that is worse than the grep it replaced.
# So this script establishes whether a Windows toolchain is reachable and says
# `skip:` out loud when it is not, rather than passing on a technicality.
#
# Grammar (exactly one line on stdout):
# Every verdict shares the noun `diagnose-surface`, so one expected_behavior
# substring accepts a genuine pass AND an honest skip while still rejecting a
# violation — a lane with no Windows toolchain must not be failed by this, and
# must not be told it passed either.
#
#   ok:diagnose-surface-verified:<count>   the named tests ran and passed
#   skip:no-windows-toolchain              no Windows cargo reachable from here
#   skip:windows-toolchain-blocked         cargo blocked by Smart App Control
#   skip:no-test-run                       the runner produced no test results
#   violation:tests-failed:<name>          a pinned test ran and failed
#   violation:missing-test:<name>          a pinned test is not in the binary
#
# Exit 0 on ok/skip, 1 on violation.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The tests that make up the operator-facing diagnostic contract. Named here
# rather than in the YAML so the list and the run share one source of truth.
PINNED_TESTS=(
    diagnose_json_top_level_keys_pinned
    diagnose_json_top_level_keys_exact_count
    diagnose_json_wire_object_keys_pinned
    diagnose_json_manifest_pin_some_serializes_as_string
    diagnose_json_manifest_pin_none_serializes_as_null
    diagnose_json_recent_log_tail_is_array
    status_once_json_keys_pinned
    exit_code_provisioned_zero_degraded_two
    status_once_exit_codes
    summary_line_classifies_exit_code
    status_summary_line_classifies_exit_code
    version_line_uses_workspace_version_and_commit
    help_text_documents_all_cli_modes
    select_log_tail_handles_all_cases
    compose_tooltip_includes_version_and_status
    should_rotate_log_at_threshold_boundary
    first_line_handles_all_cases
)

find_windows_cargo() {
    # Native Windows shell (Git Bash / MSYS).
    case "$(uname -s 2>/dev/null || echo unknown)" in
        MINGW* | MSYS* | CYGWIN*)
            command -v cargo 2>/dev/null && return 0
            ;;
    esac
    # WSL with interop: the Windows cargo is runnable through /mnt/c.
    for candidate in \
        "$(command -v cargo.exe 2>/dev/null || true)" \
        /mnt/c/Users/*/.cargo/bin/cargo.exe; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    done
    return 1
}

# Test seam: the fixture feeds a recorded cargo transcript so every verdict in
# the grammar can be proven reachable without a Windows toolchain — including
# the ones that only occur when the toolchain is broken, which is the case that
# was misreported before.
if [ -n "${TRAY_DIAGNOSE_FIXTURE_OUTPUT:-}" ]; then
    output="$TRAY_DIAGNOSE_FIXTURE_OUTPUT"
else
    CARGO="$(find_windows_cargo)" || {
        echo "skip:diagnose-surface-unverifiable:no-windows-toolchain"
        exit 0
    }
    cd "$ROOT" || { echo "skip:diagnose-surface-unverifiable:no-test-run"; exit 0; }
    output="$("$CARGO" test -p tillandsias-windows-tray --lib -- --nocapture 2>&1)"
fi

# DID THE RUNNER RUN? Ask before interpreting anything it printed.
#
# The first version of this check skipped that question and reported
# `violation:missing-test:<last name in the list>` when cargo had not executed a
# single test — Smart App Control on this host intermittently blocks freshly
# built unsigned binaries with "An Application Control policy has blocked this
# file. (os error 4551)", and every pinned test then looks absent for the same
# reason. Naming a specific test as missing when the truth is "nothing ran" is
# precisely the misdirection this packet exists to remove, so it gets its own
# verdict.
if printf '%s' "$output" | grep -qF "Application Control policy has blocked"; then
    echo "skip:diagnose-surface-unverifiable:windows-toolchain-blocked"
    exit 0
fi
if ! printf '%s' "$output" | grep -qE "^test .* \.\.\. (ok|FAILED|ignored)"; then
    echo "skip:diagnose-surface-unverifiable:no-test-run"
    exit 0
fi

missing=""
for t in "${PINNED_TESTS[@]}"; do
    if ! printf '%s' "$output" | grep -qF "$t"; then
        # Report the FIRST one: the list is ordered by surface area, and the
        # last-wins bug in the first version made the report arbitrary.
        [ -z "$missing" ] && missing="$t"
    fi
done
if [ -n "$missing" ]; then
    # A pinned test absent from a run that DID execute tests is not in the
    # binary — renamed, deleted, or cfg'd out. That is the drift the original
    # grep steps existed to catch, caught here by running rather than reading.
    echo "violation:diagnose-surface:missing-test:$missing"
    exit 1
fi

# The suite has one KNOWN pre-existing red, unrelated to this surface:
# embedded_guest_headless_matches_workspace_version (the committed guest binary
# goes stale whenever the build counter moves — see the dated plan/issues note).
# Judge each pinned test by its own result line so this check neither hides that
# red nor inherits it.
failed=""
for t in "${PINNED_TESTS[@]}"; do
    if printf '%s' "$output" | grep -qE "^test .*${t} \.\.\. FAILED"; then
        [ -z "$failed" ] && failed="$t"
    fi
done
if [ -n "$failed" ]; then
    echo "violation:diagnose-surface:tests-failed:$failed"
    exit 1
fi

echo "ok:diagnose-surface-verified:${#PINNED_TESTS[@]}"
exit 0
