#!/usr/bin/env bash
# @trace spec:ci-release
#
# test-check-test-baseline.sh — hermetic scenarios for the test-baseline
# ratchet. Every case is a synthetic cargo transcript plus a synthetic
# known-red list in a throwaway directory; nothing here compiles or runs a real
# test, which is the whole reason check-test-baseline.sh takes `--from <file>`.
#
# The load-bearing cases are the two directions of the ratchet (an unlisted
# failure, and a listed test that passed) and the case that keeps the second
# direction honest: a listed test that is ABSENT from the transcript must be
# neither, or `--check` — which feeds it a plan-lib-only transcript — would red
# on the headless entry every single run.
#
# NON-VACUITY, PROVEN NOT ASSERTED (2026-08-21). A fixture that passes against
# a broken gate is worse than none, so both halves of the gate were neutered in
# place and the damage counted:
#
#   `: > "$TMPD/new_red"`  (new-regression half)  -> 7 passed, 3 failed
#        an unlisted failure is a new regression
#        a new red and a stale entry together report the new red first
#        the same test name in another binary is not covered by the entry
#   `: > "$TMPD/stale"`    (ratchet half)         -> 8 passed, 2 failed
#        a listed test that now passes is a stale entry
#        a new red and a stale entry together report the new red first
#
# Restored: 10 passed, 0 failed, rc=0. Every other assertion stayed green under
# both mutations, so neither one is satisfiable by a gate that simply refuses
# everything.
#
# Run: scripts/test-check-test-baseline.sh   (exit 0 = pass)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-test-baseline.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-baseline-fixture.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

_assert() {
    # _assert <label> <expected-rc> <expected-verdict-prefix> <transcript> <list>
    local label="$1" want_rc="$2" want_prefix="$3" transcript="$4" list="$5"
    local out rc
    out="$(bash "$GATE" --from "$transcript" --list "$list" 2>/dev/null)"
    rc=$?
    case "$out" in
        "$want_prefix"*)
            if [ "$rc" -eq "$want_rc" ]; then
                PASSED=$((PASSED + 1))
                echo "  ok   $label"
                return 0
            fi
            ;;
    esac
    FAILED=$((FAILED + 1))
    echo "FAIL: $label"
    echo "      wanted rc=$want_rc verdict prefix '$want_prefix'"
    echo "      got    rc=$rc verdict '$out'"
}

# A transcript shaped exactly like cargo's, two binaries deep, so the binary
# stem the gate keys on is derived and not assumed.
_transcript() {
    # _transcript <plan-lib-result> <proxy-result>
    cat <<EOF
   Compiling tillandsias-plan v0.1.0 (/repo/crates/tillandsias-plan)
    Finished \`test\` profile [unoptimized + debuginfo] target(s) in 1.25s
     Running unittests src/lib.rs (target/debug/deps/tillandsias_plan-9459f657098fa92c)

running 2 tests
test answer::tests::epoch_formatting_is_correct ... ok
test answer::tests::a_real_packet_stays_answerable ... $1

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.10s

     Running tests/proxy_cache_policy.rs (target/debug/deps/proxy_cache_policy-16b4029ff16a4a4c)

running 2 tests
test ssl_bump_is_step_scoped_to_one_exact_release_asset_host ... ok
test bumped_origin_tls_and_signed_url_logs_fail_closed ... $2

test result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
EOF
}

echo "test-baseline ratchet fixture"

# The real list's shape: comments, blank lines, one key.
cat > "$WORK/list-seeded.txt" <<'EOF'
# Comment lines are not entries.
# Filed: plan/issues/whatever.md

proxy_cache_policy::bumped_origin_tls_and_signed_url_logs_fail_closed
EOF
: > "$WORK/list-empty.txt"

# 1. The baseline itself: the one listed failure is red, everything else green.
_transcript ok FAILED > "$WORK/t-baseline.txt"
_assert "the seeded known-red failure alone is tolerated" \
    0 "ok:test-baseline:ran=4 new-red=0 tolerated=1 stale=0" \
    "$WORK/t-baseline.txt" "$WORK/list-seeded.txt"

# 2. DIRECTION ONE — a failure nobody declared. This is the archive-sweep case.
_transcript FAILED FAILED > "$WORK/t-newred.txt"
_assert "an unlisted failure is a new regression" \
    1 "fail:test-baseline:ran=4 new-red=1 tolerated=1 stale=0 first=tillandsias_plan::answer::tests::a_real_packet_stays_answerable" \
    "$WORK/t-newred.txt" "$WORK/list-seeded.txt"

# 3. DIRECTION TWO — a listed test that passed. The list may only shrink.
_transcript ok ok > "$WORK/t-stale.txt"
_assert "a listed test that now passes is a stale entry" \
    1 "fail:test-baseline:ran=4 new-red=0 tolerated=0 stale=1 first=proxy_cache_policy::bumped_origin_tls_and_signed_url_logs_fail_closed" \
    "$WORK/t-stale.txt" "$WORK/list-seeded.txt"

# 4. Both at once still names the regression first — the new red is the urgent
#    half, and only one line is printed.
cat > "$WORK/list-other.txt" <<'EOF'
proxy_cache_policy::ssl_bump_is_step_scoped_to_one_exact_release_asset_host
EOF
_transcript FAILED FAILED > "$WORK/t-both.txt"
_assert "a new red and a stale entry together report the new red first" \
    1 "fail:test-baseline:ran=4 new-red=2 tolerated=0 stale=1 first=proxy_cache_policy::bumped_origin_tls_and_signed_url_logs_fail_closed" \
    "$WORK/t-both.txt" "$WORK/list-other.txt"

# 5. ABSENT IS NOT STALE. A plan-lib-only transcript must not red on an entry
#    that lives in a test binary this run never built. Without this, wiring the
#    gate into --check would be impossible.
cat > "$WORK/t-planonly.txt" <<'EOF'
     Running unittests src/lib.rs (target/debug/deps/tillandsias_plan-9459f657098fa92c)

running 1 test
test answer::tests::epoch_formatting_is_correct ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.10s
EOF
_assert "a listed test absent from the transcript is neither red nor stale" \
    0 "ok:test-baseline:ran=1 new-red=0 tolerated=0 stale=0" \
    "$WORK/t-planonly.txt" "$WORK/list-seeded.txt"

# 6. Identity is qualified by binary. The SAME bare test name failing in a
#    binary the entry does not name is a new red, not a tolerated failure.
cat > "$WORK/t-samename.txt" <<'EOF'
     Running tests/other_suite.rs (target/debug/deps/other_suite-deadbeefdeadbeef)

running 1 test
test bumped_origin_tls_and_signed_url_logs_fail_closed ... FAILED

test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
EOF
_assert "the same test name in another binary is not covered by the entry" \
    1 "fail:test-baseline:ran=1 new-red=1 tolerated=0 stale=0 first=other_suite::bumped_origin_tls_and_signed_url_logs_fail_closed" \
    "$WORK/t-samename.txt" "$WORK/list-empty.txt"

# 7. `ignored` is not `ok`. An entry whose test was skipped must not be pruned
#    on the strength of a run that never executed it.
cat > "$WORK/t-ignored.txt" <<'EOF'
     Running tests/proxy_cache_policy.rs (target/debug/deps/proxy_cache_policy-16b4029ff16a4a4c)

running 1 test
test bumped_origin_tls_and_signed_url_logs_fail_closed ... ignored, needs squid

test result: ok. 0 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.00s
EOF
_assert "an ignored listed test is neither red nor stale" \
    0 "ok:test-baseline:ran=1 new-red=0 tolerated=0 stale=0" \
    "$WORK/t-ignored.txt" "$WORK/list-seeded.txt"

# 8. A run that produced no test results is a refusal, not a pass. This is the
#    compile-failure shape, and it is the one an `|| true` would swallow.
cat > "$WORK/t-nobuild.txt" <<'EOF'
   Compiling tillandsias-plan v0.1.0 (/repo/crates/tillandsias-plan)
error[E0425]: cannot find value `nope` in this scope
error: could not compile `tillandsias-plan` (lib test) due to 1 previous error
EOF
_assert "a transcript with no test results refuses" \
    2 "fail:test-baseline:no-test-results=" \
    "$WORK/t-nobuild.txt" "$WORK/list-seeded.txt"

# 9. `test result: FAILED.` also begins with `test ` — it must not be parsed as
#    a test. Case 1 already depends on this (ran=4, not 6); asserted directly
#    here so a regression in the parser names itself.
_assert "the per-binary summary line is not counted as a test" \
    0 "ok:test-baseline:ran=4 " \
    "$WORK/t-baseline.txt" "$WORK/list-seeded.txt"

# 10. A deleted list is a refusal. An empty list would still catch new reds, so
#     "missing" must not read as "nothing tolerated" — that loses the stale
#     half of the ratchet silently.
_assert "a missing known-red list refuses rather than defaulting to empty" \
    2 "fail:test-baseline:missing-known-red=" \
    "$WORK/t-baseline.txt" "$WORK/list-gone.txt"

echo
if [ "$FAILED" -gt 0 ]; then
    echo "FAIL: test-baseline ratchet fixture — $PASSED passed, $FAILED failed"
    exit 1
fi
echo "PASS: test-baseline ratchet fixture — $PASSED passed, 0 failed"
exit 0
