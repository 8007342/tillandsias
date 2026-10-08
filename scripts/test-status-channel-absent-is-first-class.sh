#!/usr/bin/env bash
# @trace order:1260-2qgi, spec:meta-orchestration
#
# Fixture for methodology/convergence.yaml -> status_channel_policy (order
# 1260-2qgi): a status carried by a channel is PRESERVED or DECLARED ABSENT,
# never a substituted integer; the verdict is ternary green / red / absent.
#
# THE CHANNEL UNDER TEST is the fleet's recipe for running a command whose
# status someone reads later. Since the coordinator's ruling it is the agent
# door, `tillandsias-plan run --json` (1443-8pur slice 2). Until the resolved
# plan binary's `run` speaks --json, the fixture drives TODAY's improvised
# recipe instead: that recipe is the pre-fix evidence, and arms 1/3/4 are
# expected to FAIL against it.
#
# Each arm drives three children and reads the channel's answer as a verdict:
#   rc1    exits 1                 -> must read RED   (exited 1)
#   killed never reports a status  -> must read ABSENT (never an integer)
#   ok     exits 0 (NEGATIVE CONTROL: absent is not the answer for everything)
#                                  -> must read GREEN (exited 0)
#
#   1. a DETACHED run's terminal line (what a Monitor or a later cycle reads);
#   2. the wsl.exe hop (scripts/lib-wsl-exec.sh's canary): it must either carry
#      the status or refuse, naming the drop. A named SKIP where there is no
#      wsl.exe (yolanda runs it on Windows);
#   3. `producer | tee log`: the status is the PRODUCER's, not tee's;
#   4. a child killed mid-run, by signal, from outside: ABSENT, not 128+N.
#      On Windows, arms 1/3/4 skip BY NAME (limit:windows-external-kill-reads-
#      as-exited) when the verb declares that limit. See WIN_LIMIT below.
#
# Verdict: ok:status-channel:absent-distinct-from-zero:<passed>/<run>, plus
# `skipped=<n>` when an arm could not run here. PRE-FIX RESULT: FAILS — the
# improvised recipe reports `rc=137` for a killed child and tee's 0 for a
# failed producer.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; run=0; skipped=0
# ONE NAMED LIMIT (1443-8pur, the forge, 2026-09-28): on Windows a child killed
# from OUTSIDE (not by the verb) reaches the native exe as exited 2304 (9<<8).
# The verb does not decode it, because a native exe may exit 2304 on purpose,
# and it declares the limit by this token in its usage text. Arms that kill
# from outside SKIP BY THAT NAME there. They never read it as absent, and they
# never read it as a pass.
WIN_LIMIT="limit:windows-external-kill-reads-as-exited"
ON_WINDOWS=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=1 ;; esac
ok()  { echo "ok:   $1"; pass=$((pass+1)); run=$((run+1)); }
bad() { echo "FAIL: $1"; run=$((run+1)); }
skip() { echo "skip: $1"; skipped=$((skipped+1)); }

_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
PLAN="$_plan"

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/status-channel.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# The children, as script FILES (the door refuses command strings).
printf '#!/bin/bash\nexit 1\n' > "$W/rc1.sh"
printf '#!/bin/bash\nexit 0\n' > "$W/ok.sh"
# Records its pid, then waits to be killed from outside.
printf '#!/bin/bash\necho $$ > "%s/killme.pid"\nexec sleep 60\n' "$W" > "$W/killme.sh"
printf '#!/bin/bash\necho produced\nexit 1\n' > "$W/producer-fails.sh"
printf '#!/bin/bash\necho produced\nexit 0\n' > "$W/producer-ok.sh"

# Does the door speak --json? (1443-8pur slice 2.) Asked by running it.
DOOR=0
if [ -n "$PLAN" ] && "$PLAN" run --json -- bash "$W/ok.sh" 2>/dev/null | grep -q '"status"'; then
    DOOR=1
fi
# The limit counts only when the binary under test DECLARES it.
LIMIT_DECLARED=0
if [ "$ON_WINDOWS" = 1 ] && [ -n "$PLAN" ] && grep -qF "$WIN_LIMIT" <<<"$("$PLAN" run --help 2>&1)"; then
    LIMIT_DECLARED=1
fi
# killed_verdict <terminal line>: verdict, or the named limit on Windows
killed_verdict() {
    local v
    v="$(verdict "$1")"
    if [ "$v" = "red:2304" ] && [ "$ON_WINDOWS" = 1 ] && [ "$LIMIT_DECLARED" = 1 ]; then
        echo "$WIN_LIMIT"
    else
        echo "$v"
    fi
}
echo "channel: $([ "$DOOR" = 1 ] && echo "agent door (tillandsias-plan run --json)" || echo "improvised recipe (pre-fix: the door has no --json on this binary)")"

# verdict <terminal line> -> green | red:<n> | absent:<why> | unparsed:<line>
verdict() {
    local line="$1" st code
    case "$line" in
        *'"status"'*)
            st="$(printf '%s' "$line" | "$PLAN" json get -r '.status' 2>/dev/null)"
            case "$st" in
                exited)
                    code="$(printf '%s' "$line" | "$PLAN" json get -r '.code' 2>/dev/null)"
                    [ "$code" = 0 ] && echo green || echo "red:$code" ;;
                # The door's agreed vocabulary (1443-8pur, macuahuitl-forge,
                # 2026-09-28): `code` is an integer ONLY for exited, JSON null
                # for every other status. Every non-exited status is a status
                # that did NOT come from the child exiting: absent.
                signaled|timed_out|no_status|spawn_failed|policy_denied|policy_consent) echo "absent:$st" ;;
                *) echo "unparsed:$line" ;;
            esac ;;
        rc=absent*) echo "absent:${line#rc=absent:}" ;;
        rc=0) echo green ;;
        rc=[0-9]*) echo "red:${line#rc=}" ;;
        "") echo "absent:no-terminal-line" ;;
        *) echo "unparsed:$line" ;;
    esac
}

# The DETACHED recipe, run to completion: its terminal line.
#   door:       tillandsias-plan run --json -- <argv>   (last line of the log)
#   improvised: the runbooks' `nohup launcher & disown` with `echo "rc=$?"`
detached() { # detached <name> <argv...> -> prints the terminal line
    local name="$1"; shift
    local log="$W/$name.log" launcher="$W/$name.launch.sh"
    if [ "$DOOR" = 1 ]; then
        printf '#!/bin/bash\n"%s" run --json -- %s\n' "$PLAN" "$*" > "$launcher"
    else
        printf '#!/bin/bash\n%s\necho "rc=$?"\n' "$*" > "$launcher"
    fi
    nohup bash "$launcher" </dev/null >"$log" 2>&1 &
    local pid=$!
    disown 2>/dev/null || true
    if [ "$name" = killed ]; then
        local i=0
        while [ ! -s "$W/killme.pid" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
        kill -KILL "$(cat "$W/killme.pid" 2>/dev/null)" 2>/dev/null
        rm -f "$W/killme.pid"
    fi
    while kill -0 "$pid" 2>/dev/null; do sleep 0.05; done
    awk 'NF { l = $0 } END { print l }' "$log"
}

expect_arm() { # expect_arm <arm label> <red line> <killed line> <ok line>
    local label="$1" v_red v_abs v_ok
    v_red="$(verdict "$2")"; v_abs="$(killed_verdict "$3")"; v_ok="$(verdict "$4")"
    if [ "$v_abs" = "$WIN_LIMIT" ]; then
        if [ "$v_red" = "red:1" ] && [ "$v_ok" = green ]; then
            skip "$label: killed-from-outside leg is $WIN_LIMIT (declared by the verb); rc1 -> red:1, exit 0 -> green"
        else
            bad "$label: rc1 -> $v_red (want red:1), exit 0 -> $v_ok (want green); killed leg $WIN_LIMIT"
        fi
        return
    fi
    if [ "$v_red" = "red:1" ] && [ "${v_abs%%:*}" = absent ] && [ "$v_ok" = green ]; then
        ok "$label: rc1 -> red:1, killed -> $v_abs, exit 0 -> green"
    else
        bad "$label: rc1 -> $v_red (want red:1), killed -> $v_abs (want absent:…), exit 0 -> $v_ok (want green)"
    fi
}

# 1 — a detached run's terminal line.
expect_arm "arm 1 (detached terminal line)" \
    "$(detached rc1 bash "$W/rc1.sh")" \
    "$(detached killed bash "$W/killme.sh")" \
    "$(detached ok bash "$W/ok.sh")"

# 2 — the wsl.exe hop: carry the status, or refuse naming the drop.
if ! command -v wsl.exe >/dev/null 2>&1; then
    skip "arm 2 (wsl.exe hop): no wsl.exe on this host — yolanda runs this arm on Windows"
else
    distro="${TILLANDSIAS_WSL_DISTRO:-tillandsias}"
    out2="$(. "$ROOT/scripts/lib-wsl-exec.sh" && wsl_exec_transport_ok "$distro" 2>&1)"; rc2=$?
    case "$out2" in
        *"ok:wsl-exec-transport:carries-exit-status"*)
            [ "$rc2" -eq 0 ] && ok "arm 2 (wsl.exe hop): the status is carried" || bad "arm 2: carried, but rc=$rc2" ;;
        *"refused:wsl-exec-transport:drops-exit-status"*)
            [ "$rc2" -ne 0 ] && ok "arm 2 (wsl.exe hop): the drop is DECLARED (refused, rc=$rc2), not substituted" \
                             || bad "arm 2: declared a drop but exited 0" ;;
        *) bad "arm 2 (wsl.exe hop): neither carried nor declared: [$out2] rc=$rc2" ;;
    esac
fi

# 3 — producer | tee: the verdict is the producer's.
pipeline() { # pipeline <producer.sh> -> the recipe's terminal line
    if [ "$DOOR" = 1 ]; then
        "$PLAN" run --json -- bash "$1" 2>/dev/null | tee "$W/tee.log" | awk 'NF { l = $0 } END { print l }'
    else
        # The improvised recipe: `$?` after the pipeline, which is tee's. Run in
        # a FRESH shell, as an agent's shell runs it: this fixture's own
        # `set -o pipefail` would otherwise lend the recipe a guard it lacks.
        bash -c 'bash "$1" | tee "$2" >/dev/null; echo "rc=$?"' _ "$1" "$W/tee.log"
    fi
}
expect_arm "arm 3 (producer | tee)" \
    "$(pipeline "$W/producer-fails.sh")" \
    "$(detached killed bash "$W/killme.sh")" \
    "$(pipeline "$W/producer-ok.sh")"

# 4 — a child killed mid-run, from outside, by signal: absent, never 128+N.
k4="$(detached killed bash "$W/killme.sh")"
v4="$(killed_verdict "$k4")"
if [ "$v4" = "$WIN_LIMIT" ]; then
    skip "arm 4 (killed mid-run): $WIN_LIMIT — an external kill on Windows reads as exited 2304; declared by the verb, not decoded"
elif [ "${v4%%:*}" = absent ]; then
    ok "arm 4 (killed mid-run): absent ($v4)"
else
    bad "arm 4 (killed mid-run): read as $v4 from [$k4] — a substituted integer, not absent"
fi

if [ "$pass" -eq "$run" ] && [ "$run" -gt 0 ]; then
    echo "ok:status-channel:absent-distinct-from-zero:${pass}/${run}$([ "$skipped" -gt 0 ] && echo " skipped=$skipped")"
    exit 0
fi
echo "fail:status-channel:absent-distinct-from-zero:${pass}/${run}$([ "$skipped" -gt 0 ] && echo " skipped=$skipped")"
exit 1
