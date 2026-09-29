#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_ROOT="${CARGO_TARGET_DIR:-$ROOT/target}"
PLAN_BIN="${TILLANDSIAS_PLAN_BIN:-$TARGET_ROOT/release/tillandsias-plan}"
if [ ! -x "$PLAN_BIN" ]; then
    echo "blocked:test-plan-run-verb:no-runnable-plan-binary:$PLAN_BIN" >&2
    exit 2
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tillandsias-plan-run-verb.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ok() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

start=$SECONDS
set +e
timeout_out="$(cd "$ROOT" && "$PLAN_BIN" run --timeout 1s -- sleep 5 2>&1)"
timeout_rc=$?
set -e
elapsed=$((SECONDS - start))
[ "$timeout_rc" -eq 124 ] || fail "--timeout exits 124 (got $timeout_rc): $timeout_out"
[ "$elapsed" -lt 2 ] || fail "--timeout 1s returned in ${elapsed}s"
grep -Eq '^status=timed_out after_ms=[0-9]+$' <<<"$timeout_out" \
    || fail "timeout diagnostic missing: $timeout_out"
ok "timeout deadline returns 124 promptly with measured status"

"$PLAN_BIN" run -- printf '%s\n' 'a b*' > "$WORK/argv.txt" \
    || fail "argv probe did not run"
grep -Fxq 'a b*' "$WORK/argv.txt" \
    || fail "argv element with spaces and glob characters was not preserved"
ok "argv remains tokenized; spaces and glob characters are not reinterpreted"

if [ "$(uname -s)" = Linux ] || [ "$(uname -s)" = Darwin ]; then
    caller_session="$(ps -o sess= -p "$$" | tr -d '[:space:]')"
    child_record="$WORK/detached.txt"
    cat > "$WORK/detached-child.sh" <<'CHILD'
printf '%s %s\n' "$$" "$(ps -o sess= -p $$ | tr -d '[:space:]')" > "$1"
sleep 3
CHILD
    start=$SECONDS
    "$PLAN_BIN" run --detach -- sh "$WORK/detached-child.sh" "$child_record" \
        2>"$WORK/detach.err" \
        || fail "detached run refused: $(<"$WORK/detach.err")"
    elapsed=$((SECONDS - start))
    [ "$elapsed" -lt 1 ] || fail "detach returned in ${elapsed}s"
    for _ in {1..40}; do [ -s "$child_record" ] && break; sleep 0.025; done
    [ -s "$child_record" ] || fail "detached child did not start"
    read -r child_pid child_session < "$child_record"
    [ "$child_session" != "$caller_session" ] \
        || fail "detached session equals caller session ($caller_session)"
    sleep 3.2
    kill -0 "$child_pid" 2>/dev/null && fail "detached child did not finish" || true
    ok "detach returns promptly, enters a distinct session, and survives its caller"
elif [[ "${OS:-}" == Windows_NT ]]; then
    marker="$WORK/detached-marker"
    cat > "$WORK/detached-child.ps1" <<'CHILD'
Start-Sleep -Seconds 2
Set-Content -NoNewline -Path $args[0] -Value 'alive'
CHILD
    "$PLAN_BIN" run --detach -- powershell.exe -NoProfile -File "$WORK/detached-child.ps1" "$marker" \
        2>"$WORK/detach.err" || fail "detached Windows run refused: $(<"$WORK/detach.err")"
    for _ in {1..60}; do [ -s "$marker" ] && break; sleep 0.1; done
    [ -s "$marker" ] || fail "detached Windows child did not survive its caller"
    ok "detached Windows child survives caller exit"
else
    echo "skip:detach-unsupported-host:$(uname -s)" >&2
fi

lock="$WORK/shared.lock"
out="$WORK/critical-section.txt"
cat > "$WORK/lock-child.sh" <<'CHILD'
printf 'begin:%s\n' "$1" >> "$2"
sleep 0.002
printf 'end:%s\n' "$1" >> "$2"
CHILD
cat > "$WORK/lock-holder.sh" <<'CHILD'
printf 'held\n' > "$1"
sleep 2
CHILD
for i in {1..100}; do
    (
        "$PLAN_BIN" run --lock "$lock" -- sh "$WORK/lock-child.sh" "$i" "$out"
    ) &
done
wait
[ "$(wc -l < "$out" | tr -d '[:space:]')" = 200 ] || fail "expected 200 critical-section lines"
awk '
    NR % 2 == 1 { if ($0 !~ /^begin:[0-9]+$/) exit 1; id = substr($0, 7); next }
    { if ($0 != "end:" id) exit 1 }
    END { if (NR != 200) exit 1 }
' "$out" || fail "locked critical sections interleaved"
ok "100 concurrent advisory-lock runs serialize complete critical sections"

held="$WORK/held.marker"
"$PLAN_BIN" run --lock "$lock" -- sh "$WORK/lock-holder.sh" "$held" &
holder_pid=$!
for _ in {1..80}; do [ -s "$held" ] && break; sleep 0.025; done
[ -s "$held" ] || fail "lock holder never entered its critical section"
set +e
wait_out="$("$PLAN_BIN" run --lock "$lock" --lock-wait 100ms -- printf must-not-run 2>&1)"
wait_rc=$?
set -e
[ "$wait_rc" -eq 75 ] || fail "lock wait should exit 75 (got $wait_rc): $wait_out"
grep -Fq 'status=lock_timed_out' <<<"$wait_out" \
    || fail "lock wait timeout was not named: $wait_out"
wait "$holder_pid"
ok "bounded lock acquisition returns 75 without spawning on expiry"

printf 'ok:plan-run-verb:5\n'
