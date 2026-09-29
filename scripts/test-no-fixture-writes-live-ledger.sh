#!/usr/bin/env bash
# @trace order:1320-44rs
#
# test-no-fixture-writes-live-ledger.sh — the checker flags a fixture that
# writes the checkout's OWN plan/index.d or plan/loop_status.d, and accepts the
# scaffold idioms.
#
#   1  the shapes it must FLAG: `"$ROOT/$PEND"` with PEND a relative ledger path
#      (the pre-fix pending-capability fixture), a relative write after
#      `cd "$ROOT"`, the `ROOT="$(cd ...)"; cd "$ROOT"` one-liner (the pre-fix
#      archiver-memo fixture), `"$REPO_ROOT/plan/loop_status.d/x.md"`, a `tee`
#   2  the idioms it must ACCEPT: `"$W/plan/index.d/x.yaml"`, a relative write
#      after `cd "$W/wc"` or `cd "$wt"`, a same-line subshell
#      `( cd "$S" && ... > plan/index.d/a.yaml )`, a read (`cat plan/index.d/x`)
#   3  the real corpus is clean: ok:fixtures-write-scaffolds-only
#
# Pre-fix: FAILS at arm 1 (no checker).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="$ROOT/scripts/check-no-fixture-writes-live-ledger.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/no-fixture-live-ledger.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }
[ -x "$C" ] || { bad "arm 1: $C does not exist"; echo "FAIL: no-fixture-writes-live-ledger 0/1 (1320-44rs)"; exit 1; }

flags() { # flags <name> <body> -> 0 when the checker flags it
    # The samples spell the ledger dirs as __LED__ / __LSD__ so THIS file is not
    # itself a live write in the corpus scan (arm 3); they are expanded here.
    printf '%s\n' "$2" | sed -e 's#__LED__#plan/index.d#g' -e 's#__LSD__#plan/loop_status.d#g' >"$W/$1.sh"
    bash "$C" "$W/$1.sh" >"$W/$1.out" 2>&1
    [ $? -ne 0 ] && grep -q "violation:fixture-writes-live-ledger:$W/$1.sh:" "$W/$1.out"
}

# ── 1 ───────────────────────────────────────────────────────────────────────
missed=""
flags a 'ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PEND="__LED__/20990101t000000z-probe.yaml"
cat > "$ROOT/$PEND" <<Y
x: 1
Y' || missed="$missed \$ROOT/\$PEND"
flags b 'ROOT=/x
cd "$ROOT" || exit 1
printf "x\n" > __LED__/zz-probe.yaml' || missed="$missed cd-ROOT-relative"
flags c 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
printf "x\n" > __LED__/zz-probe.yaml' || missed="$missed one-liner-cd"
flags d 'echo x > "$REPO_ROOT/__LSD__/20990101-x.md"' || missed="$missed REPO_ROOT-loop_status"
flags e 'cd "$ROOT"
echo x | tee __LED__/zz.yaml >/dev/null' || missed="$missed tee"
[ -z "$missed" ] && ok "arm 1: all five live-write shapes are flagged" || bad "arm 1: missed:$missed"

# ── 2 ───────────────────────────────────────────────────────────────────────
wrongly=""
flags f 'cat > "$W/__LED__/x.yaml" <<Y
x: 1
Y' && wrongly="$wrongly \$W-prefix"
flags g 'cd "$ROOT"
cd "$W/wc" || exit 2
printf x > __LED__/a.yaml' && wrongly="$wrongly cd-scaffold"
flags h 'cd "$ROOT"
( cd "$S" && printf x > __LED__/a.yaml )' && wrongly="$wrongly same-line-subshell"
flags i 'cd "$ROOT"
n=$(cat __LED__/x.yaml | wc -l)' && wrongly="$wrongly read"
flags j 'cd "$ROOT"
git worktree add --detach -q "$wt" HEAD
cd "$wt" || exit 1
echo x > __LED__/probe.yaml' && wrongly="$wrongly worktree"
[ -z "$wrongly" ] && ok "arm 2: the scaffold idioms and a read are accepted" || bad "arm 2: wrongly flagged:$wrongly"

# ── 3 ───────────────────────────────────────────────────────────────────────
out="$(bash "$C" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qE '^ok:fixtures-write-scaffolds-only:[0-9]+ checked$' <<<"$out"; then
    ok "arm 3: the real corpus is clean ($(tail -n 1 <<<"$out"))"
else
    bad "arm 3: rc=$rc [$out]"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: no-fixture-writes-live-ledger $pass/$total (1320-44rs)"
    exit 0
fi
echo "FAIL: no-fixture-writes-live-ledger $pass/$total (1320-44rs)"
exit 1
