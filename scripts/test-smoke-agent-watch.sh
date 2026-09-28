#!/usr/bin/env bash
# @trace order:1275-ngrc
#
# test-smoke-agent-watch.sh — the smoke forge lane detects the agent-dead-
# process-idling state from the AGENT'S log, and never from a clock.
#
#   1  classify: the pirria 2026-09-19 shape (a retried rate limit, then
#      AI_RetryError "Failed after 3 attempts", then only hourly
#      `cleanup prune=7.days` ticks) is state:agent-error-idle naming the
#      RetryError line
#   2  NEGATIVE CONTROLS for classify: a working log, an error FOLLOWED by agent
#      activity (the retry worked), and a lone retrying AI_APICallError are all
#      state:working; an empty log is state:no-log
#   3  watch --log: the pirria shape yields, within grace + poll, exit 3,
#      04-agent-watch.txt carrying refused:smoke-forge-lane:agent-dead-process-
#      idling and the error line, and 04-opencode-agent.log copied host-side
#   4  NEGATIVE CONTROL for watch, the row's own: a log with an OLD terminal
#      error that keeps getting agent activity is never killed, however long
#      the watch runs (it is still running when stopped)
#   5  watch --container through a fake podman: the newest log is read with
#      two argv calls (no shell string) and the container is STOPPED on the
#      verdict, which is how the lane returns and §4 records its exit
#
# Pre-fix: FAILS at arm 1 (no scripts/smoke-agent-watch.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/smoke-agent-watch.XXXXXX")"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }
S="$ROOT/scripts/smoke-agent-watch.sh"
[ -x "$S" ] || { bad "arm 1: $S does not exist"; echo "FAIL: smoke-agent-watch 0/1 (1275-ngrc)"; exit 1; }

RETRY='ERROR 2026-09-19T17:19:38 +2ms service=session.prompt error=AI_RetryError: Failed after 3 attempts. Last error: Rate limit exceeded. stream error'
cat >"$W/pirria.log" <<EOF
INFO  2026-09-19T17:19:20 +0ms service=session id=ses_1 created
INFO  2026-09-19T17:19:30 +5ms service=session.prompt step=1 tool=bash
ERROR 2026-09-19T17:19:36 +3ms service=session.prompt error=AI_APICallError: Rate limit exceeded. Please try again later. stream error
$RETRY
INFO  2026-09-19T17:20:00 +0ms service=storage cleanup prune=7.days
INFO  2026-09-19T18:20:00 +0ms service=storage cleanup prune=7.days
INFO  2026-09-19T19:20:00 +0ms service=storage cleanup prune=7.days
EOF
printf 'INFO  2026-09-28T10:00:00 +0ms service=session.prompt step=1 tool=read\nINFO  2026-09-28T10:00:05 +1ms service=session.prompt step=2 tool=bash\n' >"$W/working.log"
{ cat "$W/pirria.log"; echo 'INFO  2026-09-19T19:21:00 +4ms service=session.prompt step=2 tool=edit'; } >"$W/recovered.log"
printf 'INFO  2026-09-28T10:00:00 +0ms service=session.prompt step=1\nERROR 2026-09-28T10:00:01 +3ms service=session.prompt error=AI_APICallError: Rate limit exceeded. stream error\n' >"$W/retrying.log"
: >"$W/empty.log"

# ── 1 ───────────────────────────────────────────────────────────────────────
out="$(bash "$S" classify "$W/pirria.log")"
if [ "$out" = "$(printf 'state:agent-error-idle\t%s' "$RETRY")" ]; then
    ok "arm 1: the pirria shape is state:agent-error-idle naming the AI_RetryError line (housekeeping ticks ignored)"
else
    bad "arm 1: [$out]"
fi

# ── 2 ───────────────────────────────────────────────────────────────────────
r2="$(bash "$S" classify "$W/working.log")|$(bash "$S" classify "$W/recovered.log")|$(bash "$S" classify "$W/retrying.log")|$(bash "$S" classify "$W/empty.log")"
if [ "$r2" = "state:working|state:working|state:working|state:no-log" ]; then
    ok "arm 2: working, error-then-activity and a lone retrying APICallError are state:working; an empty log is state:no-log"
else
    bad "arm 2: [$r2]"
fi

# ── 3 ───────────────────────────────────────────────────────────────────────
t0="$(date +%s)"
timeout 30 bash "$S" watch --log "$W/pirria.log" --grace 2 --poll 1 --out "$W/out3" 2>/dev/null
rc=$?
dt=$(($(date +%s) - t0))
v="$W/out3/04-agent-watch.txt"
if [ "$rc" = 3 ] && [ "$dt" -le 10 ] && grep -qx 'refused:smoke-forge-lane:agent-dead-process-idling' "$v" 2>/dev/null &&
    grep -qF "error: $RETRY" "$v" && cmp -s "$W/pirria.log" "$W/out3/04-opencode-agent.log"; then
    ok "arm 3: watch issues the named verdict in ${dt}s (grace 2s), naming the error, with the agent log copied host-side"
else
    bad "arm 3: rc=$rc dt=${dt}s [$(cat "$v" 2>/dev/null)]"
fi

# ── 4: the row's negative control ───────────────────────────────────────────
cp "$W/pirria.log" "$W/live.log"
( i=0; while [ "$i" -lt 12 ]; do echo "INFO  2026-09-19T19:3$i:00 +1ms service=session.prompt step=$i tool=bash" >>"$W/live.log"; i=$((i + 1)); sleep 0.5; done ) &
writer=$!
bash "$S" watch --log "$W/live.log" --grace 2 --poll 1 --out "$W/out4" 2>/dev/null &
watcher=$!
sleep 6
if kill -0 "$watcher" 2>/dev/null && [ ! -e "$W/out4/04-agent-watch.txt" ]; then
    ok "arm 4: a lane whose agent keeps working after an old terminal error is NOT killed (still watching after 6s, grace 2s)"
else
    bad "arm 4: the watcher ended or issued a verdict on a working agent [$(cat "$W/out4/04-agent-watch.txt" 2>/dev/null)]"
fi
kill "$watcher" "$writer" 2>/dev/null
wait "$watcher" "$writer" 2>/dev/null

# ── 5 ───────────────────────────────────────────────────────────────────────
mkdir -p "$W/bin"
cat >"$W/bin/podman" <<EOF
#!/bin/sh
echo "\$*" >> "$W/podman-calls"
case "\$1 \$3" in
  "exec ls") printf 'opencode-2026-09-19T171900.log\nopencode-2026-09-18T090000.log\n' ;;
  "exec cat") cat "$W/pirria.log" ;;
esac
exit 0
EOF
chmod +x "$W/bin/podman"
PATH="$W/bin:$PATH" timeout 30 bash "$S" watch --container tillandsias-x-forge --grace 1 --poll 1 --out "$W/out5" 2>/dev/null
rc=$?
calls="$(cat "$W/podman-calls" 2>/dev/null)"
if [ "$rc" = 3 ] && grep -qx 'exec tillandsias-x-forge ls -t /home/forge/.local/share/opencode/log' <<<"$calls" &&
    grep -qx 'exec tillandsias-x-forge cat /home/forge/.local/share/opencode/log/opencode-2026-09-19T171900.log' <<<"$calls" &&
    grep -qx 'stop tillandsias-x-forge' <<<"$calls" && ! grep -q 'sh -c' <<<"$calls"; then
    ok "arm 5: the container's NEWEST log is read by two argv calls and the forge container is stopped on the verdict"
else
    bad "arm 5: rc=$rc calls=[$calls]"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: smoke-agent-watch $pass/$total (1275-ngrc)"
    exit 0
fi
echo "FAIL: smoke-agent-watch $pass/$total (1275-ngrc)"
exit 1
