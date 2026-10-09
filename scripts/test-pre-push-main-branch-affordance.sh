#!/usr/bin/env bash
# @trace order:1443-sb9b, spec:branch-discipline
#
# Fixture for the Lua port of the main-branch pre-push affordance
# (scripts/lua/pre-push-main-branch-affordance.lua behind the stub
# scripts/hooks/pre-push-main-branch-affordance.sh), order 1443-sb9b.
#
#   1. a feed targeting refs/heads/main prints blocked:main-branch-affordance
#      (rc 1) and a remedy naming the seed's integration branch for the
#      platform (forge -> linux-next) with source=seed;
#   2. the stub is <= 15 lines, runs `"$PLAN" lua` on the .lua, and with
#      TILLANDSIAS_PLAN_BIN pointing at a non-runnable file prints
#      blocked:main-branch-affordance:no-plan-binary (rc 1);
#   3. NEGATIVE CONTROL: a feed naming only refs/heads/linux-next, or no feed,
#      prints ok:main-branch-affordance (rc 0);
#   4. FLOOR: from a project with no seed, main is ok (level 0 refuses nothing);
#   5. FAIL-CLOSED: a runnable binary whose `discipline` answers junk prints
#      blocked:main-branch-affordance:discipline-unanswered (rc 1).
#
# PRE-FIX RESULT: FAILS at arm 1 — the shell original hardcoded linux-next and
# never said where the branch came from, and there was no .lua.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/hooks/pre-push-main-branch-affordance.sh"
pass=0; total=5
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
[ -n "$_plan" ] || { echo "skip:main-branch-affordance-fixture:no-plan-binary — build one: cargo build --release -p tillandsias-plan"; exit 0; }
PLAN="$_plan"
command -v git >/dev/null 2>&1 || { echo "skip:main-branch-affordance-fixture:no-git"; exit 0; }

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/main-afford.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# hook <cwd> <feed> [env...] -> OUT (stdout), ERR (stderr), RC. Captured, never
# piped into a verdict (check-sigpipe-verdict-pipelines-added).
hook() {
    local dir="$1" feed="$2"; shift 2
    OUT="$(cd "$dir" && printf '%s\n' "$feed" | env TILLANDSIAS_PLAN_BIN="$PLAN" "$@" bash "$HOOK" 2>"$W/err")"; RC=$?
    ERR="$(cat "$W/err")"
}
first() { printf '%s' "${1%%$'\n'*}"; }

# 1 — main is refused, and the remedy comes from the seed.
hook "$ROOT" "refs/heads/x 1111 refs/heads/main 2222" TILLANDSIAS_HOST_KIND=forge
if [ "$RC" -eq 1 ] && [ "$(first "$OUT")" = "blocked:main-branch-affordance" ] \
   && grep -q "work on 'linux-next', the forge integration branch in the seed" <<<"$ERR" \
   && grep -q 'source=seed level=2 enforcement=enforced' <<<"$ERR"; then
    ok "arm 1: main blocked; remedy names the seed's forge branch (linux-next) with source=seed"
else
    bad "arm 1: rc=$RC out=[$OUT] err=[$ERR]"
fi

# 2 — the stub is small, runs the Lua, and fails closed without a binary.
lines="$(wc -l < "$HOOK" | tr -d ' ')"
# NON-RUNNABLE ON EVERY FILESYSTEM (1556-b2tq). This used to be an EMPTY file.
# On a Windows host the WSL2 guest sees the checkout over 9p (/mnt/c), where
# every new file is mode 777, and bash runs an empty executable as an empty
# script that exits 0 (measured on yolanda 2026-10-08: mode=777 fs=v9fs exec
# rc=0, against 644 / rc=126 on ext4). So the hook's capabilities call passed,
# the Lua printed nothing, and the arm read no-verdict. A shebang naming an
# interpreter that does not exist fails to execute (126/127) whatever the mode.
printf '#!/nonexistent/tillandsias-not-an-interpreter\n' > "$W/not-runnable"
hook "$ROOT" "refs/heads/x 1 refs/heads/linux-next 2" TILLANDSIAS_PLAN_BIN="$W/not-runnable"
if [ "$lines" -le 15 ] && grep -q '"\$PLAN" lua "\$ROOT/scripts/lua/pre-push-main-branch-affordance.lua"' "$HOOK" \
   && [ "$RC" -eq 1 ] && [ "$(first "$OUT")" = "blocked:main-branch-affordance:no-plan-binary" ]; then
    ok "arm 2: stub is $lines lines, runs the .lua, and fails closed (no-plan-binary, rc 1)"
else
    bad "arm 2: lines=$lines rc=$RC out=[$OUT]"
fi

# 3 — NEGATIVE CONTROL: nothing targeting the protected branch passes.
hook "$ROOT" "refs/heads/linux-next 1 refs/heads/linux-next 2"; rc_a=$RC; out_a="$OUT"
hook "$ROOT" ""; rc_b=$RC; out_b="$OUT"
if [ "$rc_a" -eq 0 ] && [ "$out_a" = "ok:main-branch-affordance" ] \
   && [ "$rc_b" -eq 0 ] && [ "$out_b" = "ok:main-branch-affordance" ]; then
    ok "arm 3: linux-next and an empty feed -> ok:main-branch-affordance, rc 0"
else
    bad "arm 3: linux-next rc=$rc_a [$out_a] | empty rc=$rc_b [$out_b]"
fi

# 4 — FLOOR: a project with no seed pushes main freely.
BARE="$W/bare"; mkdir -p "$BARE"; git -C "$BARE" -c init.defaultBranch=main init -q
hook "$BARE" "refs/heads/main 1 refs/heads/main 2"
if [ "$RC" -eq 0 ] && [ "$OUT" = "ok:main-branch-affordance" ]; then
    ok "arm 4: no seed (level 0) -> main is ok"
else
    bad "arm 4: rc=$RC out=[$OUT] err=[$ERR]"
fi

# 5 — FAIL-CLOSED: a runnable binary that cannot answer the discipline question.
cat > "$W/junk-plan" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in discipline) echo "usage: nothing here"; exit 2 ;; esac
exec "$PLAN" "\$@"
EOF
chmod +x "$W/junk-plan"
hook "$ROOT" "refs/heads/x 1 refs/heads/linux-next 2" TILLANDSIAS_PLAN_BIN="$W/junk-plan"
if [ "$RC" -eq 1 ] && [ "$(first "$OUT")" = "blocked:main-branch-affordance:discipline-unanswered" ]; then
    ok "arm 5: an unanswerable discipline question -> blocked:…:discipline-unanswered, rc 1"
else
    bad "arm 5: rc=$RC out=[$OUT] err=[$ERR]"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:main-branch-affordance-fixture:$pass/$total"
    exit 0
fi
echo "fail:main-branch-affordance-fixture:$pass/$total"
exit 1
