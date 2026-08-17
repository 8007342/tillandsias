#!/usr/bin/env bash
# test-squid-supervisor.sh — hermetic fixtures for images/proxy/
# squid-supervisor.sh (order 767-es4w). No podman, no network, no squid:
# every scenario runs the real script on this host with a throwaway state dir.
#
# The property that matters most is scenarios 5 and 3 read together. They fire
# the SAME signal (SIGSEGV) at the SAME supervisor and demand DIFFERENT
# verdicts, because the only thing that differs is whether the supervisor was
# asked to stop first:
#
#   3. unsolicited SIGSEGV -> fail:proxy-crashed:...:action=restart, counted,
#      child relaunched;
#   5. SIGSEGV after a forwarded TERM -> note:proxy-exit-teardown-crash:...,
#      exit code normalised to 0, NOT counted as a crash, NOT restarted.
#
# That pair is the whole reason this script exists: on this host an idle squid
# 6.9 AND an idle squid 6.12 both segfault inside exit() after logging
# "Exiting normally", so without the discrimination every `podman stop` would
# look like a crash — and for two days in August 2026 a genuinely dead proxy
# looked like a stop. Each is the other's mutation control: break the
# discrimination and exactly one of the two goes red.
#
# Also pinned: silent happy path, ordinary-failure passthrough, ordered TERM
# shutdown staying byte-silent, the flap cap giving up with a TRUTHFUL nonzero
# exit rather than spinning, usage refusal, and image+entrypoint wiring with a
# stripped-copy negative control (634-39ik: a pin without falsifiability is a
# tautology).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUP="$ROOT/images/proxy/squid-supervisor.sh"
fail=0

T="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$T'" EXIT

# 1. clean control — the happy path must be byte-identical to no supervisor.
out="$(TILLANDSIAS_PROXY_CRASH_STATE_DIR="$T/s1" bash "$SUP" squid true 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -d "$T/s1" ]; then
    echo "ok: clean exit passes through silently (rc=0, no output, no state dir)"
else
    echo "FIXTURE-FAIL: clean control rc=$rc out='$out'"; fail=1
fi

# 2. ordinary failure passthrough — squid's own FATAL config refusals exit
#    with a small code and must NOT be dressed up as a crash or restarted.
out="$(TILLANDSIAS_PROXY_CRASH_STATE_DIR="$T/s2" bash "$SUP" squid bash -c 'exit 3' 2>&1)"
rc=$?
if [ "$rc" -eq 3 ] && [ -z "$out" ]; then
    echo "ok: ordinary failure passes through untouched (rc=3, silent, no restart)"
else
    echo "FIXTURE-FAIL: ordinary failure rc=$rc out='$out'"; fail=1
fi

# 3. REAL crash: unsolicited SIGSEGV -> loud counted verdict on both streams,
#    evidence, and a bounded restart (child runs twice, then exits clean).
marker="$T/launches3"
: > "$marker"
o3="$T/s3.out"; e3="$T/s3.err"
TILLANDSIAS_PROXY_CRASH_STATE_DIR="$T/s3" TILLANDSIAS_PROXY_BACKOFF_MAX=1 \
    bash "$SUP" squid bash -c "echo x >> '$marker'; if [ \$(wc -l < '$marker') -ge 2 ]; then exit 0; fi; kill -SEGV \$\$" \
    >"$o3" 2>"$e3"
rc=$?
launches3="$(wc -l < "$marker" | tr -d ' ')"
v3='fail:proxy-crashed:service=squid:signal=11:rc=139:crashes=1:recent=1:window=300:action=restart:backoff=1'
if [ "$rc" -eq 0 ] && grep -qxF "$v3" "$o3" && grep -qxF "$v3" "$e3" \
   && [ "$launches3" = "2" ] \
   && [ "$(cat "$T/s3/crash-count" 2>/dev/null)" = "1" ] \
   && [ "$(cat "$T/s3/exit-teardown-count" 2>/dev/null)" = "0" ] \
   && grep -q '^kind: crash$' "$T/s3/last-event" 2>/dev/null; then
    echo "ok: unsolicited SIGSEGV -> counted crash verdict on both streams, evidence, bounded restart, recovery rc=0"
else
    echo "FIXTURE-FAIL: real-crash scenario rc=$rc launches=$launches3 count=$(cat "$T/s3/crash-count" 2>/dev/null)"
    sed -n '1,3p' "$o3" 2>/dev/null; fail=1
fi

# 4. flap cap: a child that always crashes must NOT spin forever — after
#    RESTART_MAX crashes in the window the supervisor gives up LOUDLY and
#    exits with the child's truthful rc, so the container really dies.
marker4="$T/launches4"
: > "$marker4"
o4="$T/s4.out"
TILLANDSIAS_PROXY_CRASH_STATE_DIR="$T/s4" TILLANDSIAS_PROXY_RESTART_MAX=2 \
    TILLANDSIAS_PROXY_BACKOFF_MAX=1 \
    bash "$SUP" squid bash -c "echo x >> '$marker4'; kill -SEGV \$\$" >"$o4" 2>&1
rc=$?
launches4="$(wc -l < "$marker4" | tr -d ' ')"
if [ "$rc" -eq 139 ] && [ "$launches4" = "3" ] \
   && grep -q 'fail:proxy-crashed:service=squid:signal=11:rc=139:crashes=3:recent=3:window=300:action=giveup' "$o4" \
   && grep -q '^kind: giveup$' "$T/s4/last-event" 2>/dev/null; then
    echo "ok: flap cap honoured — 3 launches, giveup verdict, truthful rc=139 (container dies, lane fails loud)"
else
    echo "FIXTURE-FAIL: flap-cap scenario rc=$rc launches=$launches4"
    sed -n '1,6p' "$o4" 2>/dev/null; fail=1
fi

# 5. THE SQUID CASE and scenario 3's mutation control: the supervisor forwards
#    TERM, the child dies of SIGSEGV on the way out (squid's exit-time
#    Store::Controller teardown). Same signal as scenario 3, different
#    provenance: named + counted separately, NOT restarted, rc normalised to 0.
o5="$T/s5.out"; e5="$T/s5.err"
m5="$T/launches5"
: > "$m5"
TILLANDSIAS_PROXY_CRASH_STATE_DIR="$T/s5" \
    bash "$SUP" squid bash -c "echo x >> '$m5'; trap 'kill -SEGV \$\$' TERM; while :; do sleep 0.2; done" \
    >"$o5" 2>"$e5" &
sup5=$!
sleep 1
kill -TERM "$sup5" 2>/dev/null
# BOUNDED. Losing the discrimination does not merely mislabel this event — it
# turns an ordered shutdown into an endless restart loop, because the
# supervisor keeps resurrecting a service someone asked it to stop. An
# unbounded `wait` here would hang the fixture instead of failing it, so the
# deadline is part of the assertion.
w5=0
while kill -0 "$sup5" 2>/dev/null && [ "$w5" -lt 100 ]; do
    sleep 0.1; w5=$((w5 + 1))
done
if kill -0 "$sup5" 2>/dev/null; then
    echo "FIXTURE-FAIL: teardown scenario — supervisor still alive 10s after TERM (ordered shutdown became a restart loop)"
    pkill -P "$sup5" 2>/dev/null
    kill -KILL "$sup5" 2>/dev/null
    fail=1
fi
wait "$sup5" 2>/dev/null
rc=$?
launches5="$(wc -l < "$m5" | tr -d ' ')"
v5='note:proxy-exit-teardown-crash:service=squid:signal=11:rc=139:teardowns=1:action=normalised-to-0'
if [ "$rc" -eq 0 ] && grep -qxF "$v5" "$o5" && grep -qxF "$v5" "$e5" \
   && [ "$launches5" = "1" ] \
   && ! grep -q 'fail:proxy-crashed' "$o5" \
   && [ "$(cat "$T/s5/exit-teardown-count" 2>/dev/null)" = "1" ] \
   && [ "$(cat "$T/s5/crash-count" 2>/dev/null)" = "0" ]; then
    echo "ok: ordered shutdown + exit-time SIGSEGV -> named teardown note, rc normalised to 0, NOT restarted, NOT counted as a crash"
else
    echo "FIXTURE-FAIL: teardown scenario rc=$rc launches=$launches5 teardowns=$(cat "$T/s5/exit-teardown-count" 2>/dev/null) crashes=$(cat "$T/s5/crash-count" 2>/dev/null)"
    sed -n '1,3p' "$o5" 2>/dev/null; fail=1
fi

# 6. plain ordered shutdown (child dies OF the forwarded TERM) stays silent —
#    the ordinary `podman stop` must emit nothing at all.
o6="$T/s6.out"
TILLANDSIAS_PROXY_CRASH_STATE_DIR="$T/s6" bash "$SUP" squid sleep 30 >"$o6" 2>&1 &
sup6=$!
sleep 0.5
kill -TERM "$sup6" 2>/dev/null
waited=0
while kill -0 "$sup6" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1; waited=$((waited + 1))
done
if ! kill -0 "$sup6" 2>/dev/null && [ ! -s "$o6" ] && [ ! -d "$T/s6" ]; then
    echo "ok: plain ordered shutdown emits NO verdict and writes no state"
else
    echo "FIXTURE-FAIL: ordered-shutdown scenario out='$(cat "$o6" 2>/dev/null)'"
    kill -KILL "$sup6" 2>/dev/null; fail=1
fi
wait "$sup6" 2>/dev/null || true

# 7. usage refusal
bash "$SUP" only-one-arg >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    echo "ok: missing command refuses with rc=2"
else
    echo "FIXTURE-FAIL: usage refusal rc=$rc"; fail=1
fi

# 8. image + entrypoint wiring, WITH a negative control proving the matcher
#    can fail (634-39ik).
entry="$ROOT/images/proxy/entrypoint.sh"
cf="$ROOT/images/proxy/Containerfile"
wired="$(grep -cF 'exec /usr/local/bin/squid-supervisor squid squid -N' "$entry")"
copied="$(grep -cF 'squid-supervisor.sh' "$cf")"
chmodded="$(grep -cF '/usr/local/bin/squid-supervisor' "$cf")"
stripped="$T/entry-stripped.sh"
grep -vF 'squid-supervisor' "$entry" > "$stripped"
neg="$(grep -cF 'exec /usr/local/bin/squid-supervisor squid squid -N' "$stripped")"
if [ "$wired" = "1" ] && [ "$copied" -ge 1 ] && [ "$chmodded" -ge 1 ] && [ "$neg" = "0" ]; then
    echo "ok: wiring — entrypoint execs the supervisor, image COPY+chmod present; negative control red on a stripped copy"
else
    echo "FIXTURE-FAIL: wiring wired=$wired copied=$copied chmodded=$chmodded neg=$neg"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "ok: all squid-supervisor scenarios passed"
    exit 0
fi
echo "fail: squid-supervisor fixture scenarios failed"
exit 1
