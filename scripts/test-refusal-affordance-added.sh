#!/usr/bin/env bash
# @trace order:1470-v67y, spec:methodology-accountability
#
# Fixture for scripts/check-refusal-affordance-added.sh (1470-v67y, the guard
# and per-site audit for 1247-amcu), over scratch repos whose origin/linux-next
# is the base:
#
#   1. an ADDED bare `echo "refused:…"` is REFUSED, naming file:line;
#   2. the same verdict followed by `_afford "<why>" "<remedy>"` is admitted;
#   3. affordance printed first, then the bare token repeated on stdout for a
#      caller to parse: admitted (the look-back);
#   4. why/remedy written as text is admitted;
#   5. `# affordance-ok: <reason>` admits a program-only token, and an EMPTY
#      marker does not;
#   6. lines that MATCH a verdict without emitting it (a case arm, a grep
#      pattern, a comment) are not refusals;
#   7. NEGATIVE CONTROL: a bare verdict already in the base is not re-litigated,
#      and a fixture file (scripts/test-*.sh) is skipped;
#   8. --audit counts PER SITE: one file with one covered and two bare verdicts
#      lists covered=1 and bare=2 for that file, not "covered".
#
# PRE-FIX RESULT: FAILS — no guard existed, and 289 of 339 verdicts reached
# trunk with no affordance (1247-amcu, measured per file, so a floor).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-refusal-affordance-added.sh"
pass=0; total=8
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

[ -f "$GUARD" ] || { echo "fail:refusal-affordance-added-fixture:0/$total (guard missing)"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "skip:refusal-affordance-added-fixture:no-git"; exit 0; }

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/refusal-affordance.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
GC=(-c user.email=f@x -c user.name=f)

repo() { # repo <name> [base content of scripts/x.sh]
    local r="$W/$1"
    mkdir -p "$r/scripts"
    cp "$GUARD" "$r/scripts/"
    printf '%s\n' "${2:-#!/bin/bash}" > "$r/scripts/x.sh"
    git -C "$r" init -q && git -C "$r" "${GC[@]}" add -A && git -C "$r" "${GC[@]}" commit -qm base
    git -C "$r" update-ref refs/remotes/origin/linux-next HEAD
    echo "$r"
}
run() { OUT="$(cd "$1" && bash scripts/check-refusal-affordance-added.sh "${@:2}" 2>&1)"; RC=$?; }
put() { printf '%s\n' "$2" > "$1/scripts/x.sh"; }

# 1 — bare.
R="$(repo one)"
put "$R" '#!/bin/bash
if [ -z "$X" ]; then
    echo "refused:thing:no-x" >&2
    exit 1
fi'
run "$R"
[ "$RC" -eq 1 ] && grep -q '^violation:refusal-affordance-added:1$' <<<"$OUT" && grep -q 'scripts/x.sh:3' <<<"$OUT" \
    && ok "arm 1: an added bare refusal is refused, naming scripts/x.sh:3" \
    || bad "arm 1: rc=$RC [$OUT]"

# 2 — _afford after.
R="$(repo two)"
put "$R" '#!/bin/bash
_afford() { printf "  why: %s\n  remedy: %s\n" "$1" "$2" >&2; }
if [ -z "$X" ]; then
    echo "refused:thing:no-x" >&2
    _afford "X names the target and is unset" "export X=<target>, then re-run"
    exit 1
fi'
run "$R"
[ "$RC" -eq 0 ] && ok "arm 2: a refusal followed by _afford is admitted" || bad "arm 2: rc=$RC [$OUT]"

# 3 — affordance first, token repeated after.
R="$(repo three)"
put "$R" '#!/bin/bash
_afford() { printf "  why: %s\n  remedy: %s\n" "$1" "$2" >&2; }
if [ -z "$X" ]; then
    _afford "X names the target and is unset" "export X=<target>, then re-run"
    echo "blocked:no-x"
    exit 2
fi'
run "$R"
[ "$RC" -eq 0 ] && ok "arm 3: affordance printed first, token repeated for the caller: admitted" || bad "arm 3: rc=$RC [$OUT]"

# 4 — why/remedy as text.
R="$(repo four)"
put "$R" '#!/bin/bash
echo "violation:thing:bad-shape" >&2
echo "  why: the file must parse as YAML" >&2
echo "  remedy: fix the line named above, then re-run" >&2'
run "$R"
[ "$RC" -eq 0 ] && ok "arm 4: why/remedy written as text is admitted" || bad "arm 4: rc=$RC [$OUT]"

# 5 — affordance-ok with a reason; an empty marker does not count.
R="$(repo five)"
put "$R" '#!/bin/bash
# affordance-ok: land-queue.sh reads this token and prints the remedy
echo "blocked:queue-empty"'
run "$R"; rc_reason=$RC
put "$R" '#!/bin/bash
# affordance-ok:
echo "blocked:queue-empty"'
run "$R"; rc_empty=$RC
[ "$rc_reason" -eq 0 ] && [ "$rc_empty" -eq 1 ] \
    && ok "arm 5: affordance-ok with a reason admits a program-only token; an empty marker does not" \
    || bad "arm 5: with-reason rc=$rc_reason, empty rc=$rc_empty"

# 6 — matching is not emitting.
R="$(repo six)"
put "$R" '#!/bin/bash
# a comment mentioning echo "refused:thing:x"
case "$out" in
    refused:*) handle ;;
esac
grep -q "^violation:thing:" "$log" && handle'
run "$R"
[ "$RC" -eq 0 ] && ok "arm 6: a comment, a case arm and a grep pattern are not refusals" || bad "arm 6: rc=$RC [$OUT]"

# 7 — NEGATIVE CONTROL: the base is not re-litigated; fixtures are skipped.
R="$(repo seven '#!/bin/bash
echo "refused:old:bare" >&2')"
put "$R" '#!/bin/bash
echo "refused:old:bare" >&2
echo "an unrelated addition"'
printf '#!/bin/bash\necho "refused:expected:by-a-fixture"\n' > "$R/scripts/test-y.sh"
run "$R"
[ "$RC" -eq 0 ] && ok "arm 7: a pre-existing bare verdict and a fixture's expected verdict are not refused" \
    || bad "arm 7: rc=$RC [$OUT]"

# 8 — --audit is per SITE.
R="$(repo eight)"
put "$R" '#!/bin/bash
_afford() { printf "  why: %s\n  remedy: %s\n" "$1" "$2" >&2; }
echo "refused:a:covered" >&2
_afford "why a" "remedy a"
exit 1
echo "unrelated line one"
echo "unrelated line two"
echo "unrelated line three"
echo "unrelated line four"
echo "unrelated line five"
echo "refused:b:bare" >&2
exit 1
echo "unrelated line six"
echo "unrelated line seven"
echo "unrelated line eight"
echo "unrelated line nine"
echo "unrelated line ten"
echo "violation:c:bare"'
git -C "$R" "${GC[@]}" commit -qam audit
run "$R" --audit
# Count only this file's sites: the scratch repo also holds the guard itself.
xc="$(grep -c '^covered scripts/x.sh:' <<<"$OUT")"; xb="$(grep -c '^bare scripts/x.sh:' <<<"$OUT")"
if [ "$xc" = 1 ] && [ "$xb" = 2 ] && grep -q '^audit:refusal-affordance:covered=[0-9]* bare=[0-9]* sites=[0-9]*$' <<<"$OUT" \
   && grep -q '^covered scripts/x.sh:3 refused:a:covered$' <<<"$OUT" && grep -q '^bare scripts/x.sh:11 refused:b:bare$' <<<"$OUT"; then
    ok "arm 8: --audit counts per site (covered=1 bare=2), naming file:line — one good message does not credit the file"
else
    bad "arm 8: [$OUT]"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:refusal-affordance-added-fixture:$pass/$total"
    exit 0
fi
echo "fail:refusal-affordance-added-fixture:$pass/$total"
exit 1
