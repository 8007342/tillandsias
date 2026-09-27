#!/usr/bin/env bash
# @trace plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md (order 540, reversed by 1440-w8g8)
# test-meta-orchestration-opsx-sync-merge.sh — litmus for how the
# meta-orchestration start-of-cycle flow treats launch-generated opsx dirt.
#
# Order 540 (2026-07-31) had the cycle COMMIT that dirt as a chore(opsx) sync;
# the operator reversed it on 2026-09-27 (launch dirt "should not exist").
# 1422-w3p8 stopped launches from producing it; 1440-w8g8 made the cycle refuse
# it. The file keeps its name because litmus-bindings.yaml binds it by name.
#
# Proves against a fixture repo:
#   (a) a checkout whose only dirt is a simulated newer openspec CLI
#       regeneration of the 22 opsx paths reads launch-dirt:opsx-only, rc=5 —
#       a refusal, not an ok:
#   (b) the refused cycle commits nothing: HEAD is unchanged, the 22 paths are
#       still dirty, and the startup boundary verifies byte-identical
#   (c) the dirty-start fixture with ANY non-opsx path still fails closed and
#       preserves startup bytes byte-identically
#   (d) the skill wires the deterministic checker, and NO skill, script,
#       methodology or image file tells an agent to commit launch-generated
#       opsx files
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

# ── (a) deterministic detector: launch dirt is a refusal, not an ok ────────
if verdict="$(cd "$repo" && "$CHECKER")"; then rc=0; else rc=$?; fi
[[ "$verdict" == "launch-dirt:opsx-only" && $rc -eq 5 ]] || {
    echo "FAIL(a): expected launch-dirt:opsx-only rc=5, got '$verdict' rc=$rc" >&2
    exit 1
}
echo "ok: (a) checker verdict '$verdict' rc=$rc"

# ── (b) the refused cycle commits nothing and preserves the dirt ─────────────
head_before="$(git -C "$repo" rev-parse HEAD)"
(cd "$repo" && "$GUARD" snapshot "$boundary")
(cd "$repo" && "$GUARD" verify "$boundary") | grep -q '^ok: startup worktree boundary preserved$' || {
    echo "FAIL(b): guard verify rejected the untouched startup boundary" >&2
    exit 1
}
[[ "$(git -C "$repo" rev-parse HEAD)" == "$head_before" ]] || {
    echo "FAIL(b): a commit landed on a refused cycle" >&2
    exit 1
}
[[ "$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')" == 22 ]] || {
    echo "FAIL(b): the 22 launch-dirt paths were not preserved" >&2
    git -C "$repo" status --porcelain
    exit 1
}
git -C "$repo" checkout -q -- .
echo "ok: (b) refused cycle: HEAD unchanged, launch dirt preserved"

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

# ── (d) the skill wires the checker; nothing tells an agent to commit ───────
grep -Fq 'scripts/check-opsx-generated-dirt.sh' "$ROOT/skills/meta-orchestration/SKILL.md"
grep -Fq 'launch-dirt:opsx-only' "$ROOT/skills/meta-orchestration/SKILL.md"
self="scripts/test-meta-orchestration-opsx-sync-merge.sh"
if hits="$(cd "$ROOT" && git grep -n -F -e 'chore(opsx): sync generated' -e 'git add .opencode/commands/opsx-' \
        -- skills methodology methodology.yaml scripts images ":!$self")"; then
    echo "FAIL(d): an instruction still commits launch-generated opsx files:" >&2
    printf '%s\n' "$hits" >&2
    exit 1
fi
echo "ok: (d) skill wires the checker; no instruction commits launch opsx dirt"

echo "PASS: 1440-w8g8 launch opsx dirt refused, never committed (a)-(d)"
