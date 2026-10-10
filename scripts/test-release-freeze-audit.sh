#!/usr/bin/env bash
# @trace order:1255-s4im, order:1176-9vqn
#
# Fixture for `release-freeze.sh audit` and release-preflight's Gate 6.
#
# THE PREMISE IS THE RED OF 1255-s4im, reproduced 2026-10-09: a host with no
# hooks pushes code into a frozen branch and git accepts it. No client-side
# guard can stop a host that has none, so the cut must be able to SEE it from
# origin alone. Every push below is made with --no-verify, standing in for
# that host.
#
# Hermetic: a bare remote and clones under mktemp; HOME and the global git
# config point into it; the scripts under test are copied from the working
# tree. The real remote is never contacted.
#
# Arms:
#   1. no marker                          -> ok:freeze-none
#   2. frozen, branch unmoved             -> ok:freeze-audit:clean:moved=0
#   3. NEGATIVE CONTROL: plan-only push during the freeze -> clean
#   4. a hookless CODE push during the freeze -> violation naming the commit,
#      its author and the held path, exit 1
#   5. SAME ANSWER FROM ANY HOST: a clone that never fetched the breach reports
#      the identical verdict (it reads origin, not its own refs)
#   6. NEGATIVE CONTROL: code that landed BEFORE the freeze -> clean
#   7. the remedy works: reverting the breach makes the audit clean
#   8. an unreachable remote -> refused:freeze:unreachable, exit 3 (not "clean")
#   9. release-preflight refuses the breached cut (blocked:freeze-breached, exit
#      1, the remedy names the commit); after the revert it does not.
set -u

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/freeze-audit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

export HOME="$TMP/home" GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"; : > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=f@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=f@example.invalid
unset CARGO_TARGET_DIR TILLANDSIAS_PLAN_BIN

# A minimal repository the release preflight can run in: its gates 1-5 pass on
# this tree (stub monotonicity, minimal ledger, only the sanctioned workflow,
# no stable tag), so Gate 6 is reached and is the only thing under test.
R="$TMP/src"; mkdir -p "$R/scripts" "$R/.github/workflows" "$R/plan/index.d" "$R/crates/x/src"
cp "$SRC/scripts/release-freeze.sh" "$SRC/scripts/lib-freeze-paths.sh" \
   "$SRC/scripts/release-preflight.sh" "$SRC/scripts/plan-binary-probe.sh" "$R/scripts/"
printf '#!/bin/sh\nexit 0\n' > "$R/scripts/verify-version-monotonic.sh"
chmod +x "$R"/scripts/*.sh
printf 'plan_index:\n  steps: []\n' > "$R/plan/index.yaml"
printf 'name: release\n' > "$R/.github/workflows/release.yml"
echo "// code" > "$R/crates/x/src/lib.rs"
git init -q -b linux-next "$R" && git -C "$R" add -A && git -C "$R" commit -q -m seed
# --no-local throughout: a local clone hardlinks objects, and on macOS git
# intermittently aborts that ("hardlink different from source").
git clone -q --no-local --bare "$R" "$TMP/bare.git"
git clone -q --no-local "$TMP/bare.git" "$TMP/coord"     # the coordinator's clone
git clone -q --no-local "$TMP/bare.git" "$TMP/floor"     # a hookless floor host
C="$TMP/coord"; F="$TMP/floor"

audit() { # audit <clone> -> OUT RC
    OUT="$(cd "$1" && bash scripts/release-freeze.sh audit linux-next 2>"$TMP/err")"; RC=$?
}
last() { printf '%s\n' "$1" | tail -n 1; }
floor_push() { # floor_push <path> <content> <msg>
    git -C "$F" pull -q --no-rebase origin linux-next
    mkdir -p "$F/$(dirname "$1")"; printf '%s\n' "$2" >> "$F/$1"
    git -C "$F" add -A && git -C "$F" commit -q -m "$3"
    git -C "$F" push -q --no-verify origin linux-next
}

# 6 (set up first): code that lands BEFORE the freeze.
floor_push crates/x/src/lib.rs "// before the freeze" "code before the freeze"

# 1. not frozen
audit "$C"
[ "$RC" -eq 0 ] && [ "$(last "$OUT")" = "ok:freeze-none:linux-next" ] \
    && ok "arm 1: no marker -> ok:freeze-none" || bad "arm 1: rc=$RC out=[$OUT]"

# freeze (from the coordinator's clone, which is behind: set must still mark origin's tip)
( cd "$C" && bash scripts/release-freeze.sh set linux-next >/dev/null 2>&1 )
frozen_at="$(git --git-dir="$TMP/bare.git" rev-parse linux-next)"

# 2. unmoved; and 6, the pre-freeze code is not a breach
audit "$C"
[ "$RC" -eq 0 ] && [ "$(last "$OUT")" = "ok:freeze-audit:clean:linux-next:moved=0" ] \
    && ok "arm 2+6: frozen and unmoved -> clean; code that landed before the freeze is not a breach" \
    || bad "arm 2: rc=$RC out=[$OUT]"

# 3. plan-only during the freeze
floor_push plan/index.d/claim.yaml "x: 1" "plan only, during the freeze"
audit "$C"
[ "$RC" -eq 0 ] && [ "$(last "$OUT")" = "ok:freeze-audit:clean:linux-next:moved=1" ] \
    && ok "arm 3 (control): a plan-only push during the freeze -> clean" || bad "arm 3: rc=$RC out=[$OUT]"

# 4. the red: a hookless code push during the freeze
floor_push crates/x/src/lib.rs "// during the freeze" "code during the freeze"
breach_full="$(git -C "$F" rev-parse HEAD)"
audit "$C"
# The audit abbreviates with git's %h; resolve what it named back to a full sha.
breach="$(sed -n 's/^breach:linux-next:\([0-9a-f]*\):.*/\1/p' <<<"$OUT" | head -n 1)"
if [ "$RC" -eq 1 ] && [ -n "$breach" ] && [ "$(git -C "$F" rev-parse "$breach" 2>/dev/null)" = "$breach_full" ] \
   && grep -q "^breach:linux-next:${breach}:fixture:code during the freeze$" <<<"$OUT" \
   && grep -qx 'held:crates/x/src/lib.rs' <<<"$OUT" \
   && [[ "$(last "$OUT")" == violation:freeze-breached:linux-next:commits=1:held-paths=1:frozen-at=* ]] \
   && grep -q '  remedy: ' "$TMP/err"; then
    ok "arm 4: a hookless code push during the freeze -> violation naming $breach, its author and crates/x/src/lib.rs (exit 1)"
else
    bad "arm 4: rc=$RC out=[$OUT] err=[$(cat "$TMP/err")]"
fi
coord_verdict="$(last "$OUT")"

# 5. the same answer from a host that never fetched the breach
git clone -q --no-local "$TMP/bare.git" "$TMP/late"; git -C "$TMP/late" reset -q --hard "$frozen_at"
git -C "$TMP/late" update-ref refs/remotes/origin/linux-next "$frozen_at"
audit "$TMP/late"
[ "$RC" -eq 1 ] && [ "$(last "$OUT")" = "$coord_verdict" ] \
    && ok "arm 5: a clone whose refs predate the breach gives the identical verdict — it reads origin" \
    || bad "arm 5: rc=$RC got [$(last "$OUT")] want [$coord_verdict]"

# 9a. the release preflight refuses the breached cut
PF="$(cd "$C" && git pull -q --no-rebase origin linux-next && bash scripts/release-preflight.sh 2>"$TMP/pferr")"; PRC=$?
if [ "$PRC" -eq 1 ] && [ "$(last "$PF")" = "blocked:freeze-breached" ] \
   && grep -q "remedy: revert the breach (git revert ${breach}" "$TMP/pferr"; then
    ok "arm 9a: release-preflight refuses the breached cut (blocked:freeze-breached, exit 1) and its remedy names $breach"
else
    bad "arm 9a: rc=$PRC out=[$PF] err=[$(tail -5 "$TMP/pferr")]"
fi

# 7. the remedy works: revert the breach
git -C "$F" revert --no-edit HEAD >/dev/null && git -C "$F" push -q --no-verify origin linux-next
audit "$C"
[ "$RC" -eq 0 ] && [[ "$(last "$OUT")" == ok:freeze-audit:clean:linux-next:moved=* ]] \
    && ok "arm 7: after reverting the breach the audit reads clean — the remedy clears it" \
    || bad "arm 7: rc=$RC out=[$OUT]"

# 9b. ... and the preflight no longer refuses for it
PF="$(cd "$C" && git pull -q --no-rebase origin linux-next && bash scripts/release-preflight.sh 2>"$TMP/pferr")"; PRC=$?
[ "$(last "$PF")" != "blocked:freeze-breached" ] && [ "$PRC" -eq 0 ] \
    && ok "arm 9b (control): after the revert the preflight passes ($(last "$PF"))" \
    || bad "arm 9b: rc=$PRC out=[$PF] err=[$(tail -5 "$TMP/pferr")]"

# 8. unreachable remote
git -C "$C" remote set-url origin "$TMP/nowhere.git"
audit "$C"
[ "$RC" -eq 3 ] && [[ "$(last "$OUT")" == refused:freeze:unreachable:* ]] \
    && ok "arm 8: an unreachable remote -> refused:freeze:unreachable (exit 3), never 'clean'" \
    || bad "arm 8: rc=$RC out=[$OUT]"

echo "test-release-freeze-audit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
