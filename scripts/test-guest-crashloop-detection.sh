#!/usr/bin/env bash
# @trace spec:guest-crashloop-detection
# Falsifiable, offline proof of host-side guest CRASH-LOOP DETECTION.
#
# The host tier must tell a guest that is LOOPING (restarting over and over,
# never converging) apart from one that is merely PROGRESSING SLOWLY, and say
# so in a pinned, regex-testable grammar. This drives the REAL cross-platform
# detector (tillandsias-control-wire::crashloop — the same state machine both
# the Windows NotifyIcon tray and the macOS AppKit tray consume) through:
#
#   POSITIVE  a driven stop->start series (Ready->Provisioning repeated) and a
#             sealed-vault loop flip --diagnose's verdict to
#             crash-loop:<subsystem> WITHIN the window; and
#   NEGATIVE  a normal, slow, monotonically-progressing provision NEVER flips
#             (no false positive on slow starts — an explicit exit criterion).
#
# The detector is pure Rust, so the faithful proof is its unit suite rather
# than a bash re-implementation that could pass while the shipped code is
# broken. Only the small `tillandsias-control-wire` crate is compiled (seconds).
#
# plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

LOG="$(mktemp "${TMPDIR:-/tmp}/crashloop-detect.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

# Drive the shipped detector. `crashloop` selects the module's tests:
#   - driven_restart_series_trips_crash_loop         (positive: stop->start)
#   - sealed_vault_loop_trips_vault_unseal_subsystem (positive: sealed vault)
#   - repeated_handshake_timeouts_trip_handshake_subsystem
#   - slow_but_progressing_provision_never_trips     (negative: slow start)
#   - single_relaunch_does_not_trip                  (negative: one restart)
#   - events_age_out_of_window                       (self-clears)
#   - verdicts_render_to_pinned_grammar / grammar_validator_rejects_malformed
#   - state_file_round_trip_preserves_verdict / save_then_load_via_tempfile
if ! cargo test -p tillandsias-control-wire --lib crashloop -- --nocapture >"$LOG" 2>&1; then
    echo "---- cargo test output ----" >&2
    cat "$LOG" >&2
    fail "crash-loop detector unit proof failed"
fi

# Require BOTH the positive (trip) and negative (no-false-positive) proofs to
# have actually run and passed — a silently-empty filter must not read as PASS.
grep -Fq 'driven_restart_series_trips_crash_loop ... ok' "$LOG" \
    || fail "positive stop->start trip proof did not run/pass"
grep -Fq 'sealed_vault_loop_trips_vault_unseal_subsystem ... ok' "$LOG" \
    || fail "positive sealed-vault trip proof did not run/pass"
grep -Fq 'slow_but_progressing_provision_never_trips ... ok' "$LOG" \
    || fail "negative slow-progression proof did not run/pass"
grep -Eq 'test result: ok\. [0-9]+ passed; 0 failed' "$LOG" \
    || fail "crash-loop detector suite reported failures"

echo "ok: crash-loop detector trips on a driven restart/unseal series within the window and stays quiet on a slow-but-progressing provision"
