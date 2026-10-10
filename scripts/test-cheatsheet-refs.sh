#!/usr/bin/env bash
# @trace order:1570-k4fx, spec:cheatsheet-tooling
#
# test-cheatsheet-refs.sh — scripts/lua/check-cheatsheet-refs.lua (ported from
# the .sh by 1570-k4fx) in scratch repos. Each arm exists because a weaker
# checker could pass it:
#
#   1 RESOLVES   both reference shapes (`@cheatsheet a, b` and a `## See also`
#                bullet, bare and backticked) are counted and resolve.
#   2 DANGLING   NEGATIVE CONTROL: one `@cheatsheet missing/x.md` is refused BY
#                NAME (exit 1), and the same tree with the file present passes.
#   3 NO TOOL    the check passes with an EMPTY PATH — no rg, no toolbox, no
#                anything. The .sh refused here ~20 min into a Windows gate
#                (esmeraldinha 2026-09-12) and, with rg present-but-broken,
#                passed over nothing (1138-bb5r).
#   4 SCOPE      a bullet OUTSIDE `## See also` is not a reference.
#   5 NO DIR     a tree with no cheatsheets/ is refused (exit 2), never ok.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
GUARD="$ROOT/scripts/lua/check-cheatsheet-refs.lua"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
plan_from_checkout() {
    local p
    p="$(cd "$ROOT" && resolve_plan_binary)" || return 1
    case "$p" in
        /*) printf '%s\n' "$p" ;;
        *)  printf '%s/%s\n' "$ROOT" "${p#./}" ;;
    esac
}
PLAN="$(plan_from_checkout)" || PLAN=""
if [ -z "$PLAN" ] || ! grep -qx script <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "skip:cheatsheet-refs-fixture:no-script-runner"
    exit 0
fi

mkdir -p "$ROOT/target/plan-scratch"
W="$(mktemp -d "$ROOT/target/plan-scratch/cheatsheet-refs.XXXXXX")"; trap 'rm -rf "$W"' EXIT INT TERM
GC=(-c user.email=f@f -c user.name=f -c commit.gpgsign=false)

scratch() { # scratch <dir>: a repo with three cheatsheets citing each other
    mkdir -p "$1/cheatsheets/runtime" "$1/cheatsheets/agents"
    printf '# a\n\n@cheatsheet runtime/b.md, agents/c.md\n\n## See also\n\n- runtime/b.md — bare\n- `agents/c.md` — backticked\n\n## Next\n\n- runtime/not-a-ref.md — outside See also\n' > "$1/cheatsheets/runtime/a.md"
    printf '# b\n' > "$1/cheatsheets/runtime/b.md"
    printf '# c\n' > "$1/cheatsheets/agents/c.md"
    git -C "$1" init -q
    git -C "$1" "${GC[@]}" add -A
    git -C "$1" "${GC[@]}" commit -qm seed
}
run() { # run <dir> [PATH] -> OUT, RC
    OUT="$(cd "$1" && env -u TILLANDSIAS_REPO_ROOT PATH="${2:-$PATH}" "$PLAN" script run "$GUARD" 2>&1)"; RC=$?
}

# ── 1 + 4. both shapes resolve; a bullet outside See also is not counted ────
scratch "$W/ok"
run "$W/ok"
if [ "$RC" -eq 0 ] && grep -qx 'ok:cheatsheet-refs:4' <<<"$OUT"; then
    ok "RESOLVES: two @cheatsheet paths and two See-also bullets are counted (4) and resolve"
    ok "SCOPE: the bullet under the next heading is not a reference (else the count would be 5 and it would not resolve)"
else
    bad "RESOLVES/SCOPE: rc=$RC out=$(tr '\n' ' ' <<<"$OUT")"
fi

# ── 2. a dangling reference is refused by name; present, it passes ──────────
scratch "$W/dangling"
printf '\n@cheatsheet missing/x.md\n' >> "$W/dangling/cheatsheets/agents/c.md"
run "$W/dangling"
if [ "$RC" -eq 1 ] && grep -q '^violation:cheatsheet-refs-broken:1:of:5' <<<"$OUT" \
   && grep -q 'cheatsheets/agents/c.md:3: missing/x.md' <<<"$OUT"; then
    ok "DANGLING: one unresolvable @cheatsheet is refused (exit 1) and named with its file and line"
else
    bad "DANGLING: rc=$RC out=$(tr '\n' ' ' <<<"$OUT")"
fi
mkdir -p "$W/dangling/cheatsheets/missing"; printf '# x\n' > "$W/dangling/cheatsheets/missing/x.md"
run "$W/dangling"
if [ "$RC" -eq 0 ] && grep -qx 'ok:cheatsheet-refs:5' <<<"$OUT"; then
    ok "DANGLING control: the same tree with the file present passes"
else
    bad "DANGLING control: rc=$RC out=$(tr '\n' ' ' <<<"$OUT")"
fi

# ── 3. no tool at all: an EMPTY PATH ────────────────────────────────────────
run "$W/ok" "/nonexistent-path-1570-k4fx"
if [ "$RC" -eq 0 ] && grep -qx 'ok:cheatsheet-refs:4' <<<"$OUT"; then
    ok "NO TOOL: passes with an empty PATH (no rg, no toolbox, nothing to resolve)"
else
    bad "NO TOOL: rc=$RC out=$(tr '\n' ' ' <<<"$OUT")"
fi

# ── 5. no cheatsheets/ is a refusal, never ok ───────────────────────────────
mkdir -p "$W/nodir"; printf 'x\n' > "$W/nodir/README"
git -C "$W/nodir" init -q; git -C "$W/nodir" "${GC[@]}" add -A; git -C "$W/nodir" "${GC[@]}" commit -qm seed
run "$W/nodir"
if [ "$RC" -eq 2 ] && grep -qx 'blocked:cheatsheet-refs:no-cheatsheets-dir' <<<"$OUT"; then
    ok "NO DIR: a tree with no cheatsheets/ is refused (exit 2), never reported ok"
else
    bad "NO DIR: rc=$RC out=$(tr '\n' ' ' <<<"$OUT")"
fi

echo "cheatsheet-refs-fixture: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:cheatsheet-refs-fixture:$pass"
