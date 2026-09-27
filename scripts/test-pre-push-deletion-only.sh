#!/usr/bin/env bash
# @trace order:1427-r2d2, spec:ci-release
#
# test-pre-push-deletion-only.sh — a push that only DELETES remote refs
# transfers no tree, so the local tree's gate stamp must not decide it; the
# protected refs must stay exactly as guarded as before.
#
# Hermetic: a bare scratch remote plus a working copy with the REAL hook
# installed as .git/hooks/pre-push (core.hooksPath pinned, since a forge sets a
# global one). Refs are created with --no-verify; every arm then pushes through
# the hook from a DIRTY tree that has never been stamped.
#
#   1  deleting release/* from a dirty, unstamped tree is ADMITTED   (pre-fix: FAILS)
#   2  deleting salvage/* is still REFUSED (874-w2gc)
#   3  a MIXED push (one update + one delete) still demands the stamp
#   4  deleting linux-next is still gated (refused on an unstamped tree)
#
#   PASS: pre-push-deletion-only <n>/<n>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-local-gate.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/deletion-only.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"
git config core.hooksPath .git/hooks
git config core.autocrlf false
mkdir -p scripts/hooks plan/index.d crates/demo
cp "$GUARD" scripts/hooks/pre-push-local-gate.sh
for f in gate-stamp.sh plan-binary-probe.sh common.sh; do cp "$ROOT/scripts/$f" "scripts/$f" 2>/dev/null || true; done
chmod +x scripts/*.sh scripts/hooks/*.sh 2>/dev/null || true
printf 'packets: []\n' > plan/index.yaml
printf 'fn main() {}\n' > crates/demo/main.rs
G add -A >/dev/null; G commit -q -m base
for r in linux-next release/version-bump-0.0.1 release/version-bump-0.0.2 salvage/fixture/20260927-x; do
    git push -q --no-verify origin "linux-next:refs/heads/$r"
done
printf '#!/bin/sh\nexec bash scripts/hooks/pre-push-local-gate.sh "$@"\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
# The dirt: an ungated code edit, never stamped (the cut's relay-merge state).
printf 'fn main() { let _dirty = 1; }\n' > crates/demo/main.rs
has() { git ls-remote "$W/bare.git" "refs/heads/$1" | grep -c .; }

# ARM 1
out="$(git push origin --delete release/version-bump-0.0.1 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(has release/version-bump-0.0.1)" -eq 0 ]; then
    ok "ARM 1: deleting release/* from a dirty, unstamped tree is admitted"
else
    bad "ARM 1: rc=$rc; $(printf '%s\n' "$out" | grep -m2 -E 'refused|not applicable|changed since' | tr '\n' ' ')"
fi

# ARM 2
out="$(git push origin --delete salvage/fixture/20260927-x 2>&1)"; rc=$?
case "$out" in
    (*874-w2gc*) salvage_named=1 ;;
    (*) salvage_named=0 ;;
esac
if [ "$rc" -ne 0 ] && [ "$(has salvage/fixture/20260927-x)" -eq 1 ] && [ "$salvage_named" -eq 1 ]; then
    ok "ARM 2: deleting salvage/* is still refused, naming 874-w2gc"
else
    bad "ARM 2: rc=$rc named=$salvage_named ref-present=$(has salvage/fixture/20260927-x)"
fi

# ARM 3 — a mixed push: a new branch plus a deletion, same dirty tree.
G commit -q -am "an ungated change" >/dev/null
out="$(git push origin HEAD:refs/heads/feature-mixed :refs/heads/release/version-bump-0.0.2 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(has release/version-bump-0.0.2)" -eq 1 ] && [ "$(has feature-mixed)" -eq 0 ]; then
    ok "ARM 3: a mixed update+delete push still demands the stamp (refused, nothing moved)"
else
    bad "ARM 3: rc=$rc release-present=$(has release/version-bump-0.0.2) feature=$(has feature-mixed)"
fi

# ARM 4
out="$(git push origin --delete linux-next 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(has linux-next)" -eq 1 ]; then
    ok "ARM 4: deleting linux-next is still gated (refused on an unstamped tree)"
else
    bad "ARM 4: rc=$rc linux-next-present=$(has linux-next)"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: pre-push-deletion-only $pass/$total (1427-r2d2)"
    exit 0
fi
echo "FAIL: pre-push-deletion-only $pass/$total (1427-r2d2)"
exit 1
