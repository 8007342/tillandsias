#!/usr/bin/env bash
# test-lua-determinism.sh — one Lua script, one byte stream, on any host.
# @trace order:1384-bp6t, order:1254-fdsu (the locale class)
#
# PRE-FIX RESULT: FAILS. Measured on yoga 2026-09-26 with the trunk plan binary
# (0.1.0+f707748ff4a9460e): three processes encoding the same 12-key table
# printed 206 bytes each with THREE different checksums
# ({"zeta":6,"gamma":3,…} / {"lambda":11,"alpha":1,…} / {"alpha":1,"zeta":6,…}),
# because Lua 5.4 seeds string hashing per process and pairs/next walk the hash;
# and under LC_ALL=fr_FR.UTF-8 one os.setlocale("") flipped %.2f from 3.50 to
# 3,50 and made tonumber("3,5") parse.
#
# Arms: (1) three processes of scripts/fixtures/determinism.lua in the
# CACHEABLE class give identical, NON-EMPTY output (an empty output on all three
# would compare equal — the premise refuses it); (2) os.setlocale is nil in
# both classes; (3) under an installed comma-radix locale %.2f is 3.50 and
# tonumber("3,5") is nil (a named skip if none is installed); (4) next is withheld (reading it
# raises an error naming table.is_empty, 1395-xjty) in
# both classes and table.keys returns numbers ascending, then strings.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN_BIN="$(resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
[ -n "$PLAN_BIN" ] || { echo "could-not-run:no-plan-binary"; exit 3; }
pass=0; fail=0; skip=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
skp() { skip=$((skip + 1)); echo "skip $1"; }
lua_c() { "$PLAN_BIN" lua --class cacheable "$@" 2>&1; }
lua_o() { "$PLAN_BIN" lua "$@" 2>&1; }

# ── 1: three processes, one byte stream ───────────────────────────────────
o1="$(lua_c scripts/fixtures/determinism.lua)"; o2="$(lua_c scripts/fixtures/determinism.lua)"; o3="$(lua_c scripts/fixtures/determinism.lua)"
# premise: real output (an empty or error output on all three would compare
# equal); then identity across processes; then byte order — three separate
# claims, so a failure names which one broke.
case "$o1" in
    '{"'*'}'*) prem=1 ;;
    *) prem=0 ;;
esac
if [ "$prem" != 1 ]; then
    bad "premise: the fixture did not print an encoded object (got: $(printf '%.60s' "$o1"))"
else
    if [ "$o1" = "$o2" ] && [ "$o2" = "$o3" ]; then
        ok "three processes print the same $(printf '%s' "$o1" | wc -c | tr -d ' ') bytes"
    else
        bad "the output differs across processes: $(printf '%.30s' "$o1") | $(printf '%.30s' "$o2") | $(printf '%.30s' "$o3")"
    fi
    case "$o1" in
        '{"alpha":1,"beta":2,"delta":4,"eps":5,"eta":7,"gamma":3,"iota":9,"kappa":10,"lambda":11,"mu":12,"theta":8,"zeta":6}'*'alpha=1,beta=2,delta=4,'*) ok "keys in byte order, in json.encode and in pairs" ;;
        *) bad "keys not in byte order: $(printf '%.60s' "$o1")" ;;
    esac
fi

# ── 1b: fs.list (OBSERVING only; unstable, never memoized) is still one
#       byte stream for a given tree (1395-xjty, operator ruling on 1395-ue3i)
l1="$(lua_o -e 'return table.concat(fs.list("scripts/fixtures"), ",")')"
l2="$(lua_o -e 'return table.concat(fs.list("scripts/fixtures"), ",")')"
l3="$(lua_o -e 'return table.concat(fs.list("scripts/fixtures"), ",")')"
case "$l1" in
    *determinism.lua*)
        if [ "$l1" = "$l2" ] && [ "$l2" = "$l3" ]; then ok "fs.list prints the same bytes in three processes"; else bad "fs.list differs across processes: $l1 | $l2 | $l3"; fi ;;
    *) bad "premise: fs.list did not list scripts/fixtures (got: $(printf '%.60s' "$l1"))" ;;
esac

# ── 2 and 4: withheld names, sorted keys ──────────────────────────────────
# `next` is withheld; since 1395-xjty READING it raises an error naming
# table.is_empty (the replacement an author needs), so the arm asserts the
# named error rather than a nil.
v="$(lua_o -e 'local ok, e = pcall(function() return next end); local nx = (not ok and tostring(e):find("table.is_empty", 1, true)) and "next-named" or ("next:" .. tostring(ok) .. ":" .. tostring(e)); return tostring(os.setlocale), nx, table.concat(table.keys({b=1,a=2,[3]=0,[1]=0}), ","), tostring(table.is_empty({})) .. tostring(table.is_empty({a=1}))' | tr '\n' ' ')"
[ "$v" = "nil next-named 1,3,a,b truefalse " ] && ok "observing: os.setlocale nil, next withheld with a named error, table.keys sorted, table.is_empty" || bad "observing: $v"
v="$(lua_c -e 'local ok, e = pcall(function() return next end); local nx = (not ok and tostring(e):find("table.is_empty", 1, true)) and "next-named" or ("next:" .. tostring(ok) .. ":" .. tostring(e)); return tostring(os), nx, table.concat(table.keys({b=1,a=2,[3]=0,[1]=0}), ","), tostring(table.is_empty({})) .. tostring(table.is_empty({a=1}))' | tr '\n' ' ')"
[ "$v" = "nil next-named 1,3,a,b truefalse " ] && ok "cacheable: os (so os.setlocale) nil, next withheld with a named error, table.keys sorted, table.is_empty" || bad "cacheable: $v"

# ── 3: a comma-radix locale cannot reach Lua's number formatting ──────────
loc=""; installed="
$(locale -a 2>/dev/null)
"
for c in fr_FR.UTF-8 fr_FR.utf8 br_FR.UTF-8 br_FR.utf8 de_DE.UTF-8 de_DE.utf8; do
    case "$installed" in *"
$c
"*) loc="$c"; break ;; esac
done
if [ -z "$loc" ]; then
    skp "no comma-radix locale installed (fr_FR/br_FR/de_DE): the locale arm did not run"
else
    # The ARM ATTEMPTS THE ATTACK: without a script calling os.setlocale the
    # Rust binary never leaves "C", so a bare format would read 3.50 pre-fix
    # too and this arm could not fail. Pre-fix, the call below flips it to 3,50.
    v="$(LC_ALL="$loc" "$PLAN_BIN" lua -e 'local f = type(os) == "table" and os.setlocale; if f then f("") end; return string.format("%.2f", 3.5), tostring(tonumber("3,5"))' 2>&1 | tr '\n' ' ')"
    [ "$v" = "3.50 nil " ] && ok "under LC_ALL=$loc: %.2f is 3.50 and tonumber(\"3,5\") is nil" || bad "under LC_ALL=$loc: $v"
fi

total=$((pass + fail))
if [ "$fail" = 0 ]; then echo "ok:lua-determinism:$pass arms (skipped=$skip)"; exit 0; fi
echo "FAIL:lua-determinism:$pass/$total (skipped=$skip)"; exit 1
