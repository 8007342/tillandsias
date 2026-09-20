#!/usr/bin/env bash
# @trace spec:ci-release
# @trace order:1307-kic6
#
# THE GUARD THE CHECKER'S OWN COMMENT DESCRIBES. check-fragment-status-loss.sh
# says of its fallback: "Slower is acceptable; checking NOTHING is not, and an
# empty map would silently pass every packet." Batching its three per-fragment
# plan-binary calls into three batched calls is a performance change on exactly
# that path, so this fixture exists to make the batching unable to buy speed by
# losing a verdict.
#
# WHAT IT PLANTS: one UNPARSEABLE fragment among many good ones, and it requires
# that the batch still names THAT FILE, before and after. A batch that returned
# one exit code for 1302 fragments would pass every other test and turn a
# parse-error detector into a silent pass -- which is 787-f7dh exactly, the
# order that exists because "declares no terminal events" and "could not be
# read" were once the same answer.
#
# PRE-FIX RESULT (the cost that forced the batching), measured on yolanda:
#   3 plan-binary calls per fragment x 1302 fragments x 134 ms = ~523 s
#   after batching:                                               ~250 s
#   after hoisting an IFS command substitution out of a read loop:   9 s
# The middle number is there deliberately: the batching alone left a second
# per-item spawn inside the fix (3941 printf forks against 25 plan-binary
# invocations), and only the trace found it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

. scripts/plan-binary-probe.sh 2>/dev/null || true
PLAN="${TILLANDSIAS_PLAN_BINARY:-}"
if [ -z "$PLAN" ] && command -v resolve_plan_binary >/dev/null 2>&1; then
    PLAN="$(resolve_plan_binary 2>/dev/null || true)"
fi
[ -n "${PLAN:-}" ] || { echo "unmeasured:fragment-batch:no-plan-binary-resolved"; exit 0; }

fail=0
_ok()  { echo "ok: $1"; }
_bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
D="$TMP/frags"; mkdir -p "$D"

# Good fragments, one of which declares a terminal event and an addressed event
# so the batch has real payload to report and cannot pass by being empty.
cat > "$D/a-good.yaml" <<'YAML'
events:
  - packet_id: some-packet-that-exists
    event:
      type: note
      ts: "2026-09-20T00:00:00Z"
      host: fixture
      summary: a plain note
YAML
cat > "$D/b-good.yaml" <<'YAML'
events:
  - packet_id: another-packet
    event:
      type: completed
      ts: "2026-09-20T00:00:01Z"
      host: fixture
      summary: a terminal event
YAML
# THE PLANTED DEFECT: invalid YAML, sitting between good files by sort order.
printf 'packets:\n  - packet_id: broken\n    bad: ": "unclosed\n' > "$D/m-broken.yaml"
cat > "$D/z-good.yaml" <<'YAML'
events:
  - packet_id: third-packet
    event:
      type: note
      ts: "2026-09-20T00:00:02Z"
      host: fixture
      summary: another note
YAML

for sub in fragment-terminal-events fragment-event-packets fragment-misplaced-definitions; do
    out="$("$PLAN" "$sub" "$D"/*.yaml 2>/dev/null)"

    # ARM 1 -- the bad file is named, by name, as unparseable.
    case "$out" in
        *"unparseable"*"m-broken.yaml"*)
            _ok "$sub: the unparseable fragment is named individually" ;;
        *)
            _bad "$sub: the unparseable fragment was NOT named; a batch swallowed a verdict"
            printf '%s\n' "$out" | head -5 ;;
    esac

    # ARM 2 -- the good files still get their own verdicts. Without this, a
    # batch that reported ONLY the failure would pass arm 1 while losing the
    # other 1301 answers.
    for good in a-good b-good z-good; do
        case "$out" in
            *"ok"*"$good.yaml"*) : ;;
            *) _bad "$sub: good fragment $good.yaml has no verdict line" ;;
        esac
    done

    # ARM 3 -- CARDINALITY, not mere presence. One frame per input file at
    # minimum; a collapsed batch would print fewer.
    frames="$(printf '%s\n' "$out" | awk 'NF {n++} END {print n+0}')"
    if [ "$frames" -ge 4 ]; then
        _ok "$sub: $frames frames for 4 inputs"
    else
        _bad "$sub: only $frames frames for 4 inputs -- verdicts were collapsed"
    fi
done

# ARM 4 -- SINGLE-PATH CALLERS ARE UNCHANGED. The batching must not alter the
# contract every existing caller depends on: legacy output, and exit 3 for an
# unparseable fragment (787-f7dh).
"$PLAN" fragment-terminal-events "$D/m-broken.yaml" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 3 ]; then
    _ok "single-path mode still exits 3 on an unparseable fragment"
else
    _bad "single-path mode exited $rc, not 3 -- the legacy contract changed"
fi
legacy="$("$PLAN" fragment-event-packets "$D/a-good.yaml" 2>/dev/null)"
case "$legacy" in
    *"	"*) _bad "single-path mode emitted framed output; it must stay legacy" ;;
    *some-packet-that-exists*) _ok "single-path mode still emits bare ids" ;;
    *) _bad "single-path mode emitted neither a bare id nor a frame: $legacy" ;;
esac

[ "$fail" -eq 0 ] && echo "ok:fragment-batch-never-collapses-verdicts:all" || echo "FAIL:fragment-batch-never-collapses-verdicts"
exit "$fail"
