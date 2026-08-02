#!/usr/bin/env bash
# @trace plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md (order 540)
# test-meta-orchestration-opsx-sync-merge.sh — litmus for the generated opsx
# sync-merge path through the real meta-orchestration start-of-cycle flow.
#
# Proves order-540 exit criteria against a fixture repo:
#   (a) a checkout whose only dirt is a simulated newer openspec CLI
#       regeneration of the 22 opsx paths does NOT get refused
#   (b) the chore(opsx): sync commit lands on the canonical branch (local), and
#       the boundary is re-anchored so the final guard verify passes
#   (c) the dirty-start fixture with ANY non-opsx path still fails closed and
#       preserves startup bytes byte-identically
#   (d) the skill wires the deterministic checker (not prose judgment)
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
GUARD="$ROOT/scripts/meta-orchestration-worktree-guard.sh"
CHECKER="$ROOT/scripts/check-opsx-generated-dirt.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/meta-orchestration-opsx-merge.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

repo="$WORK/repo"
boundary="$WORK/boundary"
mkdir -p "$repo"
git -C "$repo" init -q -b linux-next
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
mkdir -p "$repo/.opencode/commands"
for sk in apply-change archive-change bulk-archive-change continue-change explore ff-change new-change onboard propose sync-specs verify-change; do
    mkdir -p "$repo/.opencode/skills/openspec-$sk"
done
printf 'base\n' >"$repo/base.txt"

# ── seed the 22 opsx/openspec paths at v1 (matching the order-540 set) ───────
for cmd in apply archive bulk-archive continue explore ff new onboard propose sync verify; do
    printf 'opsx-%s v1\n' "$cmd" >"$repo/.opencode/commands/opsx-$cmd.md"
done
for sk in apply-change archive-change bulk-archive-change continue-change explore ff-change new-change onboard propose sync-specs verify-change; do
    printf 'openspec-%s v1\n' "$sk" >"$repo/.opencode/skills/openspec-$sk/SKILL.md"
done
git -C "$repo" add -A
git -C "$repo" commit -qm baseline

# ── simulate a NEWER openspec CLI regeneration: all 22 paths dirtied ─────────
for cmd in apply archive bulk-archive continue explore ff new onboard propose sync verify; do
    printf 'opsx-%s v2\n' "$cmd" >"$repo/.opencode/commands/opsx-$cmd.md"
done
for sk in apply-change archive-change bulk-archive-change continue-change explore ff-change new-change onboard propose sync-specs verify-change; do
    printf 'openspec-%s v2\n' "$sk" >"$repo/.opencode/skills/openspec-$sk/SKILL.md"
done

# ── (a) deterministic detector: opsx-only is NOT a refusal ───────────────────
verdict="$(cd "$repo" && "$CHECKER")"
[[ "$verdict" == "ok:opsx-only" ]] || {
    echo "FAIL(a): expected ok:opsx-only, got '$verdict'" >&2
    exit 1
}
echo "ok: (a) checker verdict '$verdict'"

# ── start-of-cycle snapshot, then sync-merge + re-anchor ─────────────────────
(cd "$repo" && "$GUARD" snapshot "$boundary")
git -C "$repo" add .opencode/commands/opsx-*.md .opencode/skills/openspec-*/
git -C "$repo" commit -qm "chore(opsx): sync generated openspec commands and skills"
(cd "$repo" && "$GUARD" re-snapshot "$boundary")

# ── (b) chore(opsx) landed on canonical branch; verify passes after re-anchor ─
git -C "$repo" log -1 --format='%s' | grep -q '^chore(opsx): sync' || {
    echo "FAIL(b): chore(opsx) commit missing" >&2
    exit 1
}
[[ "$(git -C "$repo" status --porcelain)" == "" ]] || {
    echo "FAIL(b): worktree not clean after sync-merge" >&2
    git -C "$repo" status --porcelain
    exit 1
}
(cd "$repo" && "$GUARD" verify "$boundary") | grep -q '^ok: startup worktree boundary preserved$' || {
    echo "FAIL(b): guard verify rejected re-anchored boundary" >&2
    exit 1
}
echo "ok: (b) chore(opsx) on linux-next + re-anchored verify passes"

# ── (c) non-opsx dirt still fails closed, byte-identical preservation ────────
printf 'operator tracked edit\n' >"$repo/base.txt"
tracked_before="$(git -C "$repo" hash-object --no-filters -- base.txt)"
boundary2="$WORK/boundary2"
(cd "$repo" && "$GUARD" snapshot "$boundary2")
printf 'preflight diagnostic only\n' >"$boundary2/tmp/probe.log"
(cd "$repo" && "$GUARD" verify "$boundary2") | grep -q '^ok: startup worktree boundary preserved$'
if verdict2="$(cd "$repo" && "$CHECKER")"; then
    verdict2rc=0
else
    verdict2rc=$?
fi
[[ "$verdict2" == "non-opsx:base.txt" && $verdict2rc -eq 3 ]] || {
    echo "FAIL(c): expected non-opsx:base.txt rc=3, got '$verdict2' rc=$verdict2rc" >&2
    exit 1
}
printf 'tampered during blocked exit\n' >"$repo/base.txt"
if (cd "$repo" && "$GUARD" verify "$boundary2" >/dev/null 2>&1); then
    echo "FAIL(c): guard accepted changed startup bytes" >&2
    exit 1
fi
printf 'operator tracked edit\n' >"$repo/base.txt"
(cd "$repo" && "$GUARD" verify "$boundary2" >/dev/null)
[[ "$(git -C "$repo" hash-object --no-filters -- base.txt)" == "$tracked_before" ]]
echo "ok: (c) non-opsx dirt refuses closed and preserves bytes"

# ── (d) the skill wires the deterministic checker ────────────────────────────
grep -Fq 'scripts/check-opsx-generated-dirt.sh' "$ROOT/skills/meta-orchestration/SKILL.md"
grep -Fq 'chore(opsx): sync generated openspec commands and skills' "$ROOT/skills/meta-orchestration/SKILL.md"
grep -Fq 're-snapshot' "$ROOT/skills/meta-orchestration/SKILL.md"
grep -Fq 're-snapshot' "$ROOT/scripts/meta-orchestration-worktree-guard.sh"
echo "ok: (d) skill wires deterministic checker + re-anchor"

echo "PASS: order-540 opsx sync-merge exit criteria (a)-(d)"
