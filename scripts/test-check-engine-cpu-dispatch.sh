#!/usr/bin/env bash
# @trace order:861-n7f5, order:2199-luab
#
# test-check-engine-cpu-dispatch.sh — pin the 861-n7f5 grammar and the one
# verdict that matters: a BASELINE build on a VECTOR host must be refused, not
# quietly benchmarked.
#
# Hermetic: every arm uses a stubbed engine output (ENGINE_DISPATCH_SYSINFO_FILE,
# a file whose contents stand in for the engine's) and a stubbed host feature
# set (ENGINE_DISPATCH_HOST_FLAGS). No real engine binary, no model, no
# network, no capability matrix. The guard is the Lua port (2199-luab), run
# through the plan binary's script runner.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUA="$ROOT/scripts/lua/check-engine-cpu-dispatch.lua"
# 1401-x76w / 84f37ff24: resolve the plan binary from the CHECKOUT, not the caller's cwd,
# and absolutise it before any cd. An explicit TILLANDSIAS_PLAN_BIN keeps its meaning.
if [ -n "${TILLANDSIAS_PLAN_BIN:-}" ]; then
    PLAN="$TILLANDSIAS_PLAN_BIN"
else
    PLAN="$(cd "$ROOT" && _p="$(. scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" && case "$_p" in (/*) printf %s "$_p" ;; (*) printf %s/%s "$PWD" "${_p#./}" ;; esac)" || PLAN=""
fi
[ -n "$PLAN" ] || { echo "could-not-run:test-check-engine-cpu-dispatch:no-plan-binary"; exit 3; }
GUARD() { "$PLAN" script run "$LUA" -- "$@"; }
SCR="$(mktemp -d "${TMPDIR:-/tmp}/engine-dispatch.XXXXXX")" || exit 2
trap 'rm -rf "$SCR"' EXIT
fail=0
pass=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

# The real thing llama.cpp prints. Kept verbatim in shape so a future format
# change breaks this test rather than silently passing everything.
FEDORA_BASELINE='system_info: n_threads = 4 (n_threads_batch = 4) / 4 | CPU : LLAMAFILE = 1 | REPACK = 1 |'
OLLAMA_DISPATCHED='system_info: n_threads = 4 (n_threads_batch = 4) / 4 | CPU : LLAMAFILE = 1 | AVX = 1 | AVX2 = 1 | FMA = 1 | AVX_VNNI = 1 | REPACK = 1 |'
NO_TABLE='version: 6153 (b6153-3.fc44) built with gcc 15.2.1'

run() { # run <host-flags> <stub-stdout> ; echoes "<rc>|<verdict>"
    local out rc
    printf '%s' "$2" > "$SCR/sysinfo"
    out="$(ENGINE_DISPATCH_HOST_FLAGS="$1" \
           ENGINE_DISPATCH_SYSINFO_FILE="$SCR/sysinfo" \
           GUARD /nonexistent-engine 2>/dev/null)"
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

expect() { # expect <label> <want-rc> <want-verdict> <host-flags> <stub>
    local got want
    got="$(run "$4" "$5")"
    want="$2|$3"
    if [ "$got" = "$want" ]; then ok "$1"; else bad "$1 — want [$want] got [$got]"; fi
}

# 1. THE MEASURED INCIDENT. Fedora's baseline build on this host's real flags.
expect "baseline build on a vector host is refused" \
    1 "refused:engine-cpu-dispatch-baseline:avx,avx2,fma,avx_vnni" \
    "avx,avx2,fma,avx_vnni" "$FEDORA_BASELINE"

# 2. The build ollama actually loads: every advertised feature dispatched.
expect "fully dispatched build passes" \
    0 "ok:engine-cpu-dispatch:avx,avx2,fma,avx_vnni" \
    "avx,avx2,fma,avx_vnni" "$OLLAMA_DISPATCHED"

# 3. PARTIAL is still a refusal, and it names only what is missing. A build
#    with AVX2 but no AVX_VNNI on a VNNI host leaves measurable throughput on
#    the floor, and "mostly dispatched" is not a verdict.
expect "partially dispatched build names only the gap" \
    1 "refused:engine-cpu-dispatch-baseline:avx_vnni" \
    "avx,avx2,fma,avx_vnni" \
    'system_info: CPU : AVX = 1 | AVX2 = 1 | FMA = 1 | AVX_VNNI = 0 | REPACK = 1 |'

# 4. NEGATIVE CONTROL — the check must not manufacture a refusal. A baseline
#    build on a host that genuinely has no vector features is CORRECT, and a
#    check that refuses it would ban the only build such a host can run.
expect "baseline build on a baseline host passes" \
    0 "ok:engine-cpu-dispatch:none" \
    "sse2" "$FEDORA_BASELINE"

# 5. A build that dispatches MORE than the host advertises is not a refusal.
#    Runtime selection handles that; the check's question is one-directional.
expect "build ahead of the host's row is not refused" \
    0 "ok:engine-cpu-dispatch:avx,avx2,fma,avx_vnni" \
    "avx,avx2" "$OLLAMA_DISPATCHED"

# 6. UNREADABLE IS NOT PASSING (the order-531 shape). A version banner with no
#    dispatch table tells us nothing, and reporting nothing as ok is the whole
#    failure mode this project keeps re-learning.
expect "no dispatch table is unavailable, never ok" \
    2 "unavailable:no-dispatch-table" \
    "avx,avx2,fma,avx_vnni" "$NO_TABLE"

# 7. Silence is likewise not a pass.
expect "an engine that emits nothing is unavailable" \
    2 "unavailable:engine-emitted-nothing" \
    "avx,avx2,fma,avx_vnni" ""

# 8. Grammar: every verdict this suite produced matches the pinned regex.
grammar='^(ok:engine-cpu-dispatch:[a-z0-9_,-]+|refused:engine-cpu-dispatch-baseline:[a-z0-9_,-]+|unavailable:[a-z0-9-]+)$'
gfail=0
for stub in "$FEDORA_BASELINE" "$OLLAMA_DISPATCHED" "$NO_TABLE" ""; do
    v="$(run "avx,avx2,fma,avx_vnni" "$stub")"; v="${v#*|}"
    grep -qE <<<"$v" "$grammar" || { bad "grammar violated by [$v]"; gfail=1; }
done
[ "$gfail" = 0 ] && ok "every verdict matches the pinned grammar"

# 9. No engine argument at all is a usage error, not a silent pass.
out="$(GUARD 2>/dev/null)"; rc=$?
[ "$rc" = 2 ] && [ "$out" = "unavailable:no-engine-given" ] \
    && ok "missing engine argument is unavailable" \
    || bad "missing engine argument — want [2|unavailable:no-engine-given] got [$rc|$out]"

echo "test-check-engine-cpu-dispatch: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
