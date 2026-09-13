#!/usr/bin/env bash
# @trace order:1144-jfr5
# test-stale-ready-rows.sh — pins check-stale-ready-rows.sh's first pass
# (cites-the-order) in a hermetic scratch repo: candidates, the three negative
# controls, the count-and-newest grammar, and exit 0. The real-tree arm only
# asserts the summary grammar, since a live candidate is a coincidence.
# bash 3.2 clean (761-g36m).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/check-stale-ready-rows.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-stale-ready-rows.XXXXXX")" || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM
fails=0; passes=0
ok()   { passes=$((passes + 1)); echo "ok: $1"; }
fail() { fails=$((fails + 1)); echo "FAIL: $1"; }

repo="$tmp/repo"; mkdir -p "$repo"; cd "$repo" || exit 2
git init -q .; git config user.email t@t; git config user.name t; git config commit.gpgsign false
c() { echo "$1" >> f; git add f; git -c commit.gpgsign=false commit -q -m "$1"; }
c "fix(1001-aaaa): the first candidate"
c "claim(1002-bbbb): a claim is not work"
c "close(1003-cccc, 1004-dddd): two orders in one subject"
c "docs: mention 1005-eeee without the cite shape"
c "feat(1001-aaaab): a longer order that must not match 1001-aaaa"
c "fix(278): numeric order"
c "fix(1278-zzzz): must not match 278"
c "test(1001-aaaa): the second citing commit, newest"
printf '%s\n' 1001-aaaa 1002-bbbb 1003-cccc 1005-eeee 278 '# comment' > "$tmp/orders"
out="$(bash "$check" --repo "$repo" --orders-file "$tmp/orders")"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 (advisory)" || fail "exit $rc, wanted 0"
newest="$(git rev-parse --short HEAD)"
printf '%s\n' "$out" | grep -qx "stale-candidate:1001-aaaa:2:${newest}" && ok "two citing commits counted, newest sha first" || fail "1001-aaaa line wrong: $(printf '%s\n' "$out" | grep 1001-aaaa)"
printf '%s\n' "$out" | grep -q '^stale-candidate:1003-cccc:1:' && ok "an order cited among several in one subject is a candidate" || fail "1003-cccc missing"
printf '%s\n' "$out" | grep -q '^stale-candidate:278:1:' && ok "a numeric order is bounded (278 found once, not via 1278)" || fail "278 wrong: $(printf '%s\n' "$out" | grep ':278:')"
printf '%s\n' "$out" | grep -q '1002-bbbb' && fail "NEGATIVE CONTROL: claim(<order>) reported as work" || ok "NEGATIVE CONTROL: claim(<order>) is not a candidate"
printf '%s\n' "$out" | grep -q '1005-eeee' && fail "NEGATIVE CONTROL: a bare mention without the cite shape reported" || ok "NEGATIVE CONTROL: a mention without (<order>) is not a candidate"
printf '%s\n' "$out" | grep -q '1004-dddd' && fail "NEGATIVE CONTROL: an order that is not ready was reported" || ok "NEGATIVE CONTROL: an order not in the ready list is never reported"
printf '%s\n' "$out" | grep -qx 'ok:stale-ready-rows:3/5:pass=cites-order' && ok "summary grammar: 3 candidates of 5 ready rows" || fail "summary wrong: $(printf '%s\n' "$out" | tail -1)"
# MUTATION: widening the prefix list to include claim( would red the negative control — asserted by construction above.
# Real tree: grammar only.
cd "$here/.." || exit 2
real="$(bash "$check" 2>/dev/null | tail -1)"
printf '%s\n' "$real" | grep -q -E '^ok:stale-ready-rows:[0-9]+/[0-9]+:pass=cites-order' && ok "real tree: summary grammar holds ($real)" || fail "real tree summary: $real"
echo "stale-ready-rows fixture: ${passes} passed, ${fails} failed"
[ "$fails" -eq 0 ] && { echo "ok:stale-ready-rows-fixture:all"; exit 0; } || exit 1
