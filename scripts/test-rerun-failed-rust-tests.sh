#!/usr/bin/env bash
# @trace order:1242-4x53, spec:methodology-accountability
#
# Pins rerun_failed_rust_tests (scripts/lib-rerun-failed-rust-tests.sh), the
# same-regime re-run behind the `reproduced` field on a failed rust-tests
# check. Hermetic: the "cargo" is a fake runner, so no arm compiles anything.
#
# ARM 1 is 1242-4x53's NEGATIVE CONTROL: a genuine regression (the test fails
# again) must be recorded reproduced=yes. A re-run mechanism is one bug away
# from absorbing every red as noise, and this arm is what would catch that.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"
# shellcheck source=scripts/lib-rerun-failed-rust-tests.sh
. "$ROOT/scripts/lib-rerun-failed-rust-tests.sh"

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A cargo test log with two failures, one pass, and noise that must not parse.
cat > "$TMP/red.log" <<'EOF'
running 3 tests
test groundtruth::tests::the_spec_engine_stamps_the_index_frame_not_the_readers_head ... FAILED
test fold::tests::keeps_order ... ok
test fold::tests::drops_tombstones ... FAILED
failures:
    fold::tests::drops_tombstones
test result: FAILED. 1 passed; 2 failed
EOF

# Fake runners. Each records the argv it was given.
still_red() { printf '%s\n' "$*" > "$TMP/argv"; return 101; }
now_green() { printf '%s\n' "$*" > "$TMP/argv"; return 0; }

# ARM 1 — NEGATIVE CONTROL: a seeded genuine regression reproduces.
v="$(rerun_failed_rust_tests "$TMP/red.log" still_red)"
[ "$v" = yes ] && ok "a failure that fails again is reproduced=yes (not absorbed as noise)" \
    || bad "a genuine regression was recorded as '$v', not yes"

# ARM 2 — a failure that passes on the re-run is reproduced=no.
v="$(rerun_failed_rust_tests "$TMP/red.log" now_green)"
[ "$v" = no ] && ok "a failure that passes on re-run is reproduced=no" \
    || bad "a non-reproducing failure was recorded as '$v', not no"

# ARM 3 — the re-run names exactly the FAILED tests, after `-- --exact`, and
# carries the caller's argv (the same regime) in front of them.
rerun_failed_rust_tests "$TMP/red.log" now_green env SEAT=1 cargo test >/dev/null
want="env SEAT=1 cargo test -- --exact fold::tests::drops_tombstones groundtruth::tests::the_spec_engine_stamps_the_index_frame_not_the_readers_head"
got="$(cat "$TMP/argv")"
[ "$got" = "$want" ] && ok "re-runs exactly the failed tests, in the caller's regime" \
    || bad "re-run argv was: $got"

# ARM 4 — no FAILED names (a compile error, a killed run): no answer, no re-run.
printf 'error[E0433]: cannot find module\n' > "$TMP/compile.log"
rm -f "$TMP/argv"
v="$(rerun_failed_rust_tests "$TMP/compile.log" still_red)"
if [ -z "$v" ] && [ ! -e "$TMP/argv" ]; then
    ok "no FAILED test names: nothing re-run, no verdict"
else
    bad "a log with no FAILED tests produced '$v' (re-ran: $([ -e "$TMP/argv" ] && echo yes || echo no))"
fi

# ARM 5 — an unreadable log is not an error for the caller.
v="$(rerun_failed_rust_tests "$TMP/missing.log" still_red)"; rc=$?
[ -z "$v" ] && [ "$rc" -eq 0 ] && ok "missing log: empty verdict, rc 0" \
    || bad "missing log gave '$v' rc=$rc"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'ok:rerun-failed-rust-tests:%d/%d\n' "$pass" "$total"
else
    printf 'refused:rerun-failed-rust-tests:%d/%d\n' "$pass" "$total"
    exit 1
fi
