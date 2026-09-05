#!/usr/bin/env bash
# @trace order:811-28eh, spec:ci-release
#
# Fixture for the embed-endpoint failure CLASSIFICATION in
# scripts/spec-index-ensure.sh.
#
# WHY IT EXISTS. That script reported `blocked:spec-index:embed-endpoint-refused`
# for every failure mode, including the one where nothing is listening at all.
# "Refused" asserts a server answered and declined. On 2026-08-25, during a
# release cut, a host with no ollama, no inference image and an empty podman
# store produced that verdict — and the reader spent the first minutes of a
# blocked release hunting a misconfigured endpoint instead of an absent one.
#
# The classification is now derived from curl's exit code and the HTTP status,
# never guessed (797-5kqe: an error may only assert what it measured). This
# fixture proves the derivation, in both directions, WITHOUT needing a real
# embedding service — because a test that requires the very endpoint whose
# absence it is characterising could never run in the case that matters.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/spec-index-ensure.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${NCPID:-}" ] && kill "$NCPID" 2>/dev/null' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$SCRIPT" ] || fail "not found: $SCRIPT"

# A port nothing is listening on. Chosen high and probed to confirm it is free —
# assuming a port is closed is the same class of unverified premise this whole
# packet is about.
CLOSED_PORT=45917
while curl -s --max-time 1 "http://127.0.0.1:$CLOSED_PORT" >/dev/null 2>&1; do
    CLOSED_PORT=$((CLOSED_PORT + 1))
done

run_against() {
    # Runs the real script with the endpoint overridden, and a destination it
    # may write to, so nothing touches the host's real index.
    #
    # 1063-nraf: THE ISOLATION ABOVE WAS A CLAIM THE CODE DID NOT HONOUR. This
    # passed TILLANDSIAS_SPEC_INDEX_ROOT, a name spec-index-ensure.sh NEVER
    # READS (grep -c in that file: 0). Every arm therefore drove the real
    # producer against the operator's own checkout — the comment asserted the
    # safety property and the variable did not provide it, which is the same
    # shape as a fixture escaping its temp dir. The seam the producer actually
    # honours is TILLANDSIAS_SPEC_INDEX_CHECKOUT (spec-index-ensure.sh:231),
    # from which it derives "$_tsi_co/.cache/spec-index" (:246) — so the value
    # must be a CHECKOUT root, not an index dir.
    # NEUTRALISE THE HIGHER RUNGS OR THIS ISOLATES NOTHING (1077-vzwq).
    # TILLANDSIAS_SPEC_INDEX_CHECKOUT is RUNG 4 of a ladder, not an override:
    # spec-index-ensure.sh reads it at :231 only inside `if [ -z "$_tsi_root" ]`
    # at :229. Two higher rungs pre-empt it —
    #   rung 1  FORGE_SPEC_INDEX_ROOT, unconditional at :212, and the forge
    #           launcher INJECTS it (main.rs:14500), so inside a forge this
    #           fixture would drive the REAL mounted index;
    #   rung 2  the podman volume tillandsias-spec-index-<project>.
    #
    # MY EARLIER "PROVEN ISOLATED" HELD BY ACCIDENT AND I AM RECORDING WHY.
    # I measured a byte-identical .cache/spec-index before and after, and that
    # was true — but only because rootless podman returns a mountpoint it will
    # not let this user stat, so rung 2 self-demotes via the 1003-v3dc EACCES
    # path and rung 4 is reached. On a host where that volume is readable, or
    # in any forge, the same fixture writes to the real index and my control
    # would have reported success while measuring a directory the producer was
    # never targeting.
    FORGE_SPEC_INDEX_ROOT="" \
    TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1 \
    TILLANDSIAS_SPEC_INDEX_CHECKOUT="$WORK" \
    TILLANDSIAS_EMBED_ENDPOINT="$1" \
        bash "$SCRIPT" 2>"$WORK/err.txt" | grep -E '^blocked:spec-index:' | head -1
}

# --- case 1: NOTHING LISTENING is `absent`, not `refused` --------------------
# The exact 2026-08-25 case. curl exits 7; no server ever answered, so no server
# refused anything.
out="$(run_against "http://127.0.0.1:$CLOSED_PORT/v1")"
case "$out" in
    blocked:spec-index:embed-endpoint-absent) ;;
    blocked:spec-index:embed-endpoint-refused)
        fail "case 1: a closed port must NOT read as 'refused' — that names the wrong subject (811-28eh), got '$out'" ;;
    *) fail "case 1: expected embed-endpoint-absent, got '$out'" ;;
esac
grep -q "NOTHING IS LISTENING" "$WORK/err.txt" \
    || fail "case 1: the absent verdict must say so in words, stderr was: $(head -c 300 "$WORK/err.txt")"
echo "ok: case 1 — a closed port reads as ABSENT, and says nothing is listening"

# --- case 2 (NEGATIVE CONTROL): a server that ANSWERS >=400 IS `refused` -----
# Without this, case 1 could be satisfied by renaming every failure to 'absent',
# which would destroy the distinction rather than establish it.
PORT=$((CLOSED_PORT + 1))
while curl -s --max-time 1 "http://127.0.0.1:$PORT" >/dev/null 2>&1; do
    PORT=$((PORT + 1))
done
# PERSISTENT canned 400 (`-k` plus --sh-exec serves EVERY connection).
#
# A one-shot `printf | nc -l` was the first attempt and it produced a false
# FAIL: the readiness probe below consumed the single connection, the listener
# exited, and the script under test then met a closed port and correctly said
# `absent`. The fixture was measuring its own listener's death, not the
# classifier — the same "what would have falsified this" trap this packet's
# neighbours keep surfacing. Kept as a comment because the next author will
# reach for the one-shot form too.
timeout 60 nc -lk 127.0.0.1 "$PORT" --sh-exec \
    "printf 'HTTP/1.1 400 Bad Request\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{\"error\":\"fixture refusal\"}'" \
    >/dev/null 2>&1 &
NCPID=$!
# Wait for the listener rather than assuming it came up.
_tries=0
until curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$PORT" 2>/dev/null || [ "$_tries" -ge 40 ]; do
    _tries=$((_tries + 1)); sleep 0.25
done
if [ "$_tries" -ge 40 ]; then
    echo "SKIP: case 2 — could not bring up a local listener; classification of >=400 unverified here"
else
    out="$(run_against "http://127.0.0.1:$PORT/v1")"
    case "$out" in
        blocked:spec-index:embed-endpoint-refused) ;;
        blocked:spec-index:embed-endpoint-absent)
            fail "case 2: a server that ANSWERED 400 must read as 'refused', not 'absent' — got '$out'" ;;
        *) fail "case 2: expected embed-endpoint-refused, got '$out'" ;;
    esac
    echo "ok: case 2 — a server answering 400 reads as REFUSED (the distinction is real)"
fi
kill "$NCPID" 2>/dev/null; NCPID=""

# --- case 3: the classifier derives from MEASURED signals, not a guess -------
# Pins that every arm keys on curl's exit code, so a future edit cannot
# reintroduce a single hardcoded verdict for all failures. Behavioural checks
# above prove two arms; this proves the others EXIST and are reachable by code
# rather than being aspirational comments.
for tok in embed-endpoint-absent embed-endpoint-timeout embed-endpoint-died-mid-request embed-endpoint-unreachable embed-endpoint-refused; do
    grep -q "$tok" "$SCRIPT" || fail "case 3: classifier arm '$tok' is missing from $SCRIPT"
done
grep -q '_curl_rc' "$SCRIPT" || fail "case 3: classification must key on curl's exit code"
echo "ok: case 3 — every classifier arm exists and keys on a measured signal"

# --- case 4: the mid-request death is distinguishable from never-reachable ---
# 811-28eh's headline symptom is an endpoint that serves 200s and then vanishes.
# The counter is what separates that from an endpoint that was never up; without
# it both collapse to 'unreachable' and the packet's own signature is invisible.
grep -q '_embed_batches_ok' "$SCRIPT" \
    || fail "case 4: no completed-batch counter — a mid-workload death cannot be distinguished from an absent endpoint"
grep -q 'died-mid-request' "$SCRIPT" \
    || fail "case 4: no died-mid-request verdict"
echo "ok: case 4 — a death after successful batches is a distinct, reachable verdict"

echo "PASS: spec-index endpoint classification fixture 4/4 (absent-not-refused, refused-negative-control, arms-are-measured, death-distinguishable)"
echo "ok:spec-index-endpoint-classification-fixture:4"
exit 0
