#!/usr/bin/env bash
# freshness: added 2026-08-17 windows-yolanda (order 801-m9tk)
# @trace order:801-m9tk, order:737-zcj5, order:770-f6u4, order:531
# @trace invariant:plan_is_queried_via_mcp_server_avoiding_heuristic_parsing
#
# check-mcp-surface.sh — does the AGENT actually have the experts, or does the
# handshake merely say the servers are alive?
#
# ── THE DEFECT (order-531 shape, third recurrence) ───────────────────────────
#
# For THREE consecutive windows cycles (2026-08-15, -16, -17)
# scripts/check-mcp-expert-health.sh printed `ok:experts-healthy` while NOT ONE
# `mcp__forge-plan__*` / `mcp__project-info__*` tool existed on the session's
# tool surface. Every read in those cycles fell back to
# ./target/release/tillandsias-plan. The probe was not lying: the servers really
# did handshake, and (since 770-f6u4) really did serve a tools/call. The probe
# was answering a DIFFERENT QUESTION than the one the cycle needed answered.
#
#   HANDSHAKE   "if I launch the registered command, does it serve MCP?"
#               Script-observable. Falsifiable. Already covered, thoroughly.
#   SURFACE     "did THIS agent session get those tools bound to its tool
#               surface?" Not observable from a subprocess at all.
#
# A server that is up but not exposed to the agent is exactly the outage worth
# catching — the read path is degraded for the entire cycle — and the existing
# probe calls it healthy. That is order 531 again: truthful component state,
# wrong conclusion about capability. `experts: ready` was true then too.
#
# ── WHICH HALF IS UNFALSIFIABLE, SAID PLAINLY ────────────────────────────────
#
# A script cannot see the agent's tool surface. It runs as a subprocess of a
# harness that never tells it which tools were bound; there is no file, no
# socket, and no exit code that carries the fact. Any check that claimed to
# MEASURE the surface from here would be inventing it, which is the failure
# this file exists to prevent, one level up.
#
# So the design splits the fact along the line of what is knowable:
#
#   the PROBE measures the handshake        (script-observable, falsifiable)
#   the CYCLE reports the surface           (agent-observable, ATTESTED)
#   this check JOINS them into one verdict  (script-observable, falsifiable)
#
# The surface half is an ATTESTATION, not a measurement. It is exactly as
# trustworthy as the agent that wrote it — which is the same standing every
# `verified-by` event and every `stamp` subcommand in this repo already has, and
# strictly better than the status quo, where the fact was recorded nowhere at
# all and three cycles' worth of degraded reads left no trace.
#
# What the attestation DOES buy, and it is not small:
#   * the state becomes SAYABLE. `unexposed:handshake-ok` is a distinct verdict
#     from `ok:` and from `down:`, so cycle-metrics can carry it, the handoff
#     pastes it, and the loop-status entry inherits it — the 737-zcj5 mechanism,
#     which only ever worked for states the grammar could express.
#   * the DEFAULT is honest. An unattested cycle reads
#     `unattested:no-surface-claim`, never `ok:`. Silence stops meaning healthy,
#     which is the specific property `health=unprobed` already protects for the
#     handshake and which the surface had no equivalent of.
#   * a STALE claim expires. A marker from an earlier cycle cannot vouch for
#     this one, so the inherited-premise failure (a cycle skipping a check
#     because a previous run's artifact said it passed) cannot happen here.
#
# What it does NOT buy: it cannot catch an agent that attests `exposed` while
# holding no such tools. That residual is real and stated rather than papered
# over. It is narrower than it looks — the attesting agent is the one harmed by
# the lie, since the whole point of the record is to explain its own degraded
# reads — and the corroboration that would close it (reading the harness's own
# session transcript for `mcp__*` tool_use frames, which would falsify a false
# `unexposed` and, given a live session, a false `exposed`) is filed as its own
# packet rather than half-built here.
#
# ── GRAMMAR (exactly one line on stdout) ─────────────────────────────────────
#   ok:surface-exposed                 handshake ok AND the cycle attests the
#                                      tools were on its surface           (0)
#   unexposed:handshake-ok             THE NEW STATE: servers healthy, tools
#                                      absent from the session. Degraded read
#                                      path for the whole cycle            (1)
#   down:<csv>                         the handshake itself failed; surface is
#                                      moot and already named by the probe  (2)
#   absent:not-registered              no expected expert registered here   (2)
#   unattested:no-surface-claim        no attestation this cycle            (3)
#   unattested:surface-claim-stale     the claim predates the freshness window,
#                                      so it vouches for an earlier cycle   (3)
#   skip:no-health-log                 the handshake probe has not run yet  (3)
#
# ADVISORY, NEVER A GATE — same contract as check-mcp-expert-health.sh. A
# degraded read path is expensive, not fatal ("'Tis broken? keep goin'"). Record
# and continue; the exit code is for branching, not for failing the cycle.
#
# Seams (used by the fixture):
#   TILLANDSIAS_MCP_SURFACE_STAMP   attestation path (default <git-dir>/…)
#   TILLANDSIAS_EXPERT_HEALTH_LOG   the handshake probe's JSONL
#   TILLANDSIAS_MCP_SURFACE_MAX_AGE freshness window in seconds (default 14400)
#   TILLANDSIAS_MCP_SURFACE_NOW     force "now" as an epoch

set -uo pipefail

_git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null || echo .git)"
STAMP="${TILLANDSIAS_MCP_SURFACE_STAMP:-$_git_dir/tillandsias-mcp-surface}"
HEALTH_LOG="${TILLANDSIAS_EXPERT_HEALTH_LOG:-/tmp/forge-expert-health.jsonl}"
MAX_AGE="${TILLANDSIAS_MCP_SURFACE_MAX_AGE:-14400}"

now_epoch() {
    if [ -n "${TILLANDSIAS_MCP_SURFACE_NOW:-}" ]; then
        printf '%s\n' "$TILLANDSIAS_MCP_SURFACE_NOW"
        return 0
    fi
    date -u +%s 2>/dev/null || echo 0
}

# The handshake half, read from the SAME JSONL cycle-metrics reads so the two
# can never disagree about what the probe said. Last state wins per server.
handshake_state() {
    [ -s "$HEALTH_LOG" ] || { echo "no-log"; return 0; }
    awk -F'"' '
        /"server":/ {
            srv=""; st="";
            for (i = 1; i <= NF; i++) {
                if ($i == "server") srv = $(i + 2);
                if ($i == "state")  st  = $(i + 2);
            }
            if (srv != "" && st != "") last[srv] = st;
        }
        END {
            down = ""; absent = 0; total = 0;
            for (s in last) {
                total++;
                if (last[s] == "down") down = down (down == "" ? "" : ",") s;
                else if (last[s] == "absent") absent++;
            }
            if (total == 0) { print "no-log" }
            else if (down != "") { print "down:" down }
            else if (absent == total) { print "absent" }
            else { print "ok" }
        }' "$HEALTH_LOG" 2>/dev/null || echo "no-log"
}

stamp_field() {
    [ -f "$STAMP" ] || return 1
    sed -n "s/.*\\b$1=\\([^ ]*\\).*/\\1/p" "$STAMP" 2>/dev/null | grep -m1 . || return 1
}

case "${1:-check}" in
    attest)
        claim="${2:-}"
        case "$claim" in
            exposed | unexposed) ;;
            *)
                echo "refused:attest-needs-a-claim:usage: check-mcp-surface.sh attest <exposed|unexposed> [--tools <csv>] [--agent <id>]; the surface is the one fact only the agent can report, so it must be stated, never defaulted"
                exit 2
                ;;
        esac
        shift 2 2>/dev/null || shift
        tools="-"; agent="${TILLANDSIAS_AGENT_ID:-unknown}"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --tools) tools="${2:--}"; shift 2 || shift ;;
                --agent) agent="${2:-unknown}"; shift 2 || shift ;;
                *) shift ;;
            esac
        done
        mkdir -p "$(dirname "$STAMP")" 2>/dev/null || true
        printf 'ts=%s epoch=%s claim=%s tools=%s agent=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
            "$(now_epoch)" "$claim" "$tools" "$agent" \
            > "$STAMP" 2>/dev/null || { echo "refused:attest-unwritable-stamp"; exit 2; }
        echo "ok:surface-attested:$claim"
        exit 0
        ;;
    check)
        hs="$(handshake_state)"
        case "$hs" in
            no-log)
                # The handshake half has not run. Saying anything about the
                # surface now would be a verdict resting on one measurement.
                echo "skip:no-health-log"
                exit 3
                ;;
            down:*) echo "$hs"; exit 2 ;;
            absent) echo "absent:not-registered"; exit 2 ;;
        esac

        claim="$(stamp_field claim)" || claim=""
        if [ -z "$claim" ]; then
            echo "unattested:no-surface-claim"
            exit 3
        fi
        stamp_epoch="$(stamp_field epoch)" || stamp_epoch=""
        case "$stamp_epoch" in
            '' | *[!0-9]*) stamp_epoch="" ;;
        esac
        if [ -n "$stamp_epoch" ]; then
            age=$(( $(now_epoch) - stamp_epoch ))
            [ "$age" -lt 0 ] && age=0
            if [ "$age" -gt "$MAX_AGE" ]; then
                # A previous cycle's claim cannot vouch for this one. Inheriting
                # an unfalsifiable premise from an earlier run's artifact is a
                # failure this fleet has already paid for.
                echo "unattested:surface-claim-stale"
                exit 3
            fi
        fi
        case "$claim" in
            exposed)   echo "ok:surface-exposed"; exit 0 ;;
            unexposed) echo "unexposed:handshake-ok"; exit 1 ;;
            *)         echo "unattested:no-surface-claim"; exit 3 ;;
        esac
        ;;
    show)
        [ -f "$STAMP" ] && cat "$STAMP" || echo "(no surface attestation at $STAMP)"
        exit 0
        ;;
    fixture)
        _fx_fail=0
        _fx_dir="$(mktemp -d)"
        _fx_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
        _fx_stamp="$_fx_dir/surface"
        _fx_log="$_fx_dir/health.jsonl"
        _run() {
            TILLANDSIAS_MCP_SURFACE_STAMP="$_fx_stamp" \
            TILLANDSIAS_EXPERT_HEALTH_LOG="$_fx_log" \
            TILLANDSIAS_MCP_SURFACE_NOW="${_FX_NOW:-1000000}" \
                bash "$_fx_self" "$@"
        }
        _expect() {
            _n="$1"; _want_v="$2"; _want_rc="$3"; shift 3
            _got_v="$(_run "$@" 2>/dev/null)"; _got_rc=$?
            if [ "$_got_v" = "$_want_v" ] && [ "$_got_rc" = "$_want_rc" ]; then
                echo "ok: $_n ($_got_v rc=$_got_rc)"
            else
                echo "FAIL: $_n expected '$_want_v' rc=$_want_rc, got '$_got_v' rc=$_got_rc"
                _fx_fail=1
            fi
        }
        _healthy_log() {
            printf '{"ts":"t","server":"forge-plan","state":"up","host":"h","stage":"full"}\n{"ts":"t","server":"project-info","state":"up","host":"h","stage":"full"}\n' > "$_fx_log"
        }

        # 1. No handshake measurement yet: refuse to rule on the surface alone.
        : > "$_fx_log"
        _expect "no-health-log-refuses-to-rule" "skip:no-health-log" 3 check

        # 2. Handshake healthy, nothing attested: NOT ok. Silence must never
        #    read as exposure — the whole defect was silence reading as health.
        _healthy_log
        _expect "healthy-handshake-unattested-is-not-ok" "unattested:no-surface-claim" 3 check

        # 3. THE DEFECT, PINNED (the negative control that matters). Handshake
        #    healthy AND the cycle reports the tools were absent from its
        #    surface => a DISTINCT verdict, never ok:. This is the exact state
        #    windows was in for three consecutive cycles while the handshake
        #    probe printed ok:experts-healthy.
        _run attest unexposed --tools none --agent fixture >/dev/null 2>&1
        _expect "healthy-handshake-plus-unexposed-surface-is-its-own-state" \
            "unexposed:handshake-ok" 1 check

        # 4. Both halves good => ok, and only then.
        _run attest exposed --tools mcp__forge-plan__plan_answer --agent fixture >/dev/null 2>&1
        _expect "both-halves-good-is-ok" "ok:surface-exposed" 0 check

        # 5. NEGATIVE CONTROL: an `exposed` attestation may NOT rescue a broken
        #    handshake. The two halves are ANDed; neither can vouch for the
        #    other, or the join would be a way to launder a real outage.
        printf '{"ts":"t","server":"forge-plan","state":"down","host":"h","stage":"tool-call"}\n{"ts":"t","server":"project-info","state":"up","host":"h","stage":"full"}\n' > "$_fx_log"
        _expect "exposed-claim-cannot-launder-a-down-handshake" "down:forge-plan" 2 check

        # 6. NEGATIVE CONTROL: a claim from an earlier cycle expires rather than
        #    vouching for this one (the inherited-premise failure).
        _healthy_log
        _FX_NOW=1000000 _run attest exposed --agent fixture >/dev/null 2>&1
        _FX_NOW=$((1000000 + 14401)) _expect "a-stale-claim-does-not-vouch-for-this-cycle" \
            "unattested:surface-claim-stale" 3 check
        _FX_NOW=$((1000000 + 14399)) _expect "a-fresh-claim-still-counts" \
            "ok:surface-exposed" 0 check

        # 7. The claim must be STATED. A defaulted surface claim would be an
        #    invented measurement, which is the thing this file refuses to do.
        _got="$(_run attest 2>/dev/null)"
        case "$_got" in
            refused:attest-needs-a-claim:usage:*) echo "ok: attest-without-a-claim-is-refused" ;;
            *) echo "FAIL: attest with no claim expected a refusal naming its usage, got '$_got'"; _fx_fail=1 ;;
        esac

        # 8. absent stays absent (no expert to lose is not an outage).
        printf '{"ts":"t","server":"forge-plan","state":"absent","host":"h"}\n' > "$_fx_log"
        _expect "absent-registration-is-absent-not-unexposed" "absent:not-registered" 2 check

        # 9. Grammar: exactly one well-formed line per invocation.
        _healthy_log
        _lines="$(_run check 2>/dev/null | grep -cE '^(ok:surface-exposed|unexposed:handshake-ok|down:[a-z0-9-]+(,[a-z0-9-]+)*|absent:not-registered|unattested:(no-surface-claim|surface-claim-stale)|skip:[a-z0-9-]+)$')"
        if [ "$_lines" = "1" ]; then
            echo "ok: grammar-exactly-one-line"
        else
            echo "FAIL: grammar expected 1 well-formed line, got $_lines"
            _fx_fail=1
        fi

        rm -rf "$_fx_dir"
        [ "$_fx_fail" = 0 ] && echo "ok:mcp-surface-check-fixture:9"
        exit "$_fx_fail"
        ;;
    *)
        echo "usage: check-mcp-surface.sh [check|attest <exposed|unexposed> [--tools <csv>] [--agent <id>]|show|fixture]" >&2
        exit 2
        ;;
esac
