#!/usr/bin/env bash
# @trace order:1385-h6uz
#
# Pins images/default/opencode-tool-start-follower.sh: the prompted opencode
# lane announces each tool call when it STARTS, from opencode's own log,
# because `opencode run` prints a call only when it completes (a three-hour
# silent macOS smoke lane was one long call). Hermetic: a scratch log stands
# in for opencode's.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"
FOLLOW="$ROOT/images/default/opencode-tool-start-follower.sh"
ENTRY="$ROOT/images/default/entrypoint-forge-opencode.sh"
IMAGE="$ROOT/images/default/Containerfile"

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
FPID=""
cleanup() { [ -n "$FPID" ] && kill "$FPID" 2>/dev/null; pkill -f "tail -n 0 -F $TMP/" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

LOG="$TMP/opencode.log"
printf '%s\n' 'timestamp=OLD level=INFO message=evaluated permission=bash pattern="history-from-an-earlier-run" action.permission=*' > "$LOG"
bash "$FOLLOW" "$LOG" 5 > "$TMP/out" 2>&1 &
FPID=$!
# Out of the job table, so killing it at exit prints no "Terminated" line
# after the verdict (a gate reads the LAST line).
disown "$FPID" 2>/dev/null || true
sleep 1
printf '%s\n' 'timestamp=2026-09-26T13:39:50.047Z level=INFO run=x message=evaluated permission=bash pattern="sleep 5" action.permission=* action.action=allow action.pattern=*' >> "$LOG"
printf '%s\n' 'timestamp=T level=INFO message="an unrelated log line"' >> "$LOG"
printf '%s\n' 'timestamp=T level=INFO message=evaluated permission=edit pattern=src/main.rs action.permission=*' >> "$LOG"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'src/main.rs' "$TMP/out" 2>/dev/null && break; sleep 0.3; done
out="$(cat "$TMP/out")"

# ARM 1: a new tool call is announced, with its command.
case "$out" in *"[forge] tool start: bash: sleep 5"*) ok "a new bash call is announced with its command" ;; *) bad "no announcement for 'sleep 5': $out" ;; esac
# ARM 2: an unquoted pattern is announced too.
case "$out" in *"[forge] tool start: edit: src/main.rs"*) ok "an unquoted pattern is announced" ;; *) bad "unquoted pattern missing: $out" ;; esac
# ARM 3: an earlier run's history is never replayed.
case "$out" in *history-from-an-earlier-run*) bad "replayed history from before it started: $out" ;; *) ok "history before the follower started is not replayed" ;; esac
# ARM 4: unrelated log lines are not echoed.
case "$out" in *"unrelated log line"*) bad "echoed an unrelated line: $out" ;; *) ok "unrelated log lines are not echoed" ;; esac

# ARM 5: FAIL-LOUD. A log that never appears is named, with rc 3, not silence.
absent="$(bash "$FOLLOW" "$TMP/never.log" 1 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && case "$absent" in *"opencode log never appeared"*) true ;; *) false ;; esac; then
    ok "a log that never appears is reported loudly (rc 3)"
else
    bad "absent log was not loud: rc=$rc out=$absent"
fi

# ARM 6: wiring. The prompted branch starts the follower BEFORE its exec,
# and the image installs and marks it executable.
branch="$(awk '/TILLANDSIAS_OPENCODE_PROMPT:-}" \]; then/{f=1} f{print} f&&/exec \/usr\/local\/bin\/harness-supervisor/{exit}' "$ENTRY")"
if grep -q 'opencode-tool-start-follower &' <<<"$branch" ; then
    ok "the prompted branch starts the follower before exec"
else
    bad "the prompted branch does not start the follower before exec"
fi
if grep -q '^COPY opencode-tool-start-follower.sh /usr/local/bin/opencode-tool-start-follower$' "$IMAGE" \
   && grep -q '/usr/local/bin/opencode-tool-start-follower \\' "$IMAGE"; then
    ok "the forge image installs the follower and marks it executable"
else
    bad "the forge image does not COPY and chmod the follower"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'ok:opencode-tool-start-follower:%d/%d\n' "$pass" "$total"
else
    printf 'refused:opencode-tool-start-follower:%d/%d\n' "$pass" "$total"
    exit 1
fi
