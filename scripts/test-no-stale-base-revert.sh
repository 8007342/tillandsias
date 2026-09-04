#!/usr/bin/env bash
# @trace spec:meta-orchestration
# @trace order:1000-rqmx
#
# Fixture for the stale-base revert guard.
#
# THE PACKET NAMES THIS TEST AS ITS REAL DELIVERABLE: "a fixture that constructs
# a stale-base branch — one innocent commit, a trunk advanced beneath it — and
# asserts the gate refuses the push while the same commit rebased is accepted.
# That test is the packet's real deliverable and whoever takes this should write
# it first." So it is written first, and the guard is shaped by it.
#
# EVERY ARM DRIVES A REAL PUSH through a real installed hook against a real bare
# remote. Asserting the guard's output on a hand-made ref list would test the
# script's argument parsing, not the thing that actually happens when a stale
# branch meets `git push`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-no-stale-base-revert.sh"
[ -x "$GUARD" ] || { echo "blocked:no-guard:$GUARD"; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/stale-base.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() {
    if [ "$1" = ok ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$2"
    else fail=$((fail + 1)); printf 'FAIL %s\n' "$2"; [ -n "${3:-}" ] && printf '     %s\n' "$3"; fi
}

git init -q --bare "$tmp/origin.git"
git init -q -b main "$tmp/work"
cd "$tmp/work" || exit 2
git config user.email f@f; git config user.name f
git config core.hooksPath "$tmp/work/.githooks"
mkdir -p .githooks
# The hook under test, alone, so nothing else in the repo's real chain can
# explain a refusal.
cat > .githooks/pre-push <<EOS
#!/usr/bin/env bash
exec bash "$GUARD" "\$@"
EOS
chmod +x .githooks/pre-push
git remote add origin "$tmp/origin.git"

# Trunk: three files that belong to OTHER hosts.
for f in trunk_a trunk_b trunk_c; do echo "$f" > "$f"; done
echo mine > mine.txt
git add -A && git commit -qm base
git push -q origin main 2>/dev/null
base="$(git rev-parse HEAD)"

# ── the stale-base branch: ONE innocent commit on the OLD base ──────────────
git checkout -q -b stale "$base"
echo "my session's work" >> mine.txt
git commit -qam "innocent: only touches mine.txt"

# ── the trunk advances beneath it, as another host's work ───────────────────
git checkout -q main
for f in trunk_d trunk_e; do echo "$f" > "$f"; done
git add -A && git commit -qm "another host's work"
git push -q origin main 2>/dev/null

# 1. THE CRITERION, and it must be a FORCE push. MEASURED while writing this:
#    a PLAIN non-fast-forward push is rejected by git itself and the hook
#    receives an EMPTY ref list, so there is nothing for this guard to judge.
#    The dangerous invocation — and the only one this guard can reach — is a
#    forced one. See the packet event for why that corrects the threat model.
git checkout -q stale
out="$(git push --force origin stale:main 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^blocked:stale-base-revert:'; then
    check ok "a stale-base push is refused"
else
    check FAIL "a stale-base push is refused" "rc=$rc out=[$(printf '%s' "$out" | tail -3)]"
fi
if printf '%s' "$out" | grep -q 'trunk_d' && printf '%s' "$out" | grep -q 'trunk_e'; then
    check ok "the refusal NAMES the files that would be reverted"
else
    check FAIL "the refusal names the files" "out=[$(printf '%s' "$out" | tail -5)]"
fi

# 1b. THE TRAP, and it is the one worth pinning: --force-with-lease after a
#     FRESH FETCH also reverts. The lease proves only that the remote has not
#     moved since YOUR fetch — not that your base is current — so a loop that
#     fetches each iteration REFRESHES the lease and it always passes. The more
#     careful the loop looks, the more reliably it reverts. Measured.
out="$(git fetch -q origin; git push --force-with-lease origin stale:main 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^blocked:stale-base-revert:'; then
    check ok "--force-with-lease after a fresh fetch is ALSO refused"
else
    check FAIL "--force-with-lease after a fresh fetch is refused" "rc=$rc out=[$(printf '%s' "$out" | tail -3)]"
fi

# 2. THE OTHER HALF, and without it arm 1 is satisfied by a guard that refuses
#    everything: the SAME commit, rebased, must be ACCEPTED.
git rebase -q origin/main 2>/dev/null
out="$(git push origin stale:main 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    check ok "the SAME commit rebased is accepted"
else
    check FAIL "the same commit rebased is accepted" "rc=$rc out=[$(printf '%s' "$out" | tail -3)]"
fi

# 3. A DELIBERATE DELETION IS NOT A REVERT. A commit that removes a file it
#    touched must pass, or the guard blocks ordinary work.
git checkout -q main && git pull -q --ff-only origin main 2>/dev/null
git rm -q trunk_a && git commit -qm "delete a file on purpose"
out="$(git push origin main 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    check ok "a deletion the commit itself made is accepted"
else
    check FAIL "a deletion the commit itself made is accepted" "rc=$rc out=[$(printf '%s' "$out" | tail -3)]"
fi

# 4. A BRAND-NEW REMOTE REF IS NEVER BLOCKED. That is the salvage path
#    (872-c9nd), which exists to rescue work from exactly the wedged host this
#    guard is about — blocking it would be the worst possible failure.
git checkout -q -b salvage/test
echo salvaged > salvaged.txt && git add -A && git commit -qm "salvage copy"
out="$(git push origin salvage/test 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    check ok "a new remote ref (the salvage path) is never blocked"
else
    check FAIL "a new remote ref is never blocked" "rc=$rc out=[$(printf '%s' "$out" | tail -3)]"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: stale-base revert guard ${pass}/${total} (1000-rqmx)"
    exit 0
fi
echo "FAIL: stale-base revert guard ${fail}/${total} red (1000-rqmx)"
exit 1
