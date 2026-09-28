#!/usr/bin/env bash
# @trace order:1457-r8yi, spec:simplified-tray-ux
#
# A Linux lane that fails inside the container used to ask for TWO keypresses:
# the entrypoint's exit_pause ("Press any key") and then the host's
# `tillandsias --hold-window` ("Press Enter"). The host now passes
# TILLANDSIAS_HOST_HOLDS_WINDOW=1 into the forge by name, and exit_pause skips
# its own pause when it is set. It does NOT delete the traps (828-h7kw: all six
# are live, and they are the only hold on the macOS and Windows lanes).
#
# For EACH of the six entrypoints, its real exit_pause is extracted and run on a
# real pseudo-terminal (`script`), since the pause only happens when stdin is a
# TTY, after a failing command:
#   held   -> the error banner is printed, no "Press any key", returns at once
#   unheld -> CONTROL: it still blocks on the keypress (timeout fires), so the
#             pause exists and only the held case skips it
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v script >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    echo "skip:exit-pause-host-hold:no-script-or-timeout"
    exit 3
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/exit-pause-hold.XXXXXX")"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

for ep in entrypoint-forge-antigravity entrypoint-forge-claude entrypoint-forge-codex \
          entrypoint-forge-opencode entrypoint-forge-opencode-web entrypoint-terminal; do
    src="$ROOT/images/default/$ep.sh"
    fn="$(awk '/^exit_pause\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$src")"
    if [ -z "$fn" ]; then bad "$ep: premise: no exit_pause function found"; continue; fi
    {
        printf '%s\n' "$fn"
        printf 'trap exit_pause EXIT\nfalse\nexit 1\n'
    } > "$W/$ep.sh"
    # stdin stays OPEN past the timeout (a sleeping writer): with </dev/null the
    # pty sees EOF at once, `read` returns, and neither arm could tell a pause
    # from none. Process substitution, so nothing waits for the writer.
    out="$(TILLANDSIAS_HOST_HOLDS_WINDOW=1 timeout 5 script -qec "bash $W/$ep.sh" /dev/null < <(sleep 8) 2>&1)"; rc=$?
    if [ "$rc" != 124 ] && grep -q 'ERROR' <<<"$out" && ! grep -q 'Press any key' <<<"$out"; then
        held=ok
    else held="rc=$rc out=[$(tr -d '\r' <<<"$out" | tail -2 | tr '\n' ' ')]"; fi
    env -u TILLANDSIAS_HOST_HOLDS_WINDOW timeout 3 script -qec "bash $W/$ep.sh" /dev/null < <(sleep 8) >"$W/$ep.unheld" 2>&1
    urc=$?
    if [ "$held" = ok ] && [ "$urc" = 124 ] && grep -q 'Press any key' "$W/$ep.unheld"; then
        ok "$ep: held -> banner, no second pause; unheld -> still pauses"
    else
        bad "$ep: held=[$held] unheld_rc=$urc"
    fi
done
echo "$([ "$fail" = 0 ] && echo ok || echo fail):exit-pause-host-hold:${pass}/$((pass + fail))"
[ "$fail" = 0 ]
