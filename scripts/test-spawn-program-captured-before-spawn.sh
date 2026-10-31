#!/usr/bin/env bash
# @trace spec:init-command
# @trace order:1928-s9ae
#
# litmus:spawn-failure-names-program step 3 asked "is the program name captured
# BEFORE the spawn" by comparing the FIRST `let program = command` with the
# FIRST `spawn_caller_owned_lifetime()` anywhere in main.rs. 5f8cce30d
# (1911-3dqo) added an unrelated caller-owned spawn earlier in the file, and the
# step went red while the property still held (v56.10.31.1 cut gate). The
# property is about ONE function: within the function that captures the
# program, the capture precedes that function's spawn.
#
# Arms:
#   1. the property: inside the enclosing fn of `let program = command`, a
#      spawn_caller_owned_lifetime() follows the capture and none precedes it.
#   2. the retired whole-file position check REFUSES on today's file, so this
#      fixture is not a no-op relabelling of it.
#   3. negative control: a copy with the capture moved after its spawn fails
#      the property check.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
F=crates/tillandsias-headless/src/main.rs
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok:   $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# property FILE -> prints ok:<p>:<s> or fail:<reason>
property() {
    awk '
        /^[[:space:]]*(pub(\([a-z]+\))? )?(async )?fn [A-Za-z0-9_]+/ { fnline = NR; seen_spawn = 0 }
        /spawn_caller_owned_lifetime\(\)/ { if (p && NR > p && !s && fnline == pfn) s = NR; if (!p) seen_spawn = 1 }
        /let program = command/ && !p { p = NR; pfn = fnline; pre = seen_spawn }
        END {
            if (!p)  { print "fail:no-capture"; exit }
            if (pre) { print "fail:spawn-before-capture-in-fn"; exit }
            if (!s)  { print "fail:no-spawn-after-capture-in-fn"; exit }
            print "ok:" p ":" s
        }' "$1"
}

v="$(property "$F")"
case "$v" in
    ok:*) ok "within its function the program is captured (line ${v#ok:}) before the spawn" ;;
    *)    bad "property check on $F: $v" ;;
esac

# The retired check, verbatim in shape.
p=$(grep -n 'let program = command' "$F" | head -1 | cut -d: -f1)
s=$(grep -n 'spawn_caller_owned_lifetime()' "$F" | head -1 | cut -d: -f1)
if [ -n "$p" ] && [ -n "$s" ] && [ "$p" -lt "$s" ]; then
    bad "the retired whole-file position check passes on today's file — arm 2 has no subject (p=$p s=$s)"
else
    ok "the retired whole-file position check refuses on today's file (first capture $p, first spawn $s) though the property holds"
fi

base="${CARGO_TARGET_DIR:-target}"; case "$base" in /*) ;; *) base="$PWD/$base" ;; esac
mkdir -p "$base/plan-scratch"
M="$(mktemp "$base/plan-scratch/spawn-capture-mutant.XXXXXX")" || { echo "FAIL: no scratch"; exit 1; }
trap 'rm -f "$M"' EXIT
# Mutant: drop the capture line and re-insert it after the spawn line it guards.
pl=$(grep -n 'let program = command' "$F" | head -1 | cut -d: -f1)
sl=$(awk -v p="$pl" 'NR > p && /spawn_caller_owned_lifetime\(\)/ { print NR; exit }' "$F")
awk -v p="$pl" -v s="$sl" 'NR == p { held = $0; next } { print } NR == s { print held }' "$F" > "$M"
mv_v="$(property "$M")"
case "$mv_v" in
    fail:*) ok "negative control: the capture moved after its spawn is refused ($mv_v)" ;;
    *)      bad "negative control: a capture after its spawn still passed ($mv_v)" ;;
esac

[ "$fail" -eq 0 ] && { echo "ok: program captured before spawn ($pass/$pass, 1928-s9ae)"; exit 0; }
echo "FAIL: spawn-program-captured-before-spawn $pass/$((pass+fail))"; exit 1
