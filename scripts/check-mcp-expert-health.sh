#!/bin/bash
# freshness: updated 2026-08-16 windows-yolanda (tool-call depth + launcher fidelity, order 770-f6u4)
set -uo pipefail
# @trace order:737-zcj5, order:741-t66e, order:741-2izr, order:741-na2c, order:770-f6u4
# @trace invariant:plan_is_queried_via_mcp_server_avoiding_heuristic_parsing
#
# check-mcp-expert-health.sh: the executable MCP-expert liveness probe (order
# 737-zcj5), hardened against adversarial false verdicts (741-t66e/2izr/na2c),
# probing to TOOL-CALL depth with harness launcher fidelity (770-f6u4).
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
#   linux    the session began on `main`, which carries no .mcp.json, so it
#            never loaded the experts at all and did every read through
#            ./target/release/tillandsias-plan.
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
# trace therefore exists whether or not any agent thinks to write one.
#
# ── WHAT "ANSWERED" MEANS, AND WHY THE FIRST DRAFT WAS WRONG ─────────────────
# A verdict is only worth as much as its definition of success. This probe's
# first draft accepted `grep -q '"result"'` over the first 8KB of stdout, and an
# in-forge adversarial review (BigPickle, 2026-08-15) defeated it in BOTH
# directions:
#
#   FALSE HEALTHY (741-t66e) — reported ok:experts-healthy against
#     * an error frame REJECTING initialize whose `error.data` embedded the
#       substring "result" — i.e. exactly the registered-but-broken server this
#       probe exists to catch;
#     * `"result":null` and `"result":{}`, which are schema-invalid as an
#       InitializeResult;
#     * an ordinary log line that merely contained the literal `"result"`.
#   FALSE OUTAGE (741-2izr) — reported down against genuinely healthy experts
#     whose registration carried `env` (dropped), and against chatty-but-healthy
#     servers whose frame fell past the `head -c 8192` byte cut.
#   ABSENT LIES (741-na2c) — reported absent:not-registered for registrations
#     that DID name the server but malformed its command/args, conflating "no
#     expert here" with "the expert here is unusable".
#
# The fixture had pinned the weak behaviour: its stand-in emitted `"result":{}`,
# so the litmus passed *because* the definition was wrong. A test that encodes
# the defect is worse than no test — it converts an unexamined assumption into a
# defended one.
#
# So success is now the MCP contract, validated structurally with jq: a
# JSON-RPC 2.0 frame, matching id, NO `error` member, and a `result` carrying the
# required InitializeResult fields (`protocolVersion` string, `serverInfo.name`
# string). Scanning is line-oriented with a generous line budget — JSON-RPC over
# stdio is line-delimited, so a chatty server's banner no longer buries the frame.
#
# ── TOOL-CALL DEPTH (770-f6u4) ───────────────────────────────────────────────
# A valid InitializeResult proves the WRAPPER started, not that the expert can
# serve. On 2026-08-16 every forge-plan/project-info tools/call on windows died
# at exec time ("line 417 ... No such file or directory" — the shared target/
# held the other platform's artifact) while this probe, then handshake-only,
# said ok:experts-healthy for two full cycles — the order-531 shape: a health
# signal that cannot see the failure class it exists for. So after a valid
# InitializeResult the probe now sends notifications/initialized plus ONE cheap
# tools/call per expert and requires the called tool's PINNED output grammar
# back, not merely a well-formed frame:
#
#   forge-plan    expert_capability {}  → text must match
#                 `expert_capability: now=<caps>` with now NOT none and NOT
#                 stale-binary — the order-569 capability line, whose whole job
#                 is "can this binary answer RIGHT NOW".
#   project-info  project_type {}       → non-empty text content.
#   (other)       tools/list            → structurally valid result.tools array.
#
# Demanding the pinned grammar (a POSITIVE assertion, per the 741-t66e lesson)
# matters because the wrappers deliver even their own exec failures as
# structurally valid result frames: `plan_query` traps the error text and
# rpc_result_text wraps it, so "ERROR: the tillandsias-plan binary is not
# installed." arrives as a perfectly well-formed non-error tool result. A
# frame-validity check alone would have called the 2026-08-16 outage healthy at
# tool-call depth too.
#
# The JSONL record now carries the failure stage — `"stage":"handshake"` vs
# `"stage":"tool-call"` (up records read `"stage":"full"`) — so the log
# separates handshake-dead from tool-call-dead.
#
# ── LAUNCHER FIDELITY (770-f6u4, second gap) ─────────────────────────────────
# The probe launches the registration command through the CURRENT shell's PATH,
# but on windows the agent harness resolves `bash` to the WindowsApps/System32
# WSL launcher while Git Bash resolves its own bash — so a probe run from Git
# Bash tested a DIFFERENT environment than the one the session's servers run
# in, and even a tool-call-depth probe would have called the 2026-08-16 outage
# healthy from the Git Bash lane. On windows hosts, when the registered command
# is exactly `bash`, the probe now resolves it the way the harness does
# (WindowsApps bash.exe, then System32 bash.exe, when present) and records the
# chosen launcher in the JSONL record (`"launcher":"..."`).
#
# ADVISORY, NEVER A GATE. An unavailable expert is a degraded read path, never a
# blocked cycle (`filesystem_fallback.unavailable`, and "'Tis broken? keep
# goin'"). A non-zero exit here means RECORD AND CONTINUE. This is deliberately
# unlike check-credential-channel.sh, whose non-zero exit does fail the cycle:
# a missing push channel silently destroys work, while a missing expert only
# makes reads more expensive.
#
# NEGATIVE CONTROL. A healthy session prints `ok:experts-healthy` and nothing
# else — no outage line from cycle-metrics.sh, no ledger artifact. A signal that
# fires every cycle is one nobody reads.
#
# VERDICT GRAMMAR (pinned by litmus:mcp-expert-health-probe-shape):
#   ^(ok:experts-healthy|down:[a-z0-9-]+(,[a-z0-9-]+)*|absent:not-registered|skip:[a-z0-9-]+)$
#
#   ok:experts-healthy     every expected expert served the full conversation
#                          (initialize → initialized → one real tools/call)
#   down:<csv>             registered but did not — including registered-but-
#                          malformed, which is unusable, not absent, and
#                          handshake-ok-but-tool-call-dead
#   absent:not-registered  no registration source NAMES any expected expert
#   skip:<reason>          the probe could not run (no jq, no registration file)
#
# Exit: 0 healthy, 1 down, 2 absent, 3 skip.
#
# Testability seams (used by the litmus fixture):
#   TILLANDSIAS_MCP_REGISTRATION   explicit registration JSON path
#   TILLANDSIAS_MCP_EXPECTED       CSV of expected expert names
#   TILLANDSIAS_EXPERT_HEALTH_LOG  JSONL destination
#   TILLANDSIAS_MCP_PROBE_TIMEOUT  per-server conversation budget in seconds
#   TILLANDSIAS_MCP_PROBE_MAXLINES lines scanned for the frames (default 500)
#   TILLANDSIAS_MCP_PROBE_OS       force host-OS detection (launcher fidelity)
#   TILLANDSIAS_MCP_HARNESS_BASH   force the harness bash launcher path

EXPECTED_DEFAULT="forge-plan,project-info"
EXPECTED="${TILLANDSIAS_MCP_EXPECTED:-$EXPECTED_DEFAULT}"
# 890-t9pu: the writer and the reader of this log must agree on its path, and
# /tmp is not one place across the WSL boundary. Shared rule, best-effort source.
# shellcheck source=scripts/metrics-log-path.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/metrics-log-path.sh" 2>/dev/null || true
command -v metrics_default_log >/dev/null 2>&1 || { metrics_default_log() { printf '/tmp/%s' "$1"; }; }
HEALTH_LOG="${TILLANDSIAS_EXPERT_HEALTH_LOG:-$(metrics_default_log forge-expert-health.jsonl)}"
PROBE_TIMEOUT="${TILLANDSIAS_MCP_PROBE_TIMEOUT:-10}"
PROBE_MAXLINES="${TILLANDSIAS_MCP_PROBE_MAXLINES:-500}"
PROBE_ID=1
TOOL_ID=2
INIT_FRAME='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"tillandsias-health-probe","version":"1"}}}'
INITIALIZED_NOTIF='{"jsonrpc":"2.0","method":"notifications/initialized"}'
PROBE_OS="${TILLANDSIAS_MCP_PROBE_OS:-$(uname -s 2>/dev/null || echo unknown)}"

# Best-effort by construction, mirroring mcp-usage-log.sh: telemetry must never
# break the surface it measures, so every append is wrapped and silenced.
# Fields keep their historical order (ts, server, state, host, probe_ms) so
# existing adjacency greps stay valid; stage and launcher append at the end.
health_record() {
    _hr_server="$1"; _hr_state="$2"; _hr_ms="${3:-}"; _hr_stage="${4:-}"; _hr_launcher="${5:-}"
    {
        _hr_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        _hr_line="$(printf '{"ts":"%s","server":"%s","state":"%s","host":"%s"' \
            "$_hr_ts" "$_hr_server" "$_hr_state" "${TILLANDSIAS_HOST_KIND:-unknown}")"
        case "$_hr_ms" in
            '' | *[!0-9]*) : ;;
            *) _hr_line="${_hr_line}$(printf ',"probe_ms":%s' "$_hr_ms")" ;;
        esac
        [ -n "$_hr_stage" ] && _hr_line="${_hr_line}$(printf ',"stage":"%s"' "$_hr_stage")"
        [ -n "$_hr_launcher" ] && _hr_line="${_hr_line}$(printf ',"launcher":"%s"' "$_hr_launcher")"
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

# Does the registration NAME this server at all? This is the absent/down
# boundary (741-na2c): a registration that names the expert but garbles its
# command describes an expert that is present and unusable — `down` — while
# `absent` must mean the environment has no such expert to lose. Collapsing the
# two makes a broken registration look like a host that was never meant to have
# experts, which is the one reading that suppresses the alarm.
server_is_registered() {
    jq -e --arg s "$2" --arg p "$PWD" '
        ((.projects[$p]?.mcpServers[$s]?) // (.mcpServers[$s]?)) != null
    ' "$1" >/dev/null 2>&1
}

# Extract a server's launch argv. ~/.claude.json scopes servers per project, so
# try the project map before the top-level one.
#
# `args` IS LOAD-BEARING — do not reduce this to `.command`. The repo's own
# .mcp.json registers `command: "bash"` with the server script in `args`, so
# reading `.command` alone probes a bare `bash`, which consumes the handshake
# frame as a shell script and reports every healthy expert as DOWN. That false
# positive was produced by the first draft of this very script. `@sh` emits a
# shell-quoted argv so a path containing spaces survives `sh -c`.
#
# $3 (optional) replaces argv[0] — the launcher-fidelity rewrite. It is applied
# inside jq so the substitution inherits the same quoting as every other word.
server_command() {
    jq -r --arg s "$2" --arg p "$PWD" --arg o "${3:-}" '
        ((.projects[$p]?.mcpServers[$s]?) // (.mcpServers[$s]?) // empty)
        | select(type == "object" and (.command | type == "string"))
        | select((.args // []) | type == "array")
        | ([ (if $o != "" then $o else .command end) ] + ((.args // []) | map(tostring)))
        | @sh
    ' "$1" 2>/dev/null | grep -m1 . || true
}

# The registered command word alone, un-rewritten — the launcher-fidelity test
# keys on it and the JSONL `launcher` field defaults to it.
server_argv0() {
    jq -r --arg s "$2" --arg p "$PWD" '
        ((.projects[$p]?.mcpServers[$s]?) // (.mcpServers[$s]?) // empty)
        | select(type == "object")
        | (.command // empty)
        | select(type == "string")
    ' "$1" 2>/dev/null | grep -m1 . || true
}

# A registration may carry `env`. Dropping it reported healthy experts as down
# (741-2izr) because a server that needs its environment cannot start without it.
server_env() {
    jq -r --arg s "$2" --arg p "$PWD" '
        ((.projects[$p]?.mcpServers[$s]?) // (.mcpServers[$s]?) // empty)
        | (.env // {})
        | to_entries | map("\(.key)=\(.value|tostring)") | @sh
    ' "$1" 2>/dev/null | grep -m1 . || true
}

# How the agent harness would resolve a bare `bash` on this windows host: the
# WindowsApps WSL launcher first, then the System32 one. Probing the probing
# shell's own bash instead tests a different environment than the sessions'
# servers run in (770-f6u4, second gap).
harness_bash_launcher() {
    if [ -n "${TILLANDSIAS_MCP_HARNESS_BASH:-}" ]; then
        [ -f "$TILLANDSIAS_MCP_HARNESS_BASH" ] && printf '%s\n' "$TILLANDSIAS_MCP_HARNESS_BASH"
        return 0
    fi
    for _hb in \
        "$(cygpath -u "${LOCALAPPDATA:-}" 2>/dev/null || true)/Microsoft/WindowsApps/bash.exe" \
        "$(cygpath -u "${SYSTEMROOT:-}" 2>/dev/null || true)/System32/bash.exe"; do
        case "$_hb" in
            /*) [ -f "$_hb" ] && { printf '%s\n' "$_hb"; return 0; } ;;
        esac
    done
    return 0
}

# The cheap depth-probe frame for a server. Known experts get a REAL tools/call
# whose success output is pinned; unknown servers get tools/list, which still
# proves the request loop serves past the handshake.
probe_tool_frame() {
    case "$1" in
        forge-plan)
            jq -cn '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"expert_capability",arguments:{}}}'
            ;;
        project-info)
            jq -cn '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"project_type",arguments:{}}}'
            ;;
        *)
            jq -cn '{jsonrpc:"2.0",id:2,method:"tools/list",params:{}}'
            ;;
    esac
}

# Per-server acceptance of the tool result TEXT — the positive pinned-grammar
# assertion (741-t66e: never a substring blacklist). For forge-plan the line is
# the order-569 capability grammar, and now=none / now=stale-binary are the
# binary-cannot-serve states this stage exists to catch.
probe_tool_text_ok() {
    case "$1" in
        forge-plan)
            case "$2" in
                "expert_capability: now=none"*) return 1 ;;
                "expert_capability: now=stale-binary"*) return 1 ;;
                "expert_capability: now="*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            [ -n "$2" ]
            ;;
    esac
}

# Stage 1 scan: a STRUCTURALLY VALID InitializeResult (id 1) — not a substring,
# not any frame carrying a `result` key. `test -x` would call a wedged server
# healthy; a substring grep calls an ERROR frame healthy, which is worse,
# because an error frame is the failure this probe exists to name.
#
# ONE jq pass per scan, deliberately (770-f6u4): `jq -R` with `fromjson?`
# treats every stdout line as a candidate frame and non-JSON lines vanish
# silently, preserving the line-oriented chatty-server tolerance (741-2izr)
# without spawning a jq per line — the per-line form cost a process spawn per
# banner line and blew the litmus step budget on windows, where spawns are
# ~100x dearer than on linux.
probe_scan_init() {
    printf '%s\n' "$1" | jq -Rr --argjson id "$PROBE_ID" '
        fromjson? | select(
            (.jsonrpc == "2.0")
            and (.error == null)
            and (.id == $id)
            and (.result | type == "object")
            and (.result.protocolVersion | type == "string")
            and (.result.serverInfo.name | type == "string")
        ) | "MATCH"' 2>/dev/null | grep -q MATCH
}

# Stage 2 scan: the tools/call (or tools/list) response at id 2. The frame must
# be a non-error result — and for tools/call the content text must satisfy the
# per-server pinned grammar, because the wrappers deliver their own exec
# failures as structurally valid result frames (see header).
probe_scan_tool() {
    _pt_name="$1"; _pt_out="$2"
    case "$_pt_name" in
        forge-plan | project-info)
            _pt_text="$(printf '%s\n' "$_pt_out" | jq -Rr --argjson id "$TOOL_ID" '
                fromjson? | select(
                    (.jsonrpc == "2.0")
                    and (.error == null)
                    and (.id == $id)
                    and (.result | type == "object")
                    and ((.result.isError // false) != true)
                    and (.result.content | type == "array")
                    and (.result.content[0].type? == "text")
                    and (.result.content[0].text? | type == "string")
                ) | .result.content[0].text' 2>/dev/null)"
            [ -n "$_pt_text" ] || return 1
            probe_tool_text_ok "$_pt_name" "$_pt_text"
            ;;
        *)
            printf '%s\n' "$_pt_out" | jq -Rr --argjson id "$TOOL_ID" '
                fromjson? | select(
                    (.jsonrpc == "2.0")
                    and (.error == null)
                    and (.id == $id)
                    and (.result.tools | type == "array")
                ) | "MATCH"' 2>/dev/null | grep -q MATCH
            ;;
    esac
}

# Run the full three-frame conversation against one server and name the depth
# reached: `ok`, `handshake-dead`, or `tool-call-dead`. A healthy wrapper
# answers both ids and exits on stdin EOF, so the happy path never waits out
# the timeout.
probe_server() {
    _ps_name="$1"; _ps_cmd="$2"; _ps_env="${3:-}"
    # `server_env` emits @sh-quoted pairs, which are meant to be UNQUOTED by the
    # shell, not word-split raw: expanding `$_ps_env` bare hands `env` a literal
    # leading quote and it sets a variable named `'FIXTURE_TOKEN`. `eval set --`
    # is the idiomatic way to turn @sh output back into argv. Positional params
    # are function-local, so this cannot disturb main()'s expected-name list.
    if [ -n "$_ps_env" ]; then
        eval "set -- $_ps_env"
    else
        set --
    fi
    _ps_tool_frame="$(probe_tool_frame "$_ps_name")"
    _ps_out="$(printf '%s\n%s\n%s\n' "$INIT_FRAME" "$INITIALIZED_NOTIF" "$_ps_tool_frame" \
        | timeout "$PROBE_TIMEOUT" env "$@" sh -c "$_ps_cmd" 2>/dev/null \
        | head -n "$PROBE_MAXLINES")"
    if ! probe_scan_init "$_ps_out"; then
        echo handshake-dead
        return 0
    fi
    if ! probe_scan_tool "$_ps_name" "$_ps_out"; then
        echo tool-call-dead
        return 0
    fi
    echo ok
}

main() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "skip:no-jq"
        return 3
    fi

    reg="$(registration_file)"
    if [ -z "$reg" ]; then
        printf '%s' "$EXPECTED" | tr ',' '\n' | grep . | while read -r name; do
            health_record "$name" absent
        done
        echo "absent:not-registered"
        return 2
    fi

    registered=0
    down_list=""
    # Split on commas ONLY. Unquoted word-splitting silently dropped any expected
    # name containing a space and still reported ok (741-t66e, secondary).
    _saved_ifs="$IFS"
    IFS=','
    # shellcheck disable=SC2086
    set -- $EXPECTED
    IFS="$_saved_ifs"
    for name in "$@"; do
        [ -n "$name" ] || continue
        if ! server_is_registered "$reg" "$name"; then
            health_record "$name" absent
            continue
        fi
        registered=$((registered + 1))
        argv0="$(server_argv0 "$reg" "$name")"
        launcher="$argv0"
        override=""
        # Launcher fidelity (770-f6u4): on windows, a registered bare `bash` is
        # resolved the way the HARNESS resolves it, not the probing shell.
        case "$PROBE_OS" in
            MINGW* | MSYS* | CYGWIN* | Windows* | windows)
                if [ "$argv0" = "bash" ]; then
                    _hb="$(harness_bash_launcher)"
                    if [ -n "$_hb" ]; then
                        override="$_hb"
                        launcher="$_hb"
                    fi
                fi
                ;;
        esac
        cmd="$(server_command "$reg" "$name" "$override")"
        start_s="$(date +%s 2>/dev/null || echo 0)"
        if [ -z "$cmd" ]; then
            # Named but unusable: a malformed command/args is an outage, not an
            # absence. Reporting `absent` here would suppress the alarm for the
            # exact case where the registration is the thing that broke.
            health_record "$name" down 0 registration "${launcher:--}"
            down_list="${down_list:+$down_list,}$name"
            continue
        fi
        depth="$(probe_server "$name" "$cmd" "$(server_env "$reg" "$name")")"
        end_s="$(date +%s 2>/dev/null || echo 0)"
        _ms=$(( (end_s - start_s) * 1000 ))
        case "$depth" in
            ok)
                health_record "$name" up "$_ms" full "$launcher"
                ;;
            handshake-dead)
                health_record "$name" down "$_ms" handshake "$launcher"
                down_list="${down_list:+$down_list,}$name"
                ;;
            *)
                health_record "$name" down "$_ms" tool-call "$launcher"
                down_list="${down_list:+$down_list,}$name"
                ;;
        esac
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
#
# The adversarial scenarios are the point. Every one of them PASSED the first
# draft — they are the in-forge review's counterexamples, kept as fixtures so the
# weak definition cannot come back. The 770-f6u4 additions pin the tool-call
# depth: a server that handshakes and then errors, mutes, or returns the
# wrapper's own exec-failure text on tools/call must read DOWN.
fixture() {
    _fx_fail=0
    _fx_dir="$(mktemp -d)"
    _fx_self="$0"

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

    # Registration JSON is BUILT WITH jq, never hand-escaped. Two scenarios in
    # the first hardened draft failed as `absent:not-registered` purely because
    # nested shell quoting mangled their JSON — a fixture bug that reads exactly
    # like a probe bug, which is the worst kind to leave lying around.
    _ok_frame='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1.0.0"}}}'
    # A tool result satisfying BOTH experts' pinned grammars (forge-plan's
    # capability line is also non-empty text, which is project-info's bar).
    _tool_frame='{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"expert_capability: now=plan-answer after_relaunch=plan-answer skew=none blocked_capabilities=- lost_on_relaunch=-"}]}}'
    _tool_err_frame='{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"exec failed"}}'
    # The LIVE 2026-08-16 outage shape: a structurally valid, non-error result
    # frame whose text is the wrapper's exec-failure diagnostic.
    _tool_binerr_frame='{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ERROR: the tillandsias-plan binary is not installed."}]}}'

    # Stand-in servers as real files, so their bodies need no escaping at all.
    # Post-770-f6u4 a HEALTHY stand-in must serve the whole conversation:
    # initialize AND the depth tools/call.
    _mk_loop_srv() {
        # $1 = file, $2 = init response, $3 = tools/call response ('' = stay mute)
        {
            printf '%s\n' '#!/bin/sh'
            printf '%s\n' 'while IFS= read -r _l; do'
            printf '%s\n' '  case "$_l" in'
            printf '%s\n' "    *'\"method\":\"initialize\"'*) printf '%s\\n' '$2' ;;"
            if [ -n "$3" ]; then
                printf '%s\n' "    *'\"method\":\"tools/call\"'*) printf '%s\\n' '$3' ;;"
            fi
            printf '%s\n' '  esac'
            printf '%s\n' 'done'
        } >"$1"
    }
    _mk_loop_srv "$_fx_dir/ok.sh" "$_ok_frame" "$_tool_frame"
    _mk_loop_srv "$_fx_dir/hserr.sh" "$_ok_frame" "$_tool_err_frame"
    _mk_loop_srv "$_fx_dir/hsmute.sh" "$_ok_frame" ""
    _mk_loop_srv "$_fx_dir/binerr.sh" "$_ok_frame" "$_tool_binerr_frame"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'i=0; while [ $i -lt 120 ]; do printf "%s\n" "INFO banner padding padding padding padding padding padding padding"; i=$((i+1)); done'
        printf '%s\n' 'while IFS= read -r _l; do'
        printf '%s\n' '  case "$_l" in'
        printf '%s\n' "    *'\"method\":\"initialize\"'*) printf '%s\\n' '$_ok_frame' ;;"
        printf '%s\n' "    *'\"method\":\"tools/call\"'*) printf '%s\\n' '$_tool_frame' ;;"
        printf '%s\n' '  esac'
        printf '%s\n' 'done'
    } >"$_fx_dir/chatty.sh"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' '[ "$FIXTURE_TOKEN" = ok ] || exit 1'
        printf '%s\n' "exec sh '$_fx_dir/ok.sh'"
    } >"$_fx_dir/envsrv.sh"

    _mk_srv() { jq -cn --arg c "$1" --arg a "$2" '{command:$c,args:[$a]}'; }
    _mk_reg() { jq -cn --argjson a "$1" --argjson b "$2" '{mcpServers:{"forge-plan":$a,"project-info":$b}}'; }
    _ok_srv="$(_mk_srv sh "$_fx_dir/ok.sh")"
    _chatty_srv="$(_mk_srv sh "$_fx_dir/chatty.sh")"
    _hserr_srv="$(_mk_srv sh "$_fx_dir/hserr.sh")"
    _hsmute_srv="$(_mk_srv sh "$_fx_dir/hsmute.sh")"
    _binerr_srv="$(_mk_srv sh "$_fx_dir/binerr.sh")"
    _env_srv="$(jq -cn --arg a "$_fx_dir/envsrv.sh" '{command:"sh",args:[$a],env:{FIXTURE_TOKEN:"ok"}}')"
    _err_srv="$(jq -cn --arg f '{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"init failed","data":"no \"result\" available"}}' '{command:"echo",args:[$f]}')"
    _null_srv="$(jq -cn --arg f '{"jsonrpc":"2.0","id":1,"result":null}' '{command:"echo",args:[$f]}')"
    _empty_srv="$(jq -cn --arg f '{"jsonrpc":"2.0","id":1,"result":{}}' '{command:"echo",args:[$f]}')"
    _log_srv="$(jq -cn --arg f 'INFO starting up, no "result" yet' '{command:"echo",args:[$f]}')"
    _bad_srv='{"command":"false"}'

    _fx_run "healthy-both-answer (also pins args are honoured)" \
        "$(_mk_reg "$_ok_srv" "$_ok_srv")" "ok:experts-healthy" 0

    _fx_run "outage-both-down" \
        "$(_mk_reg "$_bad_srv" "$_bad_srv")" "down:forge-plan,project-info" 1

    _fx_run "partial-outage-names-only-the-down-one" \
        "$(_mk_reg "$_ok_srv" "$_bad_srv")" "down:project-info" 1

    _fx_run "absent-registration-names-no-expected-expert" \
        '{"mcpServers":{"git-tools":{"command":"true"}}}' \
        "absent:not-registered" 2

    # ── 741-t66e: four ways the substring grep said HEALTHY about a broken server
    _fx_run "ADVERSARIAL error-frame-embedding-the-word-result is DOWN" \
        "$(_mk_reg "$_err_srv" "$_ok_srv")" "down:forge-plan" 1

    _fx_run "ADVERSARIAL result-null is DOWN (not a valid InitializeResult)" \
        "$(_mk_reg "$_null_srv" "$_ok_srv")" "down:forge-plan" 1

    _fx_run "ADVERSARIAL plain-log-line-containing-result is DOWN" \
        "$(_mk_reg "$_log_srv" "$_log_srv")" "down:forge-plan,project-info" 1

    _fx_run "ADVERSARIAL empty-result-object is DOWN (missing required fields)" \
        "$(_mk_reg "$_empty_srv" "$_ok_srv")" "down:forge-plan" 1

    # ── 741-2izr: chatty-but-healthy must not be truncated into a false outage
    _fx_run "chatty-banner-then-valid-frame is HEALTHY (no byte truncation)" \
        "$(_mk_reg "$_chatty_srv" "$_ok_srv")" "ok:experts-healthy" 0

    # ── 741-2izr: registration env must reach the server
    _fx_run "registration-env-is-honoured (absent env would read as an outage)" \
        "$(_mk_reg "$_env_srv" "$_ok_srv")" "ok:experts-healthy" 0

    # ── 741-na2c: named-but-malformed is an OUTAGE, never an absence
    _fx_run "ADVERSARIAL malformed-args-string is DOWN not absent" \
        "$(_mk_reg '{"command":"echo","args":"not-an-array"}' "$_ok_srv")" "down:forge-plan" 1

    _fx_run "ADVERSARIAL non-string-command is DOWN not absent" \
        "$(_mk_reg '{"command":42}' "$_ok_srv")" "down:forge-plan" 1

    # ── 770-f6u4: tool-call depth — handshake success is no longer health
    _fx_run "ADVERSARIAL handshake-then-tools-call-ERROR is DOWN (tool-call depth)" \
        "$(_mk_reg "$_hserr_srv" "$_ok_srv")" "down:forge-plan" 1

    _fx_run "ADVERSARIAL handshake-then-SILENCE on tools/call is DOWN" \
        "$(_mk_reg "$_hsmute_srv" "$_ok_srv")" "down:forge-plan" 1

    _fx_run "ADVERSARIAL valid-frame-carrying-wrapper-exec-error-text is DOWN (pinned grammar, the 2026-08-16 live shape)" \
        "$(_mk_reg "$_binerr_srv" "$_ok_srv")" "down:forge-plan" 1

    # ── 770-f6u4: the log separates handshake-dead from tool-call-dead
    : >"$_fx_dir/health.jsonl"
    _mk_reg "$_hserr_srv" "$_bad_srv" >"$_fx_dir/reg.json"
    TILLANDSIAS_MCP_REGISTRATION="$_fx_dir/reg.json" \
        TILLANDSIAS_EXPERT_HEALTH_LOG="$_fx_dir/health.jsonl" \
        TILLANDSIAS_MCP_PROBE_TIMEOUT=5 bash "$_fx_self" >/dev/null
    if grep -q '"server":"forge-plan","state":"down"' "$_fx_dir/health.jsonl" \
       && grep -q '"stage":"tool-call"' "$_fx_dir/health.jsonl" \
       && grep -q '"stage":"handshake"' "$_fx_dir/health.jsonl"; then
        echo "ok: stage-tokens-separate-handshake-dead-from-tool-call-dead"
    else
        echo "FAIL: health log missing distinct stage tokens:"
        cat "$_fx_dir/health.jsonl"
        _fx_fail=1
    fi

    # ── 770-f6u4: launcher fidelity — on windows a registered bare `bash` is
    # resolved the way the HARNESS resolves it, and the choice is recorded.
    # The registration's args name the ok stand-in, but plain `bash` would run
    # it as a bash script (consuming the frames as shell) — only the harness
    # launcher stand-in serves the protocol, so ok:experts-healthy proves the
    # rewrite happened and the JSONL proves it was recorded.
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'shift $# 2>/dev/null || true'
        printf '%s\n' "exec sh '$_fx_dir/ok.sh'"
    } >"$_fx_dir/fakebash.sh"
    chmod +x "$_fx_dir/fakebash.sh" 2>/dev/null || true
    _bash_srv="$(jq -cn --arg a "$_fx_dir/ok.sh" '{command:"bash",args:[$a]}')"
    : >"$_fx_dir/health.jsonl"
    _mk_reg "$_bash_srv" "$_bash_srv" >"$_fx_dir/reg.json"
    _got_v="$(TILLANDSIAS_MCP_REGISTRATION="$_fx_dir/reg.json" \
              TILLANDSIAS_EXPERT_HEALTH_LOG="$_fx_dir/health.jsonl" \
              TILLANDSIAS_MCP_PROBE_TIMEOUT=5 \
              TILLANDSIAS_MCP_PROBE_OS=MINGW64_NT-fixture \
              TILLANDSIAS_MCP_HARNESS_BASH="$_fx_dir/fakebash.sh" \
              bash "$_fx_self")"
    if grep -q "\"launcher\":\"$_fx_dir/fakebash.sh\"" "$_fx_dir/health.jsonl"; then
        echo "ok: launcher-fidelity-rewrites-bash-and-records-choice ($_got_v)"
    else
        echo "FAIL: launcher fidelity — expected launcher=$_fx_dir/fakebash.sh in log; verdict=$_got_v:"
        cat "$_fx_dir/health.jsonl"
        _fx_fail=1
    fi
    # Negative control: off windows the registered command is used untouched
    # and recorded as itself.
    : >"$_fx_dir/health.jsonl"
    _mk_reg "$_ok_srv" "$_ok_srv" >"$_fx_dir/reg.json"
    TILLANDSIAS_MCP_REGISTRATION="$_fx_dir/reg.json" \
        TILLANDSIAS_EXPERT_HEALTH_LOG="$_fx_dir/health.jsonl" \
        TILLANDSIAS_MCP_PROBE_TIMEOUT=5 \
        TILLANDSIAS_MCP_PROBE_OS=Linux \
        bash "$_fx_self" >/dev/null
    if grep -q '"launcher":"sh"' "$_fx_dir/health.jsonl"; then
        echo "ok: launcher-recorded-verbatim-off-windows"
    else
        echo "FAIL: expected launcher=sh recorded off-windows:"
        cat "$_fx_dir/health.jsonl"
        _fx_fail=1
    fi

    # Grammar: exactly one well-formed verdict line, never two, never zero.
    _mk_reg "$_ok_srv" "$_ok_srv" >"$_fx_dir/reg.json"
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
    _mk_reg "$_bad_srv" "$_ok_srv" >"$_fx_dir/reg.json"
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
