#!/usr/bin/env bash
# @trace order:1367-emjg
#
# test-landed-but-open.sh — scripts/check-landed-but-open.sh lists the orders a
# CODE landing cites whose ledger row is still open, and nothing else.
# Scratch repo; statuses from --status-file.
#
#   1  a code landing citing a READY order is listed (order, status, sha)
#   2  a code landing citing a COMPLETED order is not
#   3  a PLAN-ONLY commit citing a ready order is not a landing, not counted
#   4  an order named only in a commit BODY is not listed by default, and is
#      with --cite message
#   5  the summary's total equals the number of suspect lines, and the exit is
#      0 with suspects present (advisory)
#
# Pre-fix: FAILS at arm 1 (no script).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="$ROOT/scripts/check-landed-but-open.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/landed-but-open-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }
[ -x "$C" ] || { bad "arm 1: $C does not exist"; echo "FAIL: landed-but-open 0/1 (1367-emjg)"; exit 1; }

export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@example.invalid\n' >"$GIT_CONFIG_GLOBAL"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
R="$W/repo"
git init -q -b main "$R"
mkdir -p "$R/src" "$R/plan/index.d"
commit() { # commit <path> <message>
    echo "$RANDOM" >>"$R/$1"
    git -C "$R" add -A && git -C "$R" commit -q -m "$2"
}
commit src/a.rs "feat(1111-aaaa): the landed-but-open one"
A_SHA="$(git -C "$R" rev-parse --short=12 HEAD)"
commit src/b.rs "fix(2222-bbbb): landed and closed"
commit plan/index.d/x.yaml "plan(3333-cccc): claim"
commit src/c.rs "$(printf 'refactor: tidy\n\nContext: see 4444-dddd for why.')"
printf '1111-aaaa ready\n2222-bbbb completed\n3333-cccc ready\n4444-dddd ready\n' >"$W/status"

run() { (cd "$R" && bash "$C" --ref HEAD --since "1 day ago" --status-file "$W/status" "$@"); }
out="$(run)"; rc=$?

grep -q "^suspect:1111-aaaa:ready:${A_SHA} " <<<"$out" &&
    ok "arm 1: a code landing citing a ready order is listed with its status and sha" || bad "arm 1: [$out]"
! grep -q '2222-bbbb' <<<"$out" && ok "arm 2: a landing citing a completed order is not listed" || bad "arm 2: [$out]"
if ! grep -q '3333-cccc' <<<"$out" && grep -q ' landings=3 ' <<<"$out"; then
    ok "arm 3: a plan-only commit is not a landing (3 landings counted of 4 commits)"
else
    bad "arm 3: [$out]"
fi
wide="$(run --cite message)"
if ! grep -q '4444-dddd' <<<"$out" && grep -q '^suspect:4444-dddd:ready:' <<<"$wide"; then
    ok "arm 4: a body-only mention is not a citation by default, and is with --cite message"
else
    bad "arm 4: default=[$out] wide=[$wide]"
fi
n="$(grep -c '^suspect:' <<<"$out")"
total="$(sed -n 's/^summary:landed-but-open:\([0-9]*\) .*/\1/p' <<<"$out")"
[ "$rc" = 0 ] && [ -n "$total" ] && [ "$total" = "$n" ] &&
    ok "arm 5: the summary total ($total) equals the suspect lines, and the exit is 0 (advisory)" ||
    bad "arm 5: rc=$rc total=[$total] lines=$n"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: landed-but-open $pass/$total (1367-emjg)"
    exit 0
fi
echo "FAIL: landed-but-open $pass/$total (1367-emjg)"
exit 1
