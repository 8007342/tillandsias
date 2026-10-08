#!/usr/bin/env bash
# @trace order:1063-363b, order:1528-ekri
#
# Fixture for check-tracked-files-unwritten.lua.
#
# Arm 1 reproduces lenovinha's corruption exactly — plan-binary-probe.sh
# overwritten with the contents of check-fragment-status-loss.sh — because that
# is the observed event and not an imitation of it.
#
# Arm 4 is the one that would have been easy to leave out. The guard hashes
# with fs.read + hash.sha256 now (not a `sha256sum` subprocess), but the
# comparison is still keyed by PATH, not by any whitespace-split text line, so
# a path containing a space must still compare and name correctly. It is
# checked on a real file with a real space in its name.
#
# PORTED to Lua (1528-ekri): the guard is
# scripts/lua/check-tracked-files-unwritten.lua, run through the one runner.
# It finds its repo root from the process's CWD (find_repo_root), not from its
# own script path, so this fixture no longer copies the guard into the scratch
# repo — it `cd`s there and runs the real checkout's .lua by absolute path.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN_BIN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
if [ -z "$PLAN_BIN" ] || ! grep -qx script <<<"$("$PLAN_BIN" capabilities 2>/dev/null)"; then
    echo "skip:tracked-files-unwritten-guard-fixture:no-script-runner — no tillandsias-plan with \`script run\` resolves; rebuild it (cargo build --release -p tillandsias-plan)"
    exit 0
fi
GUARD_LUA="$ROOT/scripts/lua/check-tracked-files-unwritten.lua"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/tracked-unwritten.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
G() { git -c user.email=t@t -c user.name=t "$@"; }

git init -q -b main "$W/repo"
cd "$W/repo" || exit 2
mkdir -p scripts
printf 'probe contents\n' > scripts/plan-binary-probe.sh
printf 'status loss contents\n' > scripts/check-fragment-status-loss.sh
printf 'a tracked file\n' > 'a file with spaces.txt'
G add -A >/dev/null; G commit -q -m base

# TILLANDSIAS_REPO_ROOT is pinned explicitly on every call below: the
# runner's find_repo_root prefers it, then PROJECT_ROOT, then cwd, and a
# litmus-driven run exports PROJECT_ROOT for the REAL checkout, which would
# otherwise win over this scratch repo's own `cd`.
_snap()   { TILLANDSIAS_REPO_ROOT="$W/repo" "$PLAN_BIN" script run "$GUARD_LUA" -- snapshot "$W/state" >/dev/null 2>&1; echo $?; }
_verify() { TILLANDSIAS_REPO_ROOT="$W/repo" "$PLAN_BIN" script run "$GUARD_LUA" -- verify "$W/state" 2>&1; }
_vrc()    { TILLANDSIAS_REPO_ROOT="$W/repo" "$PLAN_BIN" script run "$GUARD_LUA" -- verify "$W/state" >/dev/null 2>&1; echo $?; }

# ── 0. The snapshot must succeed, or every arm below is vacuous ────────────
[ "$(_snap)" = "0" ] && ok "the snapshot succeeds on a clean tree" \
    || bad "the snapshot failed; every arm below would be measuring nothing"

# ── 1. A CLEAN RUN is silent ──────────────────────────────────────────────
[ "$(_vrc)" = "0" ] && ok "an untouched tree verifies clean" \
    || bad "a clean tree was reported as written"

# ── 2. LENOVINHA'S EXACT CORRUPTION is named ──────────────────────────────
cp scripts/check-fragment-status-loss.sh scripts/plan-binary-probe.sh
out="$(_verify)"; rc="$(_vrc)"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'scripts/plan-binary-probe.sh'; then
    ok "an instrument overwritten mid-run is named"
else
    bad "the overwritten instrument was not named (rc=$rc)"
fi
G checkout -- scripts/plan-binary-probe.sh

# ── 3. MODIFY-THEN-RESTORE-TO-DIFFERENT-BYTES is caught ───────────────────
# `git status` would call this clean whenever the restore happens to match the
# index; content comparison is why the guard hashes instead.
printf 'probe contents modified\n' > scripts/plan-binary-probe.sh
[ "$(_vrc)" != "0" ] && ok "a content change git might not surface is still caught" \
    || bad "a content change was missed"
G checkout -- scripts/plan-binary-probe.sh

# ── 4. A PATH WITH SPACES is compared correctly ───────────────────────────
printf 'overwritten\n' > 'a file with spaces.txt'
out="$(_verify)"
if printf '%s' "$out" | grep -q 'a file with spaces.txt'; then
    ok "a path containing spaces is compared and named correctly"
else
    bad "a path with spaces was dropped from the comparison — the guard has a blind spot"
fi
G checkout -- 'a file with spaces.txt'

# ── 5. A MISSING BASELINE fails closed, never as a clean tree ─────────────
# The fail-open shape this guard exists to refuse: no snapshot must not read as
# "nothing was written".
rm -f "$W/state"
rc="$(_vrc)"
[ "$rc" = "2" ] && ok "a missing baseline is blocked, not reported clean" \
    || bad "a missing baseline returned $rc instead of blocking"

# ── 6. UNTRACKED files are not the subject ────────────────────────────────
# A fixture writing its own scratch file into the tree is untidy, not a
# corrupted instrument; flagging it would make the guard noisy and it would be
# switched off.
TILLANDSIAS_REPO_ROOT="$W/repo" "$PLAN_BIN" script run "$GUARD_LUA" -- snapshot "$W/state" >/dev/null 2>&1
printf 'scratch\n' > untracked-scratch.txt
[ "$(_vrc)" = "0" ] && ok "an untracked scratch file is not reported as a write" \
    || bad "an untracked file was reported; the guard would be too noisy to keep"
rm -f untracked-scratch.txt

echo "tracked-files-unwritten-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
