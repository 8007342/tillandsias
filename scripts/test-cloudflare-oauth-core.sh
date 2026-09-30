#!/usr/bin/env bash
# @trace order:1505-kyx8, openspec/changes/cloudflare-login-and-fleet-vpn/design.md (Decision 1)
# @trace openspec/changes/cloudflare-login-and-fleet-vpn/specs/cloudflare-auth/spec.md
#
# test-cloudflare-oauth-core.sh — drives the REAL cloudflare_oauth::{begin,
# exchange, refresh, revoke} (1505-kyx8) against a REAL loopback instance of
# tillandsias-fake-cloudflare (1505-svve).
#
# `cargo test -p tillandsias-headless cloudflare_oauth` (no --ignored) never
# touches a socket: every arm there runs against an in-process
# MockHttpClient, which is what proves "no test constructs a network client"
# for that command (the packet's own exit criterion). The five arms this
# script runs are `#[ignore]`d for exactly the opposite reason — they DO
# construct the real ReqwestHttpClient and DO open a real loopback socket —
# so they only run when asked for by name, here.
#
# Each arm is a `#[test]` fn inside
# crates/tillandsias-headless/src/cloudflare_oauth.rs (`mod loopback_tests`),
# not a separate binary this script writes. This script's job is: build both
# binaries, point the harness at the fake it just built, run the five ignored
# tests with --nocapture (so begin()'s eprintln! note reaches THIS script's
# log rather than libtest's normally-swallowed capture buffer), and assert on
# each arm's name plus the printed note line.
#
#   1 loopback_exchange_succeeds_with_right_state_and_verifier — begin()
#     yields an authorize URL with code_challenge_method=S256 and a
#     43..128-char verifier; exchange() with the right verifier returns a
#     bundle.
#   2 loopback_state_mismatch_makes_zero_token_requests — THE NEGATIVE
#     CONTROL: a tampered state is refused by the CLIENT (exchange() never
#     calls http.post_form at all when the state does not match), proven by
#     asserting the fake's own ledger shows zero /oauth2/token lines — not
#     just that exchange() returned an Err, which a server-side 400 would
#     also produce.
#   3 loopback_refresh_rotates_and_invalidates_old_refresh_token
#   4 loopback_revoke_succeeds_against_real_fake
#   5 loopback_device_grant_note_printed_when_discovery_lists_it — asserts
#     the RETURNED Pending.device_grant_note field AND (this script grepping
#     the captured log) the literal `note:cloudflare-login:device-grant-available`
#     line begin() actually printed to stderr.
#
# PRE-FIX RESULT: FAILS — before 1505-kyx8,
# crates/tillandsias-headless/src/cloudflare_oauth.rs does not exist, so
# `cargo test ... cloudflare_oauth::loopback_tests` fails to compile
# ("cannot find `cloudflare_oauth`").
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

if ! command -v cargo >/dev/null 2>&1; then
    echo "skip:cloudflare-oauth-core:no-cargo"
    exit 3
fi

WORK="$(mktemp -d -t tillandsias-cloudflare-oauth-core-test.XXXXXX)"
LOG="$WORK/cargo-test.log"
trap 'rm -rf "$WORK"' EXIT

echo "[cloudflare-oauth-core] building tillandsias-fake-cloudflare..." >&2
if ! cargo build -p tillandsias-headless --bin tillandsias-fake-cloudflare >"$WORK/build-fake.log" 2>&1; then
    cat "$WORK/build-fake.log" >&2
    echo "fail:cloudflare-oauth-core:build-fake"
    exit 1
fi
FAKE_BIN="$ROOT/target/debug/tillandsias-fake-cloudflare"
if [ ! -x "$FAKE_BIN" ]; then
    echo "fail:cloudflare-oauth-core:fake-binary-missing:$FAKE_BIN"
    exit 1
fi

echo "[cloudflare-oauth-core] running the loopback arms against it (this also builds the tillandsias test binary)..." >&2
export TILLANDSIAS_FAKE_CLOUDFLARE_BIN="$FAKE_BIN"
CARGO_RC=0
cargo test -p tillandsias-headless --bin tillandsias cloudflare_oauth::loopback_tests -- \
    --ignored --test-threads=1 --nocapture >"$LOG" 2>&1 || CARGO_RC=$?

ARMS="
loopback_exchange_succeeds_with_right_state_and_verifier
loopback_state_mismatch_makes_zero_token_requests
loopback_refresh_rotates_and_invalidates_old_refresh_token
loopback_revoke_succeeds_against_real_fake
loopback_device_grant_note_printed_when_discovery_lists_it
"

PASS=0
TOTAL=0
for arm in $ARMS; do
    [ -n "$arm" ] || continue
    TOTAL=$((TOTAL + 1))
    if grep -qF "test cloudflare_oauth::loopback_tests::${arm} " "$LOG" \
        && ! grep -qE "^test cloudflare_oauth::loopback_tests::${arm} .*FAILED" "$LOG"; then
        echo "ok:   $arm"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $arm -- not found passing in cargo test output"
    fi
done

NOTE_OK=0
if grep -qF "note:cloudflare-login:device-grant-available" "$LOG"; then
    echo "ok:   device_grant_note_printed_to_stderr"
    NOTE_OK=1
else
    echo "FAIL: device_grant_note_printed_to_stderr -- literal note: line not found in cargo test output"
fi

SUMMARY_OK=0
if grep -qE "^test result: ok\. ${TOTAL} passed; 0 failed;" "$LOG"; then
    SUMMARY_OK=1
else
    echo "FAIL: cargo_test_summary -- expected 'test result: ok. ${TOTAL} passed; 0 failed;' in output" >&2
fi

if [ "$CARGO_RC" -ne 0 ]; then
    echo "" >&2
    echo "-- cargo test output (nonzero exit $CARGO_RC) --" >&2
    cat "$LOG" >&2
fi

echo ""
if [ "$CARGO_RC" -eq 0 ] && [ "$PASS" -eq "$TOTAL" ] && [ "$NOTE_OK" -eq 1 ] && [ "$SUMMARY_OK" -eq 1 ]; then
    echo "ok:cloudflare-oauth-core:${PASS}/${TOTAL}+note"
    exit 0
else
    echo "fail:cloudflare-oauth-core:${PASS}/${TOTAL}+note=${NOTE_OK}+summary=${SUMMARY_OK}+rc=${CARGO_RC}"
    exit 1
fi
