#!/usr/bin/env bash
# Fixture for scripts/lib-wsl-exec.sh (order 1155-jurn).
#
# REGIME: runs anywhere. The decision arms drive the comparison with SUPPLIED
# values rather than the live transport, so they have teeth on every host — the
# retargeting 793-zumy's shape test needed for the same reason. The live arm is
# msys-only and SKIPS loudly elsewhere; a fixture that can only ever see a
# healthy transport proves nothing about an unhealthy one.
#
# WHAT THIS FIXTURE EXISTS TO PREVENT, beyond the defect itself: the FIRST
# version of lib-wsl-exec.sh probed the shell it was running in, passed against
# the real broken hop, and would have shipped as a green safeguard over a
# channel that was still zeroing every caller's exit status. Arm 5 is the arm
# that would have caught it — it pins that the check must read a status sent
# THROUGH the hop, not one evaluated locally.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

. "$ROOT/scripts/lib-wsl-exec.sh"

# ── arm 1: no distro named is a refusal, not a silent pass ──────────────────
out="$(wsl_exec_transport_ok 2>&1)"; rc=$?
case "$out" in
    refused:wsl-exec-transport:no-distro-named*)
        [ "$rc" -eq 1 ] && ok "arm 1: a missing distro refuses with rc=1" \
                        || bad "arm 1: right verdict, wrong rc=$rc" ;;
    skip:wsl-exec-transport:no-wsl-on-this-host*)
        ok "arm 1: no wsl on this host — reported as skip, not as a pass" ;;
    *) bad "arm 1: expected a refusal or a skip, got '$out' rc=$rc" ;;
esac

# ── arm 2: a host with no wsl.exe SKIPS rather than passing ─────────────────
# Not-applicable and healthy are different findings; conflating them is how a
# guard reports green on a host it never examined.
if grep -q 'skip:wsl-exec-transport:no-wsl-on-this-host' "$ROOT/scripts/lib-wsl-exec.sh"; then
    ok "arm 2: absence of wsl.exe is a named skip, not a pass"
else
    bad "arm 2: no skip verdict for a host without wsl.exe"
fi

# ── arm 3: the header mandates running it BEFORE the protected measurement ──
if grep -q "run it BEFORE the measurement it protects" "$ROOT/scripts/lib-wsl-exec.sh"; then
    ok "arm 3: the before-not-after instruction is present"
else
    bad "arm 3: the before-not-after instruction is missing"
fi

# ── arm 4: MUTATION CONTROL on the decision itself ──────────────────────────
verdict_for() { # <false_result> <seven_result> -> pass|refuse
    [ "$1" = "1" ] && [ "$2" = "7" ] && echo pass || echo refuse
}
m=0
[ "$(verdict_for 1 7)"   = "pass" ]   || { bad "arm 4: a sound pair must pass"; m=1; }
[ "$(verdict_for 0 0)"   = "refuse" ] || { bad "arm 4: the msys shape (0,0) must refuse"; m=1; }
[ "$(verdict_for '' '')" = "refuse" ] || { bad "arm 4: empty results must refuse"; m=1; }
[ "$(verdict_for 1 0)"   = "refuse" ] || { bad "arm 4: a half-sound pair must refuse"; m=1; }
[ "$m" -eq 0 ] && ok "arm 4: refuses (0,0), (empty,empty) and a half-sound pair"

# ── arm 5: THE CHECK MUST READ A STATUS SENT THROUGH THE HOP ────────────────
# This is the arm that catches the mistake the first implementation made. A
# check whose `$?` is evaluated locally cannot see this defect, because a `$?`
# inside a file is CORRECT — only the argument string is mangled. So the body
# must send its probes through wsl.exe rather than running them inline.
body="$(cat "$ROOT/scripts/lib-wsl-exec.sh")"
miss=""
case "$body" in *'wsl.exe -d "$distro" -- bash -lc'*) : ;; *) miss="$miss sends-through-the-hop" ;; esac
case "$body" in *'it is the argument string that is'*) : ;; *) miss="$miss names-the-argument-string" ;; esac
if [ -z "$miss" ]; then
    ok "arm 5: the check probes the TRANSPORT, and says why a local probe cannot"
else
    bad "arm 5: implementation is missing:$miss (a local probe always passes)"
fi

# ── arm 6: the refusal names the remedy AND both measured non-remedies ──────
miss=""
case "$body" in *"script FILE"*)  : ;; *) miss="$miss script-file-remedy" ;; esac
case "$body" in *"MSYS_NO_PATHCONV"*)      : ;; *) miss="$miss msys-no-pathconv" ;; esac
case "$body" in *"MSYS2_ARG_CONV_EXCL"*)   : ;; *) miss="$miss arg-conv-excl" ;; esac
if [ -z "$miss" ]; then
    ok "arm 6: the refusal names the remedy and both measured non-remedies"
else
    bad "arm 6: refusal text is missing:$miss"
fi

# ── arm 7: LIVE, msys only — the real transport is exercised or skipped loudly ──
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        if command -v wsl.exe >/dev/null 2>&1; then
            live="$(wsl_exec_transport_ok "${TILLANDSIAS_CANARY_DISTRO:-tillandsias-build}" 2>&1)"
            case "$live" in
                ok:wsl-exec-transport:carries-exit-status*)
                    ok "arm 7 (live): this host's transport carries exit status" ;;
                refused:wsl-exec-transport:drops-exit-status*)
                    ok "arm 7 (live): this host's transport DROPS exit status — canary fires" ;;
                *) bad "arm 7 (live): unrecognised verdict '$live'" ;;
            esac
        else
            ok "arm 7 (live): skipped — msys host with no wsl.exe"
        fi ;;
    *) ok "arm 7 (live): skipped — not an msys host, the defect cannot occur here" ;;
esac

if [ "$fail" -eq 0 ]; then
    echo "ok:wsl-exec-channel-fixture:all"
else
    echo "FAIL:wsl-exec-channel-fixture"
    exit 1
fi
