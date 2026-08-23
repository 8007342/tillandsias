#!/usr/bin/env bash
# @trace order:757-qwqz, spec:forge-environment-discoverability
#
# Mid-session transport DEATH TRACE for the stdio MCP expert servers: when a
# server dies between health probes (the 2026-08-15 -32000 class), the dying
# process itself must append a record to the expert health log — the same
# JSONL the probe writes — so cycle-metrics's `mcp_outage:` line carries the
# outage into the handoff without any agent noticing anything. Clean stdin
# EOF must stay silent (the negative control), and an external signal ending
# an IDLE server must be visible but NOT counted as an outage.
#
# Vectors:
#   1 helper: signal with a request in flight  -> down / transport-died
#   2 helper: set -e abort (the 2026-08-15 class) -> down, rc recorded
#   3 helper: clean shutdown                   -> NO record (negative control)
#   4 real project-info: full session + EOF    -> NO record (negative control)
#   5 real project-info: TERM while idle       -> stopped / signal-idle,
#                                                 NOT matched by the
#                                                 cycle-metrics outage grep
#   6 real project-info: client vanishes mid-write (SIGPIPE with read_file in
#     flight — the witnessed cited-span-read shape) -> down / transport-died,
#     last_tool named, MATCHED by the cycle-metrics outage grep
#   7 real forge-plan: TERM while idle         -> stopped record names
#                                                 forge-plan (parity)
#
# GRAMMAR (exactly one line on stdout, last line):
#   ok:mcp-transport-death-trace:7
#   fail:<detail>
# Exit 0 on ok, 1 on fail.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED="$ROOT/images/default/config-overlay/mcp/mcp-usage-log.sh"
PROJECT_INFO="$ROOT/images/default/config-overlay/mcp/project-info.sh"
FORGE_PLAN="$ROOT/images/default/config-overlay/mcp/forge-plan.sh"

# The exact pattern cycle-metrics.sh counts as outages — asserted here so the
# two cannot drift silently: if cycle-metrics changes its grep, vector 5/6
# stop proving the ride-along and this literal must be updated with it.
OUTAGE_GREP='"state":"\(down\|absent\)"'

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcp-death-trace.XXXXXX")" || {
    echo "fail:mktemp"
    exit 1
}
SRV_PID=""
cleanup() {
    [ -n "$SRV_PID" ] && kill -9 "$SRV_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
    echo "fail:$1"
    exit 1
}

[ -r "$SHARED" ] || fail "missing:$SHARED"
[ -r "$PROJECT_INFO" ] || fail "missing:$PROJECT_INFO"
[ -r "$FORGE_PLAN" ] || fail "missing:$FORGE_PLAN"

# ── 1: helper — signal with a request in flight ─────────────────────────────
LOG="$WORK/v1.jsonl"
cat > "$WORK/v1.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$SHARED"
mcp_transport_guard "fixture-inflight"
mcp_tg_inflight "read_file"
kill -TERM \$\$
sleep 5
EOF
TILLANDSIAS_EXPERT_HEALTH_LOG="$LOG" bash "$WORK/v1.sh" 2>/dev/null
grep -q '"server":"fixture-inflight"' "$LOG" 2>/dev/null || fail "v1-no-record"
grep -q '"state":"down"' "$LOG" || fail "v1-not-down"
grep -q '"stage":"transport-died"' "$LOG" || fail "v1-wrong-stage"
grep -q '"signal":"TERM"' "$LOG" || fail "v1-no-signal"
grep -q '"last_tool":"read_file"' "$LOG" || fail "v1-no-last-tool"
grep -q '"advice":"filesystem-reads-sanctioned-for-rest-of-cycle"' "$LOG" || fail "v1-no-advice"

# ── 2: helper — set -e abort while a request is in flight ───────────────────
LOG="$WORK/v2.jsonl"
cat > "$WORK/v2.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$SHARED"
mcp_transport_guard "fixture-abort"
mcp_tg_inflight "grep_code"
false
EOF
TILLANDSIAS_EXPERT_HEALTH_LOG="$LOG" bash "$WORK/v2.sh" 2>/dev/null
grep -q '"server":"fixture-abort"' "$LOG" 2>/dev/null || fail "v2-no-record"
grep -q '"state":"down"' "$LOG" || fail "v2-not-down"
grep -q '"rc":1' "$LOG" || fail "v2-no-rc"

# ── 3: helper — clean shutdown writes nothing ───────────────────────────────
LOG="$WORK/v3.jsonl"
cat > "$WORK/v3.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$SHARED"
mcp_transport_guard "fixture-clean"
mcp_tg_inflight "read_file"
mcp_tg_done
mcp_tg_clean_shutdown
exit 0
EOF
TILLANDSIAS_EXPERT_HEALTH_LOG="$LOG" bash "$WORK/v3.sh" 2>/dev/null || fail "v3-nonzero-exit"
[ -s "$LOG" ] && fail "v3-clean-shutdown-wrote-record"

# ── 4: real project-info — full session then EOF stays silent ───────────────
LOG="$WORK/v4.jsonl"
{
    printf '{"jsonrpc":"2.0","id":1,"method":"initialize"}\n'
    printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"project_type","arguments":{"path":"."}}}\n'
} > "$WORK/v4-requests.jsonl"
(cd "$ROOT" && TILLANDSIAS_EXPERT_HEALTH_LOG="$LOG" \
    TILLANDSIAS_EXPERT_USAGE_LOG="$WORK/usage.jsonl" \
    bash "$PROJECT_INFO" < "$WORK/v4-requests.jsonl" > "$WORK/v4-out.jsonl" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || fail "v4-server-rc-$rc"
grep -q '"id":2' "$WORK/v4-out.jsonl" || fail "v4-call-unanswered"
[ -s "$LOG" ] && fail "v4-clean-eof-wrote-record"

# run_fifo_server <server-path> <health-log>: launch on FIFOs, fds 7 (stdin
# write end) and 8 (stdout read end) held by this shell. Sets SRV_PID.
# `exec env` so $! IS the server process — a plain `(cd && bash …) &` makes
# $! the wrapper subshell, and a TERM sent there never reaches the server
# (vector 5 failed exactly that way on first run).
run_fifo_server() {
    rm -f "$WORK/in" "$WORK/out"
    mkfifo "$WORK/in" "$WORK/out" || fail "mkfifo"
    (cd "$ROOT" && exec env TILLANDSIAS_EXPERT_HEALTH_LOG="$2" \
        TILLANDSIAS_EXPERT_USAGE_LOG="$WORK/usage.jsonl" \
        bash "$1" < "$WORK/in" > "$WORK/out" 2>/dev/null) &
    SRV_PID=$!
    exec 7>"$WORK/in" || fail "fifo-in-open"
    exec 8<"$WORK/out" || fail "fifo-out-open"
}

# ── 5: real project-info — TERM while idle is visible, not an outage ────────
LOG="$WORK/v5.jsonl"
run_fifo_server "$PROJECT_INFO" "$LOG"
printf '{"jsonrpc":"2.0","id":1,"method":"initialize"}\n' >&7
IFS= read -t 15 -r _resp <&8 || fail "v5-no-initialize-response"
kill -TERM "$SRV_PID" 2>/dev/null
wait "$SRV_PID" 2>/dev/null
SRV_PID=""
exec 7>&- 8<&-
grep -q '"server":"project-info"' "$LOG" 2>/dev/null || fail "v5-no-record"
grep -q '"state":"stopped"' "$LOG" || fail "v5-not-stopped"
grep -q '"stage":"signal-idle"' "$LOG" || fail "v5-wrong-stage"
n="$(grep -c "$OUTAGE_GREP" "$LOG")" || true
[ "${n:-0}" -eq 0 ] || fail "v5-idle-signal-counted-as-outage"

# ── 6: real project-info — client vanishes mid-write (the witnessed shape) ──
LOG="$WORK/v6.jsonl"
seq 1 60000 > "$WORK/big.txt"
run_fifo_server "$PROJECT_INFO" "$LOG"
printf '{"jsonrpc":"2.0","id":1,"method":"initialize"}\n' >&7
IFS= read -t 15 -r _resp <&8 || fail "v6-no-initialize-response"
printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"%s"}}}\n' "$WORK/big.txt" >&7
# The ~400KB response overflows the 64KB pipe buffer; the server blocks
# writing it with read_file still in flight. Give it a moment to get there,
# then vanish: closing the read end delivers SIGPIPE to the blocked write.
sleep 2
exec 8<&- 7>&-
wait "$SRV_PID" 2>/dev/null
SRV_PID=""
grep -q '"server":"project-info"' "$LOG" 2>/dev/null || fail "v6-no-record"
grep -q '"state":"down"' "$LOG" || fail "v6-not-down"
grep -q '"stage":"transport-died"' "$LOG" || fail "v6-wrong-stage"
grep -q '"last_tool":"read_file"' "$LOG" || fail "v6-no-last-tool"
n="$(grep -c "$OUTAGE_GREP" "$LOG")" || true
[ "${n:-0}" -ge 1 ] || fail "v6-death-not-counted-as-outage"

# ── 7: real forge-plan — the guard is armed there too ───────────────────────
LOG="$WORK/v7.jsonl"
run_fifo_server "$FORGE_PLAN" "$LOG"
printf '{"jsonrpc":"2.0","id":1,"method":"initialize"}\n' >&7
IFS= read -t 20 -r _resp <&8 || fail "v7-no-initialize-response"
kill -TERM "$SRV_PID" 2>/dev/null
wait "$SRV_PID" 2>/dev/null
SRV_PID=""
exec 7>&- 8<&-
grep -q '"server":"forge-plan"' "$LOG" 2>/dev/null || fail "v7-no-record"
grep -q '"state":"stopped"' "$LOG" || fail "v7-not-stopped"

echo "ok:mcp-transport-death-trace:7"
exit 0
