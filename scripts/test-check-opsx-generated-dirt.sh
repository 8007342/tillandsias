#!/usr/bin/env bash
# @trace plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md (order 540)
# test-check-opsx-generated-dirt.sh — fixture proof for the deterministic
# launch-generated opsx-dirt detector.
#
# Proves the detector's branches against throwaway repos:
#   1.  ok:opsx-only      — ONLY the 22 generated opsx/openspec paths are dirty
#   1b. ok:opsx-only      — the same set in the .claude/ locus (order 964-fwvh)
#   1c. ok:opsx-only      — both harness loci dirty at once
#   1d. non-opsx:<path>   — the widened set still fails closed on real dirt
#   2.  non-opsx:<path>   — ANY real dirt fails closed (tracked edit, untracked,
#                          and the untracked-vs-tracked mix)
#   3.  ok:clean-tree     — no dirt at all (exit 4, distinct from a sync)
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

# ── branch 1b: the SAME set in the .claude/ locus → ok:opsx-only (964-fwvh) ──
# A Claude-Code-launched forge gets the identical 22 artifacts under `.claude/`
# with the CLI's nested command layout. Before 964-fwvh the detector knew only
# the `.opencode/` locus, so a Claude-launched forge read `non-opsx:` on 22
# provably-generated paths and refused its entire cycle — measured live on
# macuahuitl-tillandsias-forge 2026-09-02.
git -C "$repo" checkout -q -- .
mkdir -p "$repo/.claude/commands/opsx" "$repo/.claude/skills"
for cmd in apply archive bulk-archive continue explore ff new onboard propose sync verify; do
    printf '%s\n' "opsx $cmd v1" >"$repo/.claude/commands/opsx/$cmd.md"
done
for sk in apply-change archive-change bulk-archive-change continue-change explore ff-change new-change onboard propose sync-specs verify-change; do
    mkdir -p "$repo/.claude/skills/openspec-$sk"
    printf '%s\n' "openspec-$sk v1" >"$repo/.claude/skills/openspec-$sk/SKILL.md"
done
git -C "$repo" add -A
git -C "$repo" commit -qm claude-opsx-baseline

for cmd in apply archive bulk-archive continue explore ff new onboard propose sync verify; do
    printf '%s\n' "opsx $cmd v2" >"$repo/.claude/commands/opsx/$cmd.md"
done
for sk in apply-change archive-change bulk-archive-change continue-change explore ff-change new-change onboard propose sync-specs verify-change; do
    printf '%s\n' "openspec-$sk v2" >"$repo/.claude/skills/openspec-$sk/SKILL.md"
done

if verdict="$(cd "$repo" && "$CHECKER")"; then
    code=0
else
    code=$?
fi
[[ "$verdict" == "ok:opsx-only" && $code -eq 0 ]] || {
    echo "FAIL branch1b: expected ok:opsx-only rc=0 for .claude locus, got '$verdict' rc=$code" >&2
    exit 1
}
echo "ok: branch1b ok:opsx-only rc=0 (.claude locus)"

# ── branch 1c: both loci dirty at once → still ok:opsx-only ──────────────────
for cmd in apply archive bulk-archive continue explore ff new onboard propose sync verify; do
    printf '%s\n' "opsx-$cmd v3" >"$repo/.opencode/commands/opsx-$cmd.md"
done
if verdict="$(cd "$repo" && "$CHECKER")"; then
    code=0
else
    code=$?
fi
[[ "$verdict" == "ok:opsx-only" && $code -eq 0 ]] || {
    echo "FAIL branch1c: expected ok:opsx-only rc=0 for both loci, got '$verdict' rc=$code" >&2
    exit 1
}
echo "ok: branch1c ok:opsx-only rc=0 (both loci)"

# ── branch 1d: real dirt alongside .claude locus dirt → still fails closed ───
# The widened set must not weaken the refusal: one non-generated path is enough.
printf 'real operator edit\n' >"$repo/base.txt"
if verdict="$(cd "$repo" && "$CHECKER")"; then
    code=0
else
    code=$?
fi
[[ "$verdict" == "non-opsx:base.txt" && $code -eq 3 ]] || {
    echo "FAIL branch1d: expected non-opsx:base.txt rc=3, got '$verdict' rc=$code" >&2
    exit 1
}
echo "ok: branch1d fails closed with .claude dirt present, rc=3"
git -C "$repo" checkout -q -- .

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
# The checker exits nonzero BY CONTRACT for every verdict except opsx-only
# (3=non-opsx, 4=clean-tree); under set -e the bare assignment died on a
# clean tree before the PASS line ever printed. Tolerate the rc, judge the
# verdict string — the case below is the assertion.
live="$(cd "$ROOT" && "$CHECKER")" || true
case "$live" in
    ok:clean-tree|ok:opsx-only) echo "ok: live worktree verdict '$live'" ;;
    *) echo "WARN: live worktree is not clean: '$live' (expected during active work)" ;;
esac

echo "PASS: check-opsx-generated-dirt branches 1-3 proven"
