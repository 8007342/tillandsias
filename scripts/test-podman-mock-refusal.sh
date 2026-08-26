#!/usr/bin/env bash
# @trace spec:litmus-framework
# =============================================================================
# test-podman-mock-refusal.sh — order 797-p2xa, the NESTED half.
#
# 97cb255a9 made the top-level `case` in scripts/test-support/podman-mock.sh
# fail closed and put the packet's negative control in
# scripts/test-litmus-fake-podman-hermetic.sh. That closed the outer hole. It
# did not close the class: the SAME fall-through was reachable one level down,
# from an inner `case` that matched nothing, left its arm with no output, and
# landed on the file's trailing `exit 0`. `podman image ls`, `podman secret
# whatever` and `podman image inspect <img>` (no --format) each answered
# SUCCESS with EMPTY output after the outer arm landed, exactly as `--remote`
# had before it.
#
# WHY IT MATTERS, measured and not hypothetical: the outer instance cost
# roughly four hours across three wrong diagnoses on 2026-08-17 (797-vv3n),
# because the only symptoms were consequences several layers downstream —
# "atomic rename failed: No such file or directory" (the temp checkout the mock
# never made) and "invalid gh JSON: EOF while parsing a value at line 1
# column 0" (the array it never printed). Neither string contains the words
# podman, mock, or unrecognized.
#
# WHAT IS ASSERTED. Three properties, each with the control that makes it
# non-vacuous:
#
#   1. REFUSAL — an unhandled invocation exits 97 with a typed diagnostic on
#      stderr and NOTHING on stdout, at every dispatch level.
#      Control: scenario 2 runs TWO different absurd subcommands and requires
#      each diagnostic to name its OWN subject and NOT the other's. A
#      hardcoded, truncated or dropped-interpolation message passes scenario 1
#      and fails this one.
#
#   2. DELIBERATE NO-OPS STAY NO-OPS — network/compose/system still exit 0
#      silently, because the mock models no network, compose or system state.
#      Control: asserted to exit 0 AND print nothing, so a refusal wired too
#      broadly turns them red.
#
#   3. HANDLED ARMS ARE UNCHANGED — version/info/build/ps/inspect/exec and the
#      797-vv3n `--remote --url <u> run ... gh api user/repos` shape still
#      produce their canned answers.
#      Control: the other half of "too broad". Scenarios 1-2 fail if the mock
#      refuses nothing; scenario 3 fails if it refuses everything. Both
#      directions are needed — a mock that refuses everything is as useless as
#      one that refuses nothing, and only one of those is caught by asserting
#      that a refusal happened.
#
# Grammar, one line on stdout per scenario plus a verdict line:
#   ok:podman-mock-refusal:<scenario>
#   ok: all podman-mock-refusal scenarios passed | fail: ...
#
# Pinned by litmus:podman-mock-refuses-unknown-invocations.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK="$ROOT/scripts/test-support/podman-mock.sh"
# Tracks the exit status of mock_refuse() in the mock. Asserted EXACTLY, not
# merely "non-zero": a refusal that degraded into some other failure — a set -e
# trip, a syntax error, an `exit 1` from a mocked command — is also non-zero
# and would still hide the class this packet closed.
REFUSAL_EXIT=97

if [ ! -x "$MOCK" ]; then
    echo "fail: $MOCK missing or not executable"
    exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/podman-mock-refusal.XXXXXX")"
# shellcheck disable=SC2064  # expand $tmp now: it is set here and never reassigned.
trap "rm -rf '$tmp'" EXIT INT TERM HUP

# Keep every mock invocation's state inside our own tmp so the fixture never
# writes into the shared .fake-podman-state tree other runs use.
export LITMUS_PODMAN_STATE_DIR="$tmp/state"

fail=0
rc=0
out_file=""
err_file=""

run_mock() { # run_mock <label> [argv...]
    local label="$1"
    shift
    out_file="$tmp/$label.out"
    err_file="$tmp/$label.err"
    "$MOCK" "$@" >"$out_file" 2>"$err_file"
    rc=$?
}

pass() { echo "ok:podman-mock-refusal:$1"; }
bad() {
    echo "FAIL: $1"
    shift
    [ "$#" -gt 0 ] && printf '      %s\n' "$@"
    fail=1
}

# ── scenario 1: the absurd subcommand ───────────────────────────────────────
run_mock absurd frobnicate-the-widget --with-jam
if [ "$rc" -eq "$REFUSAL_EXIT" ] \
   && [ ! -s "$out_file" ] \
   && grep -q 'REFUSED: unrecognized subcommand: frobnicate-the-widget' "$err_file"; then
    pass "absurd-subcommand-refused-nonzero-and-named"
else
    bad "absurd subcommand not refused (rc=$rc, want $REFUSAL_EXIT)" \
        "stdout: $(cat "$out_file")" "stderr: $(cat "$err_file")"
fi

# ── scenario 2: the diagnostic names THIS subcommand, not a canned one ──────
# The control for scenario 1. Two distinct absurd verbs; the REFUSED line must
# carry its own subject and must not carry the other's.
#
# It reads ONLY the REFUSED line, deliberately. The first draft grepped all of
# stderr and was VACUOUS: the `full argv:` line echoes the invocation, so the
# verb is present in stderr no matter what the REFUSED line says. Replacing the
# interpolated subject with a canned string left that draft fully green while
# the mock reported every refusal as "an-unrecognized-subcommand" — the exact
# failure the scenario exists to catch, reached by a path the mutation did not
# break. Measured, not reasoned about: mutation control MC4b.
refused_line() { grep -m1 'REFUSED: unrecognized' "$1" || true; }
run_mock absurd_a alpha-not-a-podman-verb
a_rc=$rc
a_line="$(refused_line "$err_file")"
run_mock absurd_b beta-not-a-podman-verb
b_rc=$rc
b_line="$(refused_line "$err_file")"
if [ "$a_rc" -eq "$REFUSAL_EXIT" ] && [ "$b_rc" -eq "$REFUSAL_EXIT" ] \
   && printf '%s' "$a_line" | grep -q 'alpha-not-a-podman-verb' \
   && ! printf '%s' "$a_line" | grep -q 'beta-not-a-podman-verb' \
   && printf '%s' "$b_line" | grep -q 'beta-not-a-podman-verb' \
   && ! printf '%s' "$b_line" | grep -q 'alpha-not-a-podman-verb'; then
    pass "diagnostic-subject-is-interpolated-not-canned"
else
    bad "the REFUSED line does not distinguish two different subcommands" \
        "alpha: $a_line" "beta: $b_line"
fi

# ── scenario 3: global flags — the 797-vv3n shape, refused on the SUBCOMMAND ─
# `podman --remote --url <u> <verb>` is what the Rust launcher and
# scripts/common.sh emit. The refusal must name the verb, never the flag: a
# mock that reports `--remote` as the unknown subcommand has told the caller
# the wrong thing, which is how four hours went last time. The argv line must
# also still SHOW the flags, which is why the mock captures argv before the
# skip loop rather than printing the post-shift "$*".
run_mock remote_absurd --remote --url unix:///x frobnicate-the-widget
if [ "$rc" -eq "$REFUSAL_EXIT" ] \
   && grep -q 'REFUSED: unrecognized subcommand: frobnicate-the-widget' "$err_file" \
   && ! grep -q 'REFUSED: unrecognized subcommand: --remote' "$err_file" \
   && grep -q 'full argv: podman --remote --url unix:///x frobnicate-the-widget' "$err_file"; then
    pass "global-flags-skipped-refusal-names-the-verb-and-quotes-full-argv"
else
    bad "refusal after global flags named the wrong subject or lost the flags (rc=$rc)" \
        "stderr: $(cat "$err_file")"
fi

# ── scenario 4: no subcommand at all ────────────────────────────────────────
run_mock nosub
if [ "$rc" -eq "$REFUSAL_EXIT" ] && grep -q 'REFUSED: unrecognized subcommand: <empty>' "$err_file"; then
    pass "bare-invocation-refused"
else
    bad "bare podman invocation not refused (rc=$rc)" "stderr: $(cat "$err_file")"
fi

# Only global flags, no verb — same class, different path through the skip loop.
run_mock onlyflags --remote --url unix:///x
if [ "$rc" -eq "$REFUSAL_EXIT" ] && grep -q 'REFUSED: unrecognized subcommand: <empty>' "$err_file"; then
    pass "flags-without-a-verb-refused"
else
    bad "global flags with no verb not refused (rc=$rc)" "stderr: $(cat "$err_file")"
fi

# ── scenario 5: NESTED dispatch — the half the outer arm could not see ──────
# `image` and `secret` each run an inner `case`. A miss there leaves the arm
# WITHOUT matching the outer `*)`, so it landed on the trailing `exit 0` even
# after 97cb255a9. Same defect, one level down.
run_mock image_absurd image frobnicate-the-widget
if [ "$rc" -eq "$REFUSAL_EXIT" ] && [ ! -s "$out_file" ] \
   && grep -q 'REFUSED: unrecognized image subcommand: frobnicate-the-widget' "$err_file"; then
    pass "unknown-image-subcommand-refused"
else
    bad "unknown 'image' subcommand not refused (rc=$rc)" \
        "stdout: $(cat "$out_file")" "stderr: $(cat "$err_file")"
fi

run_mock secret_absurd secret frobnicate-the-widget
if [ "$rc" -eq "$REFUSAL_EXIT" ] && [ ! -s "$out_file" ] \
   && grep -q 'REFUSED: unrecognized secret subcommand: frobnicate-the-widget' "$err_file"; then
    pass "unknown-secret-subcommand-refused"
else
    bad "unknown 'secret' subcommand not refused (rc=$rc)" \
        "stdout: $(cat "$out_file")" "stderr: $(cat "$err_file")"
fi

# `image inspect <img>` with no --format: the mock has no bare-form payload, so
# it used to answer with an empty stdout and success — the shape most likely to
# be read as "this image has no data" rather than "nothing ran".
# The tag is a fixture string, not a real reference — nothing is pulled. It is
# pinned anyway because check-container-bases.sh greps scripts/ for
# `tillandsias-*:latest` and cannot tell an argument to a mock from an image
# this repo would actually run. `./build.sh --check` does not run that policy
# but `--ci-full` does, which is how this reached linux-next green and then
# failed the e2e's build gate (found 2026-08-18).
run_mock image_inspect_bare image inspect localhost/tillandsias-git:0.0.0-fixture
if [ "$rc" -eq "$REFUSAL_EXIT" ] && [ ! -s "$out_file" ] \
   && grep -q 'REFUSED: unrecognized image inspect form' "$err_file"; then
    pass "bare-image-inspect-refused"
else
    bad "'image inspect' without --format not refused (rc=$rc)" \
        "stdout: $(cat "$out_file")" "stderr: $(cat "$err_file")"
fi

# CONTROL for the two above: the handled inner arms must still answer, or the
# nested refusals would be passing on a mock that refuses all nesting.
run_mock image_inspect_format image inspect localhost/x:1 --format '{{.Size}}'
if [ "$rc" -ne 0 ] || ! grep -q '^0$' "$out_file"; then
    bad "handled 'image inspect --format' arm changed (rc=$rc)" "stdout: $(cat "$out_file")"
else
    pass "handled-image-inspect-format-unaffected"
fi

# ── scenario 6: deliberate no-ops stay silent successes ─────────────────────
# The distinction the packet asked for: "handled deliberately" and "not handled
# at all" must stop being the same answer. These three ARE handled,
# deliberately, and their handling is to do nothing.
noop_bad=0
for verb in "network create tillandsias-enclave" "compose up -d" "system prune -f"; do
    label="noop-$(printf '%s' "$verb" | tr ' /' '__')"
    # shellcheck disable=SC2086  # deliberate word splitting: fixed literals.
    run_mock "$label" $verb
    if [ "$rc" -ne 0 ] || [ -s "$out_file" ] || [ -s "$err_file" ]; then
        bad "deliberate no-op 'podman $verb' is no longer a silent success (rc=$rc)" \
            "stdout: $(cat "$out_file")" "stderr: $(cat "$err_file")"
        noop_bad=1
    fi
done
if [ "$noop_bad" -eq 0 ]; then
    pass "network-compose-system-remain-explicit-no-ops"
fi

# ── scenario 7: handled arms are unchanged ──────────────────────────────────
handled_bad=0
run_mock v version
if [ "$rc" -ne 0 ] || ! grep -q 'podman version 5.0.0-mock' "$out_file"; then
    bad "podman version arm changed (rc=$rc)" "stdout: $(cat "$out_file")"; handled_bad=1
fi
# The flag form require_podman actually probes with (found by the landed arm).
run_mock vflag --version
if [ "$rc" -ne 0 ] || ! grep -q 'podman version 5.0.0-mock' "$out_file"; then
    bad "podman --version flag form changed (rc=$rc)" "stdout: $(cat "$out_file")"; handled_bad=1
fi
run_mock i info
if [ "$rc" -ne 0 ] || ! grep -q '{}' "$out_file"; then
    bad "podman info arm changed (rc=$rc)" "stdout: $(cat "$out_file")"; handled_bad=1
fi
run_mock b build -t localhost/mock:test .
if [ "$rc" -ne 0 ] || ! grep -q 'mock-build-id' "$out_file"; then
    bad "podman build arm changed (rc=$rc)" "stdout: $(cat "$out_file")"; handled_bad=1
fi
run_mock p ps --format json
if [ "$rc" -ne 0 ]; then
    bad "podman ps arm changed (rc=$rc)" "stderr: $(cat "$err_file")"; handled_bad=1
fi
run_mock ins inspect some-container
if [ "$rc" -ne 0 ] || ! grep -q 'Secrets' "$out_file"; then
    bad "podman inspect fallback changed (rc=$rc)" "stdout: $(cat "$out_file")"; handled_bad=1
fi
run_mock ex exec ctr gh auth status
if [ "$rc" -ne 0 ] || ! grep -q 'authenticated' "$out_file"; then
    bad "podman exec arm changed (rc=$rc)" "stdout: $(cat "$out_file")"; handled_bad=1
fi
run_mock imgexists image exists localhost/x:1
if [ "$rc" -ne 0 ]; then
    bad "podman image exists arm changed (rc=$rc)" "stderr: $(cat "$err_file")"; handled_bad=1
fi
if [ "$handled_bad" -eq 0 ]; then
    pass "handled-arms-still-answer"
fi

# ── scenario 8: the original incident shape end-to-end ──────────────────────
# `--remote --url <u> run ... gh api user/repos` is the exact invocation that
# produced "invalid gh JSON: EOF while parsing a value at line 1 column 0".
# It must reach the run arm and print a JSON array.
run_mock remote_run --remote --url unix:///x run --rm localhost/git:latest gh api user/repos
if [ "$rc" -eq 0 ] && grep -q '^\[{"name":"forge"' "$out_file"; then
    pass "remote-form-run-reaches-the-run-arm"
else
    bad "the 797-vv3n remote run shape regressed (rc=$rc)" \
        "stdout: $(cat "$out_file")" "stderr: $(cat "$err_file")"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok: all podman-mock-refusal scenarios passed"
    exit 0
fi
echo "fail: podman-mock-refusal scenarios failed"
exit 1
