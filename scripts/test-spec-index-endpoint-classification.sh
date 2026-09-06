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

# 1077-vzwq: THE COUNT MUST BE OF ARMS THAT RAN, NOT OF ARMS THAT EXIST.
# This file used to end with an unconditional
#   echo "PASS: ... 4/4 (absent-not-refused, refused-negative-control, ...)"
#   echo "ok:spec-index-endpoint-classification-fixture:4"
# reached by straight-line flow after case 2's own `else` branch had printed
# SKIP. So on every host without nmap-ncat — this one, stock macOS, MSYS,
# and any Debian/Ubuntu shipping netcat-openbsd — the fixture announced that
# it had established the absent/refused distinction while the ONLY arm that
# establishes it never executed. The file's own comment on case 2 says case 1
# alone "could be satisfied by renaming every failure to 'absent'", so the
# claim was not merely over-counted, it was the one claim the run could not
# support. Arms are now counted as they run and skips are named in the verdict.
ARMS_TOTAL=4
ARMS_RUN=0
ARMS_SKIPPED=()
_ran()     { ARMS_RUN=$((ARMS_RUN + 1)); echo "ok: $*"; }
_skipped() { ARMS_SKIPPED+=("$1"); echo "skip:spec-index-endpoint-classification:$1: $2"; }

# 1077-vzwq: probe by REQUIRING curl's exit 7, not by curl merely failing.
# The old loop advanced only while curl SUCCEEDED, so it treated rc 52 (empty
# reply) and rc 56 (recv failure) as proof the port was free — which is exactly
# the "something answered" / "nothing is there" distinction this whole fixture
# exists to pin, decided the wrong way in the fixture's own setup. A co-tenant
# holding the port without speaking HTTP made case 1 report
# embed-endpoint-unreachable and reds the gate against a correct classifier.
_nothing_listening() {
    local _rc=0
    curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$1" >/dev/null 2>&1 || _rc=$?
    [ "$_rc" -eq 7 ]
}

# 1077-vzwq: base chosen BELOW the ephemeral range on every target host
# (Linux /proc/sys/net/ipv4/ip_local_port_range is 32768-60999 here; macOS
# uses 49152-65535). The old 45917/45918 sat inside both, so any transient
# outbound connection on a shared runner could occupy them mid-run.
_find_free_port() {
    local _p="$1" _limit=$(( $1 + 50 ))
    while [ "$_p" -lt "$_limit" ]; do
        if _nothing_listening "$_p"; then printf '%s' "$_p"; return 0; fi
        _p=$((_p + 1))
    done
    return 1
}

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
    #
    # TMPDIR is pinned inside $WORK too: it is operator-settable (:457) and
    # redirects STAGING out of the checkout root, so leaving it inherited left
    # one seam open that the other three variables had closed.
    local _raw=""
    _raw="$(
        FORGE_SPEC_INDEX_ROOT="" \
        TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1 \
        TILLANDSIAS_SPEC_INDEX_TMPDIR="$WORK/stage" \
        TILLANDSIAS_SPEC_INDEX_CHECKOUT="$WORK" \
        TILLANDSIAS_EMBED_ENDPOINT="$1" \
            bash "$SCRIPT" 2>"$WORK/err.txt"
    )" || true
    # No pipeline: the producer's stdout is captured first, so there is no
    # early-exiting consumer for it to take SIGPIPE from (792-ksr8). `skip:`
    # is matched as well as `blocked:` — see the precondition note below.
    grep -m1 -E '^(blocked|skip):spec-index:' <<<"$_raw" || true
}

# 1077-vzwq: A MISSING TOOL IS A SKIP, NOT A WRONG VERDICT.
# run_against used to filter to '^blocked:spec-index:' alone, so the producer's
# honest, exit-0 precondition refusals — skip:spec-index:no-jq and
# skip:spec-index:no-curl (spec-index-ensure.sh:381-383),
# skip:spec-index:no-plan-binary (:404) — collapsed to the empty string and
# landed in case 1's `*)` arm as "expected embed-endpoint-absent, got ''". That
# reds the gate on any host without jq (all stock macOS) and accuses the
# classifier of the wrong verdict when the true fact is that this host cannot
# exercise it. Matching `skip:` here lets each arm defer to the producer's OWN
# precondition logic rather than duplicating it, so the two cannot drift.
_is_skip() { case "$1" in skip:spec-index:*) return 0 ;; *) return 1 ;; esac; }

command -v curl >/dev/null 2>&1 || {
    _skipped no-curl "the fixture's own port probe needs curl"
    echo "PASS: spec-index endpoint classification fixture 0/$ARMS_TOTAL ran (no curl on this host)"
    echo "ok:spec-index-endpoint-classification-fixture:0"
    exit 0
}

CLOSED_PORT="$(_find_free_port 19917)" || fail "no free port in 19917-19966 to use as the closed-port arm"

# --- case 1: NOTHING LISTENING is `absent`, not `refused` --------------------
# The exact 2026-08-25 case. curl exits 7; no server ever answered, so no server
# refused anything.
out="$(run_against "http://127.0.0.1:$CLOSED_PORT/v1")"
if _is_skip "$out"; then
    _skipped absent-not-refused "producer declined a precondition: $out"
else
    case "$out" in
        blocked:spec-index:embed-endpoint-absent) ;;
        blocked:spec-index:embed-endpoint-refused)
            fail "case 1: a closed port must NOT read as 'refused' — that names the wrong subject (811-28eh), got '$out'" ;;
        *) fail "case 1: expected embed-endpoint-absent, got '$out'" ;;
    esac
    grep -q "NOTHING IS LISTENING" "$WORK/err.txt" \
        || fail "case 1: the absent verdict must say so in words, stderr was: $(head -c 300 "$WORK/err.txt")"
    _ran "case 1 — a closed port reads as ABSENT, and says nothing is listening"
fi

# --- case 2 (NEGATIVE CONTROL): a server that ANSWERS >=400 IS `refused` -----
# Without this, case 1 could be satisfied by renaming every failure to 'absent',
# which would destroy the distinction rather than establish it.
#
# Needs nmap-ncat specifically: BSD nc (macOS) and netcat-openbsd (Debian,
# Ubuntu) have no --sh-exec, and MSYS ships no nc at all. Detected rather than
# attempted, so the skip names the real reason.
_case2_prereq=""
command -v nc >/dev/null 2>&1 || _case2_prereq="no nc on PATH"
if [ -z "$_case2_prereq" ]; then
    # Captured, then matched: `nc -h | grep -q` is the 792-ksr8 shape, and here
    # a SIGPIPE 141 under pipefail would read as "nc lacks --sh-exec" and
    # silently disable the negative control on a host that HAS nmap-ncat.
    _nc_help="$(nc -h 2>&1 || true)"
    grep -q -- '--sh-exec' <<<"$_nc_help" || _case2_prereq="nc lacks --sh-exec (needs nmap-ncat)"
fi
[ -n "$_case2_prereq" ] || command -v timeout >/dev/null 2>&1 || _case2_prereq="no timeout(1)"

if [ -n "$_case2_prereq" ]; then
    _skipped refused-negative-control "$_case2_prereq; classification of >=400 unverified here"
else
    PORT="$(_find_free_port $((CLOSED_PORT + 1)))" || fail "no free port for the case 2 listener"
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
    # Wait for the listener rather than assuming it came up. `kill -0` is the
    # 1077-vzwq addition: without it a listener that dies instantly still burns
    # the full 40 x 0.25s before skipping, which was ~10s on EVERY host that
    # reaches this branch and fails to bind.
    _tries=0
    until curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$PORT" 2>/dev/null; do
        kill -0 "$NCPID" 2>/dev/null || break
        [ "$_tries" -ge 40 ] && break
        _tries=$((_tries + 1)); sleep 0.25
    done
    if ! kill -0 "$NCPID" 2>/dev/null || [ "$_tries" -ge 40 ]; then
        _skipped refused-negative-control "could not bring up a local listener; classification of >=400 unverified here"
    else
        out="$(run_against "http://127.0.0.1:$PORT/v1")"
        if _is_skip "$out"; then
            _skipped refused-negative-control "producer declined a precondition: $out"
        else
            case "$out" in
                blocked:spec-index:embed-endpoint-refused) ;;
                blocked:spec-index:embed-endpoint-absent)
                    fail "case 2: a server that ANSWERED 400 must read as 'refused', not 'absent' — got '$out'" ;;
                *) fail "case 2: expected embed-endpoint-refused, got '$out'" ;;
            esac
            _ran "case 2 — a server answering 400 reads as REFUSED (the distinction is real)"
        fi
    fi
    kill "$NCPID" 2>/dev/null; NCPID=""
fi

# --- case 3: the classifier derives from MEASURED signals, not a guess -------
# Pins that every arm keys on curl's exit code, so a future edit cannot
# reintroduce a single hardcoded verdict for all failures. Behavioural checks
# above prove two arms; this proves the others EXIST and are reachable by code
# rather than being aspirational comments.
#
# 1077-vzwq: SCAN CODE, NOT PROSE. These greps ran over the whole file, and
# spec-index-ensure.sh documents its own verdict tokens in the comment block at
# :766-772 — so embed-endpoint-refused matched 3 times with only 1 of them
# code, and deleting the live arm would still have satisfied this check from
# the comments alone. That is precisely the "aspirational comments" failure the
# paragraph above says the case exists to prevent, and the check was subject to
# it. Comments are stripped first (1055-6yp8).
SCRIPT_CODE="$(sed 's/#.*//' "$SCRIPT")"
for tok in embed-endpoint-absent embed-endpoint-timeout embed-endpoint-died-mid-request embed-endpoint-unreachable embed-endpoint-refused; do
    grep -q "$tok" <<<"$SCRIPT_CODE" || fail "case 3: classifier arm '$tok' is missing from the CODE of $SCRIPT (comments do not count)"
done
grep -q '_curl_rc' <<<"$SCRIPT_CODE" || fail "case 3: classification must key on curl's exit code"
_ran "case 3 — every classifier arm exists in code and keys on a measured signal"

# --- case 4: the mid-request death is distinguishable from never-reachable ---
# 811-28eh's headline symptom is an endpoint that serves 200s and then vanishes.
# The counter is what separates that from an endpoint that was never up; without
# it both collapse to 'unreachable' and the packet's own signature is invisible.
grep -q '_embed_batches_ok' <<<"$SCRIPT_CODE" \
    || fail "case 4: no completed-batch counter — a mid-workload death cannot be distinguished from an absent endpoint"
grep -q 'died-mid-request' <<<"$SCRIPT_CODE" \
    || fail "case 4: no died-mid-request verdict"
_ran "case 4 — a death after successful batches is a distinct, reachable verdict"

if [ "${#ARMS_SKIPPED[@]}" -gt 0 ]; then
    echo "PASS: spec-index endpoint classification fixture $ARMS_RUN/$ARMS_TOTAL ran; SKIPPED: ${ARMS_SKIPPED[*]}"
    # Name the consequence, not just the skip. A reader who sees 3/4 should not
    # have to know which arm carries the negative control to know what the run
    # did and did not establish.
    case " ${ARMS_SKIPPED[*]} " in
        *" refused-negative-control "*)
            echo "note: the absent/refused DISTINCTION is unestablished on this host — case 1 alone is satisfiable by renaming every failure to 'absent'" ;;
    esac
else
    echo "PASS: spec-index endpoint classification fixture $ARMS_RUN/$ARMS_TOTAL (absent-not-refused, refused-negative-control, arms-are-measured, death-distinguishable)"
fi
echo "ok:spec-index-endpoint-classification-fixture:$ARMS_RUN"
exit 0
