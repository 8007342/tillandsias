#!/bin/bash
# freshness: refreshed 2026-08-14 linux-immutable-20260814
set -uo pipefail
# @trace spec:meta-orchestration
# @trace order:737-zcj5, invariant:plan_is_queried_via_mcp_server_avoiding_heuristic_parsing
#
# check-mcp-expert-health.sh: the executable MCP-expert liveness probe (order
# 737-zcj5).
#
# WHY THIS EXISTS. `mcp_first_read_path` names three reasons to drop to the
# filesystem, and says of the first: "unavailable (MCP down or
# confidence=unsupported — fall back and keep going, THEN RECORD IT so a
# systematically-refusing expert stays visible)". On 2026-08-14 that rule was
# honoured halfway on two hosts in the same day: both fell back, both kept
# going, neither recorded anything.
#
#   windows  all 28 deferred MCP tools vanished mid-session; the host used
#            tillandsias-plan.exe for every subsequent read and write and said
#            nothing. The operator reconnected the servers by hand.
#   linux    the experts were never registered host-side AT ALL — .mcp.json is
#            absent and ~/.claude.json carries an empty mcpServers for this
#            project — so every expert call would have been unavailable. The
#            cycle used ./target/release/tillandsias-plan and carried on.
#
# Neither outage is visible anywhere in the ledger. That is the defect: recording
# depended on an agent noticing and choosing to write it down, which is the same
# "a guard only an attentive agent honors is a suggestion" shape this milestone
# keeps repairing. cycle-metrics.sh reports per-server CALL VOLUME, which cannot
# see this: a server that is DOWN produces no usage rows, and so does a server
# nobody called. Both render as absence.
#
# THE PROBE IS THE MECHANISM. It runs from Start-Of-Cycle, writes one JSONL
# record per expected expert unconditionally, and prints one verdict line. The
# trace therefore exists whether or not any agent thinks to write one, which is
# exit criterion 1. cycle-metrics.sh reads the log and reports `health=` on the
# `mcp:` line, which is exit criterion 2 — `down` and `never called` stop being
# the same observation.
#
# ADVISORY, NEVER A GATE. An unavailable expert is a degraded read path, never a
# blocked cycle (`filesystem_fallback.unavailable`, and "'Tis broken? keep
# goin'"). A non-zero exit here means RECORD AND CONTINUE. This is deliberately
# unlike check-credential-channel.sh, whose non-zero exit does fail the cycle:
# a missing push channel silently destroys work, while a missing expert only
# makes reads more expensive.
#
# NEGATIVE CONTROL (exit criterion 3). A healthy session prints
# `ok:experts-healthy` and nothing else — no outage line from cycle-metrics.sh,
# no ledger artifact. A signal that fires every cycle is one nobody reads, which
# is this milestone's own recurring failure.
#
# VERDICT GRAMMAR (pinned by litmus:mcp-expert-health-probe-shape; agents and CI
# branch on these, never on prose):
#   ^(ok:experts-healthy|down:[a-z0-9-]+(,[a-z0-9-]+)*|absent:not-registered|skip:[a-z0-9-]+)$
#
#   ok:experts-healthy     every expected expert is registered and answered the
#                          MCP initialize handshake
#   down:<csv>             registered but did NOT answer — the outage case, name
#                          ordered as given in the expected set
#   absent:not-registered  no registration source names any expected expert;
#                          this environment has no experts to lose
#   skip:<reason>          the probe could not run (no jq, no probe transport)
#
# Exit: 0 healthy, 1 down, 2 absent, 3 skip.
#
# Testability seams (used by the litmus fixture):
#   TILLANDSIAS_MCP_REGISTRATION   explicit registration JSON path
#   TILLANDSIAS_MCP_EXPECTED       CSV of expected expert names
#   TILLANDSIAS_EXPERT_HEALTH_LOG  JSONL destination
#   TILLANDSIAS_MCP_PROBE_TIMEOUT  per-server handshake budget in seconds

EXPECTED_DEFAULT="forge-plan,project-info"
EXPECTED="${TILLANDSIAS_MCP_EXPECTED:-$EXPECTED_DEFAULT}"
HEALTH_LOG="${TILLANDSIAS_EXPERT_HEALTH_LOG:-/tmp/forge-expert-health.jsonl}"
PROBE_TIMEOUT="${TILLANDSIAS_MCP_PROBE_TIMEOUT:-10}"

# Best-effort by construction, mirroring mcp-usage-log.sh: telemetry must never
# break the surface it measures, so every append is wrapped and silenced.
health_record() {
    _hr_server="$1"; _hr_state="$2"; _hr_ms="${3:-}"
    {
        _hr_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        _hr_line="$(printf '{"ts":"%s","server":"%s","state":"%s","host":"%s"' \
            "$_hr_ts" "$_hr_server" "$_hr_state" "${TILLANDSIAS_HOST_KIND:-unknown}")"
        case "$_hr_ms" in
            '' | *[!0-9]*) : ;;
            *) _hr_line="${_hr_line}$(printf ',"probe_ms":%s' "$_hr_ms")" ;;
        esac
        _hr_line="${_hr_line}}"
        printf '%s\n' "$_hr_line" >>"$HEALTH_LOG"
    } 2>/dev/null || true
    return 0
}

# Resolve the registration file that actually governs this environment. Order
# matters: an explicit seam beats the forge overlay, which beats the repo-local
# .mcp.json, which beats the user-global Claude config.
registration_file() {
    if [ -n "${TILLANDSIAS_MCP_REGISTRATION:-}" ]; then
        [ -f "$TILLANDSIAS_MCP_REGISTRATION" ] && printf '%s\n' "$TILLANDSIAS_MCP_REGISTRATION"
        return 0
    fi
    for cand in \
        "${HOME:-/nonexistent}/.config-overlay/claude/mcp.json" \
        "./.mcp.json" \
        "${HOME:-/nonexistent}/.claude.json"; do
        [ -f "$cand" ] || continue
        printf '%s\n' "$cand"
        return 0
    done
    return 0
}

# Extract a server's launch command. ~/.claude.json scopes servers per project,
# so try the project map before the top-level one; an empty result means this
# file does not register that server at all.
#
# `args` IS LOAD-BEARING — do not reduce this to `.command`. The repo's own
# .mcp.json registers `command: "bash"` with the server script in `args`, so
# reading `.command` alone probes a bare `bash`, which consumes the handshake
# frame as a shell script and reports every healthy expert as DOWN. That false
# positive was produced by the first draft of this very script. `@sh` emits a
# shell-quoted argv so a path containing spaces survives `sh -c`.
server_command() {
    _sc_file="$1"; _sc_name="$2"
    jq -r --arg s "$_sc_name" --arg p "$PWD" '
        ((.projects[$p]?.mcpServers[$s]?) // (.mcpServers[$s]?) // empty)
        | select(type == "object" and (.command | type == "string"))
        | ([.command] + ((.args // []) | map(tostring)))
        | @sh
    ' "$_sc_file" 2>/dev/null | grep -m1 . || true
}

# A genuine liveness test, not a file-existence check: speak the MCP stdio
# handshake and require a well-formed initialize RESULT back. A server binary
# that exists but wedges on startup is exactly the outage this must catch, and
# `test -x` would call it healthy.
probe_server() {
    _ps_cmd="$1"
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"tillandsias-health-probe","version":"1"}}}' \
        | timeout "$PROBE_TIMEOUT" sh -c "$_ps_cmd" 2>/dev/null \
        | head -c 8192 \
        | grep -q '"result"'
}

main() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "skip:no-jq"
        return 3
    fi

    reg="$(registration_file)"
    if [ -z "$reg" ]; then
        # No registration source at all. Record one absent row per expected
        # expert so the gap is as visible as an outage would be.
        printf '%s' "$EXPECTED" | tr ',' '\n' | grep . | while read -r name; do
            health_record "$name" absent
        done
        echo "absent:not-registered"
        return 2
    fi

    registered=0
    down_list=""
    for name in $(printf '%s' "$EXPECTED" | tr ',' ' '); do
        cmd="$(server_command "$reg" "$name")"
        if [ -z "$cmd" ]; then
            health_record "$name" absent
            continue
        fi
        registered=$((registered + 1))
        start_s="$(date +%s 2>/dev/null || echo 0)"
        if probe_server "$cmd"; then
            end_s="$(date +%s 2>/dev/null || echo 0)"
            health_record "$name" up "$(( (end_s - start_s) * 1000 ))"
        else
            end_s="$(date +%s 2>/dev/null || echo 0)"
            health_record "$name" down "$(( (end_s - start_s) * 1000 ))"
            down_list="${down_list:+$down_list,}$name"
        fi
    done

    if [ "$registered" -eq 0 ]; then
        echo "absent:not-registered"
        return 2
    fi
    if [ -n "$down_list" ]; then
        echo "down:$down_list"
        return 1
    fi
    echo "ok:experts-healthy"
    return 0
}

# Hermetic scenario fixtures (pinned by litmus:mcp-expert-health-probe-shape).
# Nothing here touches a real MCP server: each scenario registers a stand-in
# whose behaviour is fully determined by the registration JSON.
fixture() {
    _fx_fail=0
    _fx_dir="$(mktemp -d)"
    _fx_self="$0"

    # run <name> <registration-json> <expected-verdict> <expected-rc>
    _fx_run() {
        _n="$1"; _json="$2"; _want_v="$3"; _want_rc="$4"
        printf '%s\n' "$_json" >"$_fx_dir/reg.json"
        : >"$_fx_dir/health.jsonl"
        _got_v="$(TILLANDSIAS_MCP_REGISTRATION="$_fx_dir/reg.json" \
                  TILLANDSIAS_EXPERT_HEALTH_LOG="$_fx_dir/health.jsonl" \
                  TILLANDSIAS_MCP_PROBE_TIMEOUT=5 \
                  bash "$_fx_self")"
        _got_rc=$?
        if [ "$_got_v" = "$_want_v" ] && [ "$_got_rc" = "$_want_rc" ]; then
            echo "ok: $_n ($_got_v rc=$_got_rc)"
        else
            echo "FAIL: $_n expected '$_want_v' rc=$_want_rc, got '$_got_v' rc=$_got_rc"
            _fx_fail=1
        fi
    }

    # A stand-in that ANSWERS: `echo` ignores stdin and prints the argv frame.
    # This doubles as the args regression — if a future edit reads `.command`
    # and drops `.args` (the first draft's bug), this becomes a bare `echo`,
    # prints an empty line, and the scenario flips to `down`.
    _ok_srv='{"command":"echo","args":["{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"]}'
    # A stand-in that does NOT answer.
    _bad_srv='{"command":"false"}'

    _fx_run "healthy-both-answer (also pins args are honoured)" \
        "{\"mcpServers\":{\"forge-plan\":$_ok_srv,\"project-info\":$_ok_srv}}" \
        "ok:experts-healthy" 0

    _fx_run "outage-both-down" \
        "{\"mcpServers\":{\"forge-plan\":$_bad_srv,\"project-info\":$_bad_srv}}" \
        "down:forge-plan,project-info" 1

    _fx_run "partial-outage-names-only-the-down-one" \
        "{\"mcpServers\":{\"forge-plan\":$_ok_srv,\"project-info\":$_bad_srv}}" \
        "down:project-info" 1

    _fx_run "absent-registration-names-no-expected-expert" \
        '{"mcpServers":{"git-tools":{"command":"true"}}}' \
        "absent:not-registered" 2

    # Grammar: exactly one well-formed verdict line, never two, never zero.
    printf '%s\n' "{\"mcpServers\":{\"forge-plan\":$_ok_srv,\"project-info\":$_ok_srv}}" >"$_fx_dir/reg.json"
    _lines="$(TILLANDSIAS_MCP_REGISTRATION="$_fx_dir/reg.json" \
              TILLANDSIAS_EXPERT_HEALTH_LOG="$_fx_dir/health.jsonl" \
              bash "$_fx_self" \
              | grep -cE '^(ok:experts-healthy|down:[a-z0-9-]+(,[a-z0-9-]+)*|absent:not-registered|skip:[a-z0-9-]+)$')"
    if [ "$_lines" = "1" ]; then
        echo "ok: grammar-exactly-one-line"
    else
        echo "FAIL: grammar expected 1 well-formed line, got $_lines"
        _fx_fail=1
    fi

    # The health log is the durable trace — an outage must leave a `down` record
    # even though the verdict line itself is ephemeral stdout.
    : >"$_fx_dir/health.jsonl"
    printf '%s\n' "{\"mcpServers\":{\"forge-plan\":$_bad_srv,\"project-info\":$_ok_srv}}" >"$_fx_dir/reg.json"
    TILLANDSIAS_MCP_REGISTRATION="$_fx_dir/reg.json" \
        TILLANDSIAS_EXPERT_HEALTH_LOG="$_fx_dir/health.jsonl" \
        TILLANDSIAS_MCP_PROBE_TIMEOUT=5 bash "$_fx_self" >/dev/null
    if grep -q '"server":"forge-plan","state":"down"' "$_fx_dir/health.jsonl" \
       && grep -q '"server":"project-info","state":"up"' "$_fx_dir/health.jsonl"; then
        echo "ok: health-log-records-both-states"
    else
        echo "FAIL: health log missing expected records:"
        cat "$_fx_dir/health.jsonl"
        _fx_fail=1
    fi

    rm -rf "$_fx_dir"
    [ "$_fx_fail" = 0 ] && echo "ok: all mcp-expert-health scenarios passed"
    return "$_fx_fail"
}

if [ "${1:-}" = "fixture" ]; then
    fixture
    exit $?
fi

verdict="$(main)" && rc=0 || rc=$?
echo "$verdict"
exit "$rc"
