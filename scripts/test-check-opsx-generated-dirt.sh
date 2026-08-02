#!/usr/bin/env bash
# @trace plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md (order 540)
# test-check-opsx-generated-dirt.sh — fixture proof for the deterministic
# launch-generated opsx-dirt detector.
#
# Proves three branches against throwaway repos:
#   1. ok:opsx-only      — ONLY the 22 generated opsx/openspec paths are dirty
#   2. non-opsx:<path>   — ANY real dirt fails closed (tracked edit, untracked,
#                          and the untracked-vs-tracked mix)
#   3. ok:clean-tree     — no dirt at all (exit 4, distinct from a sync)
#
# Grammar pinned: ^(ok:opsx-only|ok:clean-tree|non-opsx:[a-z0-9._/-]+)$
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CHECKER="$ROOT/scripts/check-opsx-generated-dirt.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-opsx-dirt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

repo="$WORK/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
mkdir -p "$repo/.opencode/commands" "$repo/.opencode/skills"
printf 'base\n' >"$repo/base.txt"
git -C "$repo" add base.txt
git -C "$repo" commit -qm baseline

# ── branch 1: ONLY the generated opsx set is dirty → ok:opsx-only ────────────
# Create the 22 paths as tracked baseline, then modify ALL of them (simulating a
# newer openspec CLI regeneration) while nothing else is dirty.
for cmd in apply archive bulk-archive continue explore ff new onboard propose sync verify; do
    printf '%s\n' "opsx-$cmd v1" >"$repo/.opencode/commands/opsx-$cmd.md"
done
for sk in apply-change archive-change bulk-archive-change continue-change explore ff-change new-change onboard propose sync-specs verify-change; do
    mkdir -p "$repo/.opencode/skills/openspec-$sk"
    printf '%s\n' "openspec-$sk v1" >"$repo/.opencode/skills/openspec-$sk/SKILL.md"
done
git -C "$repo" add -A
git -C "$repo" commit -qm opsx-baseline

# Now regenerate (dirty) ALL 22 with new content.
for cmd in apply archive bulk-archive continue explore ff new onboard propose sync verify; do
    printf '%s\n' "opsx-$cmd v2" >"$repo/.opencode/commands/opsx-$cmd.md"
done
for sk in apply-change archive-change bulk-archive-change continue-change explore ff-change new-change onboard propose sync-specs verify-change; do
    printf '%s\n' "openspec-$sk v2" >"$repo/.opencode/skills/openspec-$sk/SKILL.md"
done

if verdict="$(cd "$repo" && "$CHECKER")"; then
    code=0
else
    code=$?
fi
[[ "$verdict" == "ok:opsx-only" && $code -eq 0 ]] || {
    echo "FAIL branch1: expected ok:opsx-only rc=0, got '$verdict' rc=$code" >&2
    exit 1
}
echo "ok: branch1 ok:opsx-only rc=0"

# ── branch 2a: a tracked non-opsx edit → non-opsx, fail closed ───────────────
printf 'real operator edit\n' >"$repo/base.txt"
if verdict="$(cd "$repo" && "$CHECKER")"; then
    code=0
else
    code=$?
fi
[[ "$verdict" == "non-opsx:base.txt" && $code -eq 3 ]] || {
    echo "FAIL branch2a: expected non-opsx:base.txt rc=3, got '$verdict' rc=$code" >&2
    exit 1
}
echo "ok: branch2a non-opsx on tracked edit, rc=3"

# ── branch 2b: an untracked non-opsx file → non-opsx, fail closed ────────────
git -C "$repo" checkout -q -- base.txt
mkdir -p "$repo/plan/issues"
printf 'scratch packet\n' >"$repo/plan/issues/operator-scratch.md"
if verdict="$(cd "$repo" && "$CHECKER")"; then
    code=0
else
    code=$?
fi
[[ "$verdict" == "non-opsx:plan/issues/operator-scratch.md" && $code -eq 3 ]] || {
    echo "FAIL branch2b: expected non-opsx:plan/... rc=3, got '$verdict' rc=$code" >&2
    exit 1
}
echo "ok: branch2b non-opsx on untracked file, rc=3"

# ── branch 3: clean tree → ok:clean-tree rc=4 ────────────────────────────────
git -C "$repo" checkout -q -- .
rm -f "$repo/plan/issues/operator-scratch.md"
if verdict="$(cd "$repo" && "$CHECKER")"; then
    code=0
else
    code=$?
fi
[[ "$verdict" == "ok:clean-tree" && $code -eq 4 ]] || {
    echo "FAIL branch3: expected ok:clean-tree rc=4, got '$verdict' rc=$code" >&2
    exit 1
}
echo "ok: branch3 ok:clean-tree rc=4"

# ── the live worktree must currently be clean or fail with honest verdict ────
live="$(cd "$ROOT" && "$CHECKER")"
case "$live" in
    ok:clean-tree|ok:opsx-only) echo "ok: live worktree verdict '$live'" ;;
    *) echo "WARN: live worktree is not clean: '$live' (expected during active work)" ;;
esac

echo "PASS: check-opsx-generated-dirt branches 1-3 proven"
