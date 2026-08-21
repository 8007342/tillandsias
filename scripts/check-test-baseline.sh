#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-test-baseline.sh — a RATCHET over a `cargo test` transcript. It answers
# one question: does this run's FAILURE SET differ from the failure set we have
# written down and accepted?
#
# THE SILENCE THIS REPLACES (measured, 2026-08-19 -> 2026-08-20).
#
# An archive sweep moved 550 packets out of plan/index.yaml. Five gates ran and
# all five were green:
#
#   ./build.sh --check                  green, every run
#   archive-plan-packets.sh --check     green (both invariants)
#   check-fragment-status-loss.sh       green
#   ready set byte-identical            asserted and true
#   no new orphaned fragment events     asserted and true
#
# Meanwhile seven tests in `cargo test -p tillandsias-plan --lib` went red,
# because the expert system could no longer ANSWER about an archived packet:
# a real query returned `unsupported: no packet in the ledger matches any
# token`. Control run in both directions rather than inferred — 292a5bc0f
# (pre-sweep) 180/0, 81d2315f5 (post-sweep) 173/7, after the revert 180/0.
#
# NONE OF THOSE FIVE GATES RUNS `cargo test`. `grep -nE 'cargo (test|nextest)'
# build.sh` put tests only in the `--test` dispatch, which the pre-push gate
# does not call. The regression was found BY ACCIDENT, while taking an
# unrelated baseline for a pending merge; without that accident it would have
# reached every other host. So: shape gates cannot see a capability loss, and
# the suite that can see it was not wired to anything that runs every cycle.
#
# WHY A RATCHET AND NOT "THE SUITE MUST BE GREEN".
#
# The suite is not green and pretending otherwise would make this gate the
# first thing anyone switches off. Linux carries exactly ONE standing failure
# (see scripts/test-known-red.txt), macOS carried eight under --no-fail-fast.
# A gate that is always red is a gate nobody reads — the same decay
# check-windows-only-sources-verified.sh reasons about at length, and this file
# copies its shape deliberately: a tolerated failure must be WRITTEN DOWN, BY
# HAND, with its issue.
#
# IT FAILS IN BOTH DIRECTIONS, and the second one is the point.
#
#   * a FAILING test that is not listed          -> new regression, red
#   * a LISTED test that PASSED in this run      -> stale entry, red
#
# Without the second direction the list is a mute button: an entry outlives the
# defect it excused, and the day that test breaks again nothing says so. The
# list may therefore only ever SHRINK without a deliberate edit, which is what
# makes it a ratchet rather than a suppression file. Same polarity as the
# ghost-trace ratchet in scripts/trace-coverage.sh --gate.
#
# A listed test that is ABSENT from the transcript is NEITHER. Absent means
# "not exercised", which carries no information — that is what lets `--check`
# feed this a `-p tillandsias-plan --lib` transcript while the one known-red
# entry lives in a different test binary entirely.
#
# TEST IDENTITY IS QUALIFIED BY ITS BINARY.
#
# Entries are `<test-binary-stem>::<test name as cargo printed it>`, where the
# stem comes from the `Running … (target/debug/deps/<stem>-<hash>)` line above
# the results, hash stripped:
#
#     Running tests/proxy_cache_policy.rs (…/deps/proxy_cache_policy-16b402…)
#     test bumped_origin_tls_and_signed_url_logs_fail_closed ... FAILED
#       ->  proxy_cache_policy::bumped_origin_tls_and_signed_url_logs_fail_closed
#
# A bare test name is ambiguous across binaries — the same name can exist in a
# lib unittest and an integration test — and an ambiguous entry would excuse a
# failure it was never meant to cover. Two crates with identically-named
# integration test files still collide; that is a known and accepted limit,
# recorded here rather than discovered later.
#
# INPUT IS A FILE, NOT A CARGO RUN.
#
# `--from <cargo-test-output>` on purpose: the gate is then a pure function of
# a transcript, so its own fixture (scripts/test-check-test-baseline.sh) runs
# in milliseconds and can drive cases that would take minutes to provoke for
# real. Callers own the cargo invocation and the transcript capture; see the
# two call sites in build.sh (`--test` wraps the whole workspace suite,
# `--check` wraps `-p tillandsias-plan --lib` only).
#
# GRAMMAR (exactly one line on stdout; every detail goes to stderr)
#   ok:test-baseline:ran=<n> new-red=0 tolerated=<t> stale=0
#   fail:test-baseline:ran=<n> new-red=<n> tolerated=<t> stale=<s> first=<key>
#   fail:test-baseline:no-test-results=<path>
#   fail:test-baseline:unreadable-transcript=<path>
#   fail:test-baseline:missing-known-red=<path>
#   fail:test-baseline:usage=<argv>          (the argv is copy-pasteable)
#
# Exit 0 ONLY on `ok:`. Anything else is non-zero — unlike the windows-only
# reporter this is a refusal, because the failure it catches already reached
# trunk once.
#
# ADDING AN ENTRY is a deliberate act: run the test, confirm it fails for a
# reason that is not this change, file the issue, and write the key plus a
# comment naming the issue into scripts/test-known-red.txt. An unexplained name
# there is how a baseline stops meaning anything.

set -uo pipefail

ROOT="${TILLANDSIAS_TEST_BASELINE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KNOWN_RED="${TILLANDSIAS_TEST_KNOWN_RED:-$ROOT/scripts/test-known-red.txt}"
TRANSCRIPT=""
USAGE="scripts/check-test-baseline.sh --from <cargo-test-output> [--list <known-red-file>]"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --from)
            [ "$#" -ge 2 ] || { echo "fail:test-baseline:usage=$USAGE"; exit 2; }
            TRANSCRIPT="$2"
            shift 2
            ;;
        --list)
            [ "$#" -ge 2 ] || { echo "fail:test-baseline:usage=$USAGE"; exit 2; }
            KNOWN_RED="$2"
            shift 2
            ;;
        -h | --help)
            echo "usage: $USAGE"
            exit 0
            ;;
        *)
            echo "fail:test-baseline:usage=$USAGE"
            exit 2
            ;;
    esac
done

if [ -z "$TRANSCRIPT" ]; then
    echo "fail:test-baseline:usage=$USAGE"
    exit 2
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/test-baseline.XXXXXX")" || {
    echo "fail:test-baseline:unreadable-transcript=$TRANSCRIPT"
    exit 2
}
trap 'rm -rf "$TMPD"' EXIT

if [ "$TRANSCRIPT" = "-" ]; then
    cat > "$TMPD/transcript"
    TRANSCRIPT="$TMPD/transcript"
fi

if [ ! -f "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then
    echo "fail:test-baseline:unreadable-transcript=$TRANSCRIPT"
    exit 2
fi

# A missing list is a REFUSAL, not an empty list. An empty list still detects
# new reds, so treating "deleted" as "nothing tolerated" would look like a
# working gate while the ratchet's memory — the half that catches a stale
# entry — had been silently removed.
if [ ! -f "$KNOWN_RED" ]; then
    echo "fail:test-baseline:missing-known-red=$KNOWN_RED"
    exit 2
fi

# One POSIX-awk pass over the transcript. Emits "<result>\t<key>" per test line
# and a trailing "RAN\t<n>". Result lines are matched on their full ` ... ok |
# FAILED | ignored` tail, so `test result: FAILED. 2 passed; 1 failed` — which
# also begins with `test ` — is not mistaken for a test.
awk '
BEGIN { label = "?"; ran = 0 }
/^[[:space:]]*Running / {
    b = $NF
    sub(/^\(/, "", b)
    sub(/\)$/, "", b)
    n = split(b, p, "/")
    s = p[n]
    sub(/-[0-9a-f]+$/, "", s)
    if (s != "") { label = s }
    next
}
/^[[:space:]]*Doc-tests / { label = "doc-" $2; next }
/^test .* \.\.\. (ok|FAILED|ignored)/ {
    line = $0
    sub(/^test /, "", line)
    if (match(line, / \.\.\. (ok|FAILED|ignored)/)) {
        name = substr(line, 1, RSTART - 1)
        res = substr(line, RSTART + 5)
        sub(/,.*$/, "", res)
        sub(/[[:space:]].*$/, "", res)
        if (res == "ok" || res == "FAILED" || res == "ignored") {
            ran++
            print res "\t" label "::" name
        }
    }
}
END { print "RAN\t" ran }
' "$TRANSCRIPT" > "$TMPD/parsed"

RAN="$(awk -F'\t' '$1 == "RAN" { print $2 }' "$TMPD/parsed")"
[ -n "$RAN" ] || RAN=0

if [ "$RAN" -eq 0 ]; then
    echo "the transcript contains no test results — a suite that did not run is not a suite that passed" >&2
    echo "fail:test-baseline:no-test-results=$TRANSCRIPT"
    exit 2
fi

awk -F'\t' '$1 == "FAILED" { print $2 }' "$TMPD/parsed" | LC_ALL=C sort -u > "$TMPD/failed"
awk -F'\t' '$1 == "ok" { print $2 }' "$TMPD/parsed" | LC_ALL=C sort -u > "$TMPD/passed.raw"

# Comments and blank lines out; leading/trailing space and CR trimmed so an
# entry pasted from a Windows editor is still the key it looks like.
awk '
{
    sub(/\r$/, "")
    if ($0 ~ /^[[:space:]]*#/) { next }
    sub(/^[[:space:]]+/, "")
    sub(/[[:space:]]+$/, "")
    if ($0 == "") { next }
    print
}
' "$KNOWN_RED" | LC_ALL=C sort -u > "$TMPD/known"

# A key that BOTH passed and failed in one transcript is failing (two crates
# can ship identically-named test binaries). Fail-closed: it must not read as a
# stale entry.
LC_ALL=C comm -23 "$TMPD/passed.raw" "$TMPD/failed" > "$TMPD/passed"

LC_ALL=C comm -23 "$TMPD/failed" "$TMPD/known" > "$TMPD/new_red"
LC_ALL=C comm -12 "$TMPD/failed" "$TMPD/known" > "$TMPD/tolerated"
LC_ALL=C comm -12 "$TMPD/passed" "$TMPD/known" > "$TMPD/stale"

count_of() { awk 'END { print NR }' "$1"; }
NEW_RED="$(count_of "$TMPD/new_red")"
TOLERATED="$(count_of "$TMPD/tolerated")"
STALE="$(count_of "$TMPD/stale")"

FIRST=""
if [ "$NEW_RED" -gt 0 ]; then
    echo "NEW FAILURES not in $KNOWN_RED — this change broke them, or they broke and nobody said so:" >&2
    while IFS= read -r k; do
        [ -n "$k" ] && echo "  new-red: $k" >&2
    done < "$TMPD/new_red"
    FIRST="$(awk 'NR == 1 { print; exit }' "$TMPD/new_red")"
fi

if [ "$STALE" -gt 0 ]; then
    echo "STALE ENTRIES in $KNOWN_RED — these PASSED in this run and must be deleted from the list:" >&2
    while IFS= read -r k; do
        [ -n "$k" ] && echo "  stale: $k" >&2
    done < "$TMPD/stale"
    echo "  (a tolerated failure that has been fixed must stop being tolerated, or the" >&2
    echo "   next break of that same test is invisible)" >&2
    [ -n "$FIRST" ] || FIRST="$(awk 'NR == 1 { print; exit }' "$TMPD/stale")"
fi

if [ "$TOLERATED" -gt 0 ]; then
    while IFS= read -r k; do
        [ -n "$k" ] && echo "  known-red (tolerated): $k" >&2
    done < "$TMPD/tolerated"
fi

if [ "$NEW_RED" -gt 0 ] || [ "$STALE" -gt 0 ]; then
    echo "fail:test-baseline:ran=$RAN new-red=$NEW_RED tolerated=$TOLERATED stale=$STALE first=$FIRST"
    exit 1
fi

echo "ok:test-baseline:ran=$RAN new-red=0 tolerated=$TOLERATED stale=0"
exit 0
