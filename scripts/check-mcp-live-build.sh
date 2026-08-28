#!/usr/bin/env bash
# freshness: added 2026-08-28 linux-yoga (order 823-u3k9)
# @trace order:823-u3k9, order:799-j4xd, order:801-m9tk, order:737-zcj5
# @trace invariant:plan_is_queried_via_mcp_server_avoiding_heuristic_parsing
#
# check-mcp-live-build.sh — is the server the agent REACHES running current code?
#
# ── THE DEFECT (order 823-u3k9) ──────────────────────────────────────────────
#
# On 2026-08-18 a macuahuitl session asked spec_answer a question and got a
# refusal naming a WSL path, on a Linux host, reciting prose that order 799-j4xd
# had removed from the file the day before. Four things were measurably true and
# did not agree: L0 was fine, the index was fine, THE FILE was fine — and
# scripts/check-mcp-expert-health.sh printed `ok:experts-healthy`.
#
# The running process predated the fix. 799-j4xd's own comment had already named
# the rule: A FIX IN A FILE DOES NOT REACH A PROCESS THAT ALREADY READ IT. It
# recurred anyway, and nothing caught it.
#
# WHY THE HEALTH PROBE CANNOT CATCH IT, EVER. It reads the registration and
# starts a FRESH server (`cmd="$(server_command ...)"; probe_server ...`). That
# new process reads the current file and is healthy BY CONSTRUCTION. The
# long-lived process the agent's tool calls actually reach is never contacted.
# This is not a gap to harden — hardening the probe measures the fresh instance
# harder. L0 hides it further: plan_answer shells out to the freshly built
# binary, so `source_commit` tracks HEAD however old the server shell is. The
# freshest-looking field in the envelope is the one least able to see this.
#
# NOT THE SAME QUESTION AS 801-m9tk. check-mcp-surface.sh asks "were the tools
# BOUND to this session at all". A stale server is bound, answering, and wrong.
# Its handshake is healthy, its surface is exposed, and its content predates a
# landed fix. Three orthogonal facts; this file owns the third.
#
# AND THE REGISTRATION IS NOT THE GAP, measured rather than assumed: the probe
# reads `.mcp.json`, which is the same registration the harness reads. The gap
# is PROCESS LIFETIME, which no registration can express.
#
# ── THE SPLIT, ALONG WHAT IS KNOWABLE (the 801-m9tk shape, different fact) ───
#
#   the SERVER reports its own build   captured at startup from the file it was
#                                      launched from (lib-mcp-build-id.sh)
#   the AGENT attests what it received by calling the LIVE tool and reading the
#                                      `server_build:` line out of the answer
#   this check JOINS them against disk  script-observable, falsifiable
#
# A subprocess cannot reach the agent's long-lived server: it has no handle on
# it, and launching one is the defect. So the live half is an ATTESTATION — the
# same standing as every `verified-by` event in this repo, and strictly better
# than the status quo, where a stale server left no trace at all.
#
# The DEFAULT is honest: an unattested cycle reads `unattested:`, never `ok:`.
# And a stale claim expires, so an earlier cycle's attestation cannot vouch for
# this one's process.
#
# RESIDUAL, stated: an agent that attests an id it did not receive is not
# caught. It is narrower than it looks — the attesting agent is the one harmed,
# since the record exists to explain its own wrong answers.
#
# ── GRAMMAR (exactly one line on stdout) ─────────────────────────────────────
#   ok:live-build-current:<server>            attested id == the file on disk (0)
#   stale:live-server-build:<server>:<a>!=<d> THE NEW STATE: the process the
#                                             agent reaches predates the file.
#                                             A named state, not a green one (1)
#   unattested:no-live-build-claim            nothing attested this cycle     (3)
#   unattested:live-build-claim-stale         the claim predates the window   (3)
#   stale:live-server-build-unreported:<s>    the live server emitted NO
#                                             `server_build:` line at all, so it
#                                             predates this mechanism entirely.
#                                             MEASURED, not hypothesised: the
#                                             session that wrote this file hit
#                                             it on its own forge-plan server
#                                             one minute after landing the
#                                             emitter — a freshly spawned server
#                                             reported the line, the long-lived
#                                             one did not                     (1)
#   unavailable:build-id-unknown              no digest tool, or the attested
#                                             id is `unknown` — UNKNOWABLE is
#                                             never `current`                 (2)
#   unavailable:server-source-unreadable      the attested source path is not
#                                             readable from here              (2)
#
# ADVISORY, NEVER A GATE — same contract as its two siblings. A stale expert is
# an expensive read path, not a blocked cycle. Record and continue.
#
# Seams (used by the fixture):
#   TILLANDSIAS_MCP_LIVE_BUILD_STAMP    attestation path (default <git-dir>/…)
#   TILLANDSIAS_MCP_LIVE_BUILD_MAX_AGE  freshness window in seconds (14400)
#   TILLANDSIAS_MCP_LIVE_BUILD_NOW      force "now" as an epoch

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || ROOT="."
_git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null || echo .git)"
STAMP="${TILLANDSIAS_MCP_LIVE_BUILD_STAMP:-$_git_dir/tillandsias-mcp-live-build}"
MAX_AGE="${TILLANDSIAS_MCP_LIVE_BUILD_MAX_AGE:-14400}"

# The SAME id function the server ran at startup, from the same file. Two
# readers of one implementation, so the comparison can only ever fail because
# the process is old — never because the two sides hash differently.
for _lib in \
    "${TILLANDSIAS_MCP_BUILD_ID_LIB:-}" \
    "$ROOT/images/default/lib-mcp-build-id.sh" \
    "/usr/local/lib/tillandsias/lib-mcp-build-id.sh"; do
    if [ -n "$_lib" ] && [ -r "$_lib" ]; then
        # shellcheck source=images/default/lib-mcp-build-id.sh
        . "$_lib"
        break
    fi
done

now_epoch() {
    if [ -n "${TILLANDSIAS_MCP_LIVE_BUILD_NOW:-}" ]; then
        printf '%s\n' "$TILLANDSIAS_MCP_LIVE_BUILD_NOW"
        return 0
    fi
    date -u +%s 2>/dev/null || echo 0
}

stamp_field() {
    [ -f "$STAMP" ] || return 1
    # Space-split, name-anchored — never `\b`, which BSD sed silently never
    # matches and which cost 803-bqte every macOS attestation.
    tr ' ' '\n' <"$STAMP" 2>/dev/null \
        | sed -n "s/^$1=\\(.*\\)\$/\\1/p" \
        | grep -m1 . || return 1
}

usage() {
    cat >&2 <<'USAGE'
usage: check-mcp-live-build.sh [check|attest <server>=<build-id> --source <path> [--agent ID]|show|fixture]

  How to attest, for an agent that has the experts on its tool surface:
    1. call the LIVE tool  mcp__forge-plan__expert_capability
    2. read the `server_build: forge-plan=<id> source=<path>` line it returns
    3. check-mcp-live-build.sh attest forge-plan=<id> --source <path>

  If the answer carries NO `server_build:` line, that IS the finding — the
  running server predates the emitter. Attest it as such, do not skip:
       check-mcp-live-build.sh attest forge-plan=unreported --source <path>

  Step 1 must go through the agent's OWN tool surface. Shelling out to the
  server script launches a fresh process and re-measures the file, which is the
  precise defect this check exists to detect.
USAGE
}

case "${1:-check}" in
    attest)
        claim="${2:-}"
        case "$claim" in
            *=*) server="${claim%%=*}"; build="${claim#*=}" ;;
            *) echo "refused:attest-needs-a-server-and-build-id"; usage; exit 2 ;;
        esac
        if [ -z "$server" ] || [ -z "$build" ]; then
            echo "refused:attest-needs-a-server-and-build-id"; usage; exit 2
        fi
        shift 2 2>/dev/null || shift
        source_path=""; agent="${TILLANDSIAS_AGENT_ID:-unknown}"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --source) source_path="${2:-}"; shift 2 || shift ;;
                --agent) agent="${2:-unknown}"; shift 2 || shift ;;
                *) shift ;;
            esac
        done
        if [ -z "$source_path" ]; then
            # Without the path there is nothing to compare the id AGAINST, and a
            # guessed path would make the verdict a guess.
            echo "refused:attest-needs-the-source-path-the-server-reported"; usage; exit 2
        fi
        mkdir -p "$(dirname "$STAMP")" 2>/dev/null || true
        printf 'ts=%s epoch=%s server=%s build=%s source=%s agent=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
            "$(now_epoch)" "$server" "$build" "$source_path" "$agent" \
            >"$STAMP" 2>/dev/null || { echo "refused:attest-unwritable-stamp"; exit 2; }
        echo "ok:live-build-attested:$server=$build"
        exit 0
        ;;
    check)
        server="$(stamp_field server)" || server=""
        attested="$(stamp_field build)" || attested=""
        source_path="$(stamp_field source)" || source_path=""
        if [ -z "$server" ] || [ -z "$attested" ] || [ -z "$source_path" ]; then
            echo "unattested:no-live-build-claim"
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
                # An earlier cycle's claim describes an earlier cycle's PROCESS.
                # Inheriting it is the unfalsifiable-premise failure again.
                echo "unattested:live-build-claim-stale"
                exit 3
            fi
        fi

        case "$source_path" in
            /*) abs="$source_path" ;;
            *)  abs="$ROOT/$source_path" ;;
        esac
        if [ ! -r "$abs" ]; then
            echo "unavailable:server-source-unreadable"
            exit 2
        fi
        if ! command -v tillandsias_mcp_build_id >/dev/null 2>&1; then
            echo "unavailable:build-id-unknown"
            exit 2
        fi
        ondisk="$(tillandsias_mcp_build_id "$abs")"
        # UNKNOWABLE is never `current`. Comparing two `unknown`s and calling it
        # a match would manufacture the green this file exists to withdraw.
        if [ "$attested" = "unreported" ]; then
            # The live server answered, and its answer carried no build line at
            # all. It cannot be current: the file on disk emits one. Naming this
            # separately matters because the REMEDY differs — `unknown` means
            # this check cannot tell, `unreported` means the server is old.
            echo "stale:live-server-build-unreported:$server"
            exit 1
        fi
        if [ "$ondisk" = "unknown" ] || [ "$attested" = "unknown" ]; then
            echo "unavailable:build-id-unknown"
            exit 2
        fi
        if [ "$attested" != "$ondisk" ]; then
            echo "stale:live-server-build:$server:$attested!=$ondisk"
            exit 1
        fi
        echo "ok:live-build-current:$server"
        exit 0
        ;;
    show)
        [ -f "$STAMP" ] && cat "$STAMP" || echo "(no live-build attestation at $STAMP)"
        exit 0
        ;;
    fixture)
        _fx_fail=0
        _fx_dir="$(mktemp -d)"
        _fx_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
        _fx_stamp="$_fx_dir/live-build"
        _fx_src="$_fx_dir/server.sh"
        _run() {
            TILLANDSIAS_MCP_LIVE_BUILD_STAMP="$_fx_stamp" \
            TILLANDSIAS_MCP_LIVE_BUILD_NOW="${_FX_NOW:-1000000}" \
                bash "$_fx_self" "$@"
        }
        _expect() {
            _n="$1"; _want="$2"; _rc="$3"; shift 3
            _got="$(_run "$@" 2>/dev/null)"; _grc=$?
            if [ "$_got" = "$_want" ] && [ "$_grc" = "$_rc" ]; then
                echo "ok: $_n ($_got rc=$_grc)"
            else
                echo "FAIL: $_n expected '$_want' rc=$_rc, got '$_got' rc=$_grc"
                _fx_fail=1
            fi
        }
        _id_of() { tillandsias_mcp_build_id "$1"; }

        printf '#!/bin/sh\necho v1\n' >"$_fx_src"
        _v1="$(_id_of "$_fx_src")"

        # 1. Nothing attested: NOT ok. Silence reading as health is the whole
        #    defect, one level up.
        rm -f "$_fx_stamp"
        _expect "unattested-is-not-ok" "unattested:no-live-build-claim" 3 check

        # 2. The running process reports the id of the file as it stands: ok.
        _run attest "forge-plan=$_v1" --source "$_fx_src" --agent fixture >/dev/null 2>&1
        _expect "attested-id-matching-disk-is-current" "ok:live-build-current:forge-plan" 0 check

        # 3. THE DEFECT, PINNED. The file is fixed; the process still carries the
        #    id it read at startup. This is 799-j4xd reaching the file and not
        #    the server, on 2026-08-18, while every other signal read green.
        printf '#!/bin/sh\necho v2-the-fix-landed\n' >"$_fx_src"
        _v2="$(_id_of "$_fx_src")"
        _expect "a-process-that-predates-the-file-is-a-named-state" \
            "stale:live-server-build:forge-plan:$_v1!=$_v2" 1 check

        # 4. Relaunched against the fixed file: green returns, and only then.
        _run attest "forge-plan=$_v2" --source "$_fx_src" --agent fixture >/dev/null 2>&1
        _expect "relaunching-onto-the-fixed-file-clears-it" "ok:live-build-current:forge-plan" 0 check

        # 5. NEGATIVE CONTROL: an UNKNOWABLE id must never compare equal. Two
        #    `unknown`s matching would manufacture exactly the green being
        #    withdrawn here.
        _run attest "forge-plan=unknown" --source "$_fx_src" --agent fixture >/dev/null 2>&1
        _expect "unknown-is-never-current" "unavailable:build-id-unknown" 2 check

        # 6. NEGATIVE CONTROL: an unreadable source is `unavailable:`, not
        #    `stale:`. A comparison that could not be made must not be reported
        #    as a comparison that failed.
        _run attest "forge-plan=$_v2" --source "$_fx_dir/gone.sh" --agent fixture >/dev/null 2>&1
        _expect "unreadable-source-is-unavailable-not-stale" \
            "unavailable:server-source-unreadable" 2 check

        # 7. A claim from an earlier cycle describes an earlier PROCESS and must
        #    expire rather than vouch for this one.
        _FX_NOW=1000000 _run attest "forge-plan=$_v2" --source "$_fx_src" >/dev/null 2>&1
        _FX_NOW=$((1000000 + 14401)) _expect "a-stale-claim-does-not-vouch-for-this-cycle" \
            "unattested:live-build-claim-stale" 3 check
        _FX_NOW=$((1000000 + 14399)) _expect "a-fresh-claim-still-counts" \
            "ok:live-build-current:forge-plan" 0 check

        # 8. The claim must be STATED, both halves. A defaulted source path would
        #    make the verdict a guess about which file the process read.
        _got="$(_run attest 2>/dev/null)"
        [ "$_got" = "refused:attest-needs-a-server-and-build-id" ] \
            && echo "ok: attest-without-a-claim-is-refused" \
            || { echo "FAIL: bare attest expected a refusal, got '$_got'"; _fx_fail=1; }
        _got="$(_run attest "forge-plan=$_v2" 2>/dev/null)"
        [ "$_got" = "refused:attest-needs-the-source-path-the-server-reported" ] \
            && echo "ok: attest-without-a-source-is-refused" \
            || { echo "FAIL: sourceless attest expected a refusal, got '$_got'"; _fx_fail=1; }

        # 9. THE REAL SERVER honours the contract: forge-plan reports a
        #    `server_build:` line whose id is the id of its own file. Without
        #    this the whole join is a fixture talking to itself.
        _real="$ROOT/images/default/config-overlay/mcp/forge-plan.sh"
        if grep -q "server_build: forge-plan=" "$_real" 2>/dev/null \
           && grep -q 'MCP_SERVER_BUILD_ID="\$(tillandsias_mcp_build_id' "$_real" 2>/dev/null; then
            echo "ok: the-real-forge-plan-server-reports-its-own-build"
        else
            echo "FAIL: $_real does not compute and report a server_build id"
            _fx_fail=1
        fi

        # 9b. MEASURED IN THE WILD, kept as a fixture. A live server older than
        #     the emitter reports no build line; that is a stale process, not an
        #     indeterminate one, and it must not read `unavailable:`.
        _run attest "forge-plan=unreported" --source "$_fx_src" >/dev/null 2>&1
        _expect "a-server-that-reports-no-build-is-stale-not-unknown" \
            "stale:live-server-build-unreported:forge-plan" 1 check

        # 10. Grammar: exactly one well-formed line per invocation.
        _run attest "forge-plan=$_v2" --source "$_fx_src" >/dev/null 2>&1
        _lines="$(_run check 2>/dev/null | grep -cE '^(ok:live-build-current:[a-z0-9-]+|stale:live-server-build:[a-z0-9-]+:[0-9a-f]+!=[0-9a-f]+|stale:live-server-build-unreported:[a-z0-9-]+|unattested:(no-live-build-claim|live-build-claim-stale)|unavailable:[a-z-]+)$')"
        if [ "$_lines" = "1" ]; then
            echo "ok: grammar-exactly-one-line"
        else
            echo "FAIL: grammar expected 1 well-formed line, got $_lines"
            _fx_fail=1
        fi

        rm -rf "$_fx_dir"
        [ "$_fx_fail" = 0 ] && echo "ok:mcp-live-build-check-fixture:11"
        exit "$_fx_fail"
        ;;
    *)
        usage
        exit 2
        ;;
esac
