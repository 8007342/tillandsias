#!/usr/bin/env bash
# @trace order:1563-u2yx, spec:ci-release
#
# Fixture for scripts/lib-wsl-capture.sh (order 1563-u2yx). Runs on any Linux
# or MSYS host: a stub wsl.exe REOPENS its stderr target by path, which is the
# independent-offset write wsl.exe does on Windows (measured on yolanda
# 2026-10-08: `> f 2>&1` kept 25600 of 38000 bytes, 3/3 runs; `>>` the same).
# The stub prints what build.sh's preflight prints: skip notices on stdout,
# refusal blocks ending refused:preflight:<name> on stderr.
#
#   1. caller captures `> log 2>&1`: every refused:preflight:<name> line
#      survives, their count equals the summary's refused=N, no byte is lost,
#      and the capture path ran (the stub is a CHILD of the wrapper);
#   2. the exit code of wsl.exe is the wrapper's;
#   3. a PIPE caller keeps the exec path (the stub IS the wrapper's pid);
#   4. two DISTINCT files keep the exec path;
#   5. TERM to the wrapper on the capture path reaches wsl.exe, and nothing
#      survives it (an orphaned guest build would be a new bug);
#   6. stdin still reaches wsl.exe on the capture path;
#   7. with-wsl2-builder.sh reaches wsl.exe for the build only through the lib.
#
# PRE-FIX RESULT: FAILS — with a plain exec, arm 1 loses refusal lines.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=7
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

LIB="$ROOT/scripts/lib-wsl-capture.sh"
[ -f "$LIB" ] || { echo "fail:wsl-capture-fixture:0/$total (lib-wsl-capture.sh missing)"; exit 1; }
[ -r /proc/$$/fd/1 ] || { echo "skip:wsl-capture-fixture:no-proc-fd"; exit 0; }

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/wsl-capture.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# The stub: records its pid and parent, reopens stderr by path when it is a
# regular file (fresh offset 0, as wsl.exe does), then acts per $STUB_MODE.
cat > "$W/wsl.exe" <<'STUB'
#!/usr/bin/env bash
echo "$$ $PPID" > "$STUB_DIR/stub.pid"
t="$(readlink "/proc/$$/fd/2" 2>/dev/null)"
[ -n "$t" ] && [ -f "$t" ] && exec 2<>"$t"
case "${STUB_MODE:-preflight}" in
    preflight)
        n=0
        while [ "$n" -lt 40 ]; do
            echo "skip:preflight:guard-$n:deadline:183s — outlived the 180s front-door deadline; the gate still runs it"
            printf 'FAIL: arm 5: an unanswerable discipline question -> blocked:…:discipline-unanswered, rc 1\n  why: the guard guard-%s refused this tree\nrefused:preflight:guard-%s\n' "$n" "$n" >&2
            n=$((n + 1))
        done
        echo "refused:preflight:ran=0 refused=40 sum=40" >&2 ;;
    rc) exit 7 ;;
    sleep)
        trap 'echo got-term > "$STUB_DIR/stub.term"; exit 143' TERM
        echo started > "$STUB_DIR/stub.started"
        while :; do sleep 0.1; done ;;
    stdin) read -r line; echo "stdin:$line" ;;
esac
STUB
chmod +x "$W/wsl.exe"
export STUB_DIR="$W" TILLANDSIAS_WSL_EXE="$W/wsl.exe"

# The wrapper under test: a shell that records its own pid, then hands over.
cat > "$W/wrapper.sh" <<WRAP
echo \$\$ > "$W/wrapper.pid"
. "$LIB"
tillandsias_wsl_exec -d tillandsias-build -- bash -c true
WRAP
expected_bytes="$( STUB_MODE=preflight "$W/wsl.exe" 2>&1 | wc -c | tr -d ' ')"
# (the line above runs the stub into a pipe: no reopen, so it is the full text)

# 1 — the measured case.
STUB_MODE=preflight bash "$W/wrapper.sh" > "$W/log" 2>&1
log="$(cat "$W/log")"
named="$(grep -c '^refused:preflight:guard-[0-9]*$' <<<"$log")"
summary="$(grep -o 'refused=[0-9]*' <<<"$log" | tail -1)"
bytes="$(wc -c < "$W/log" | tr -d ' ')"
read -r spid sppid < "$W/stub.pid"; wpid="$(cat "$W/wrapper.pid")"
if [ "$named" -eq 40 ] && [ "$summary" = "refused=40" ] && [ "$bytes" = "$expected_bytes" ] \
   && [ "$sppid" = "$wpid" ]; then
    ok "arm 1: > log 2>&1 keeps all 40 refused:preflight:<name> lines = refused=40, $bytes bytes, via the capture path"
else
    bad "arm 1: named=$named summary=$summary bytes=$bytes/$expected_bytes stub-ppid=$sppid wrapper=$wpid"
fi

# 2 — the exit code.
STUB_MODE=rc bash "$W/wrapper.sh" > "$W/log2" 2>&1; rc=$?
[ "$rc" -eq 7 ] && ok "arm 2: wsl.exe's exit code (7) is the wrapper's" || bad "arm 2: rc=$rc"

# 3 — a pipe caller keeps exec.
out="$(STUB_MODE=preflight bash "$W/wrapper.sh" 2>&1 | cat)"
read -r spid sppid < "$W/stub.pid"; wpid="$(cat "$W/wrapper.pid")"
if [ "$spid" = "$wpid" ] && [ "$(grep -c '^refused:preflight:guard-[0-9]*$' <<<"$out")" -eq 40 ]; then
    ok "arm 3: a pipe caller keeps the exec path (stub pid = wrapper pid)"
else
    bad "arm 3: stub=$spid wrapper=$wpid"
fi

# 4 — two distinct files keep exec.
STUB_MODE=preflight bash "$W/wrapper.sh" > "$W/out4" 2> "$W/err4"
read -r spid sppid < "$W/stub.pid"; wpid="$(cat "$W/wrapper.pid")"
if [ "$spid" = "$wpid" ] && [ "$(grep -c '^refused:preflight:guard-[0-9]*$' "$W/err4")" -eq 40 ]; then
    ok "arm 4: distinct stdout/stderr files keep the exec path"
else
    bad "arm 4: stub=$spid wrapper=$wpid"
fi

# 5 — TERM to the wrapper reaches wsl.exe.
STUB_MODE=sleep bash "$W/wrapper.sh" > "$W/log5" 2>&1 &
bg=$!
i=0; while [ ! -f "$W/stub.started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
read -r spid sppid < "$W/stub.pid"
kill -TERM "$bg"
i=0; while kill -0 "$bg" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
wait "$bg" 2>/dev/null; rc5=$?
alive=0; kill -0 "$spid" 2>/dev/null && alive=1
if [ -f "$W/stub.term" ] && [ "$alive" -eq 0 ] && [ "$rc5" -eq 143 ]; then
    ok "arm 5: TERM to the wrapper reached wsl.exe (rc 143), nothing survived"
else
    kill -KILL "$spid" 2>/dev/null
    bad "arm 5: term-seen=$([ -f "$W/stub.term" ] && echo yes || echo no) stub-alive=$alive rc=$rc5"
fi

# 6 — stdin reaches wsl.exe on the capture path.
echo hello | STUB_MODE=stdin bash "$W/wrapper.sh" > "$W/log6" 2>&1
[ "$(cat "$W/log6")" = "stdin:hello" ] && ok "arm 6: stdin reaches wsl.exe on the capture path" \
    || bad "arm 6: [$(cat "$W/log6")]"

# 7 — wired: no build-path wsl.exe call bypasses the lib.
B="$ROOT/scripts/with-wsl2-builder.sh"
bypass="$(grep -nE '^[[:space:]]*(exec[[:space:]]+)?wsl\.exe[[:space:]]+-d "\$BUILD_DISTRO" -u root --cd' "$B")"
uses="$(grep -cE '^[[:space:]]*(tillandsias_wsl_exec|tillandsias_wsl_run) -d "\$BUILD_DISTRO" -u root --cd' "$B")"
if [ -z "$bypass" ] && [ "$uses" -eq 3 ] && grep -q 'lib-wsl-capture.sh' "$B"; then
    ok "arm 7: with-wsl2-builder.sh reaches wsl.exe for the build only through the lib (3 sites)"
else
    bad "arm 7: uses=$uses bypass=[$bypass]"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:wsl-capture-fixture:$pass/$total"
    exit 0
fi
echo "fail:wsl-capture-fixture:$pass/$total"
exit 1
