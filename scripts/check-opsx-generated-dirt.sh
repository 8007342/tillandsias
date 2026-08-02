#!/usr/bin/env bash
# @trace plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md (order 540)
# check-opsx-generated-dirt.sh — deterministic detector for launch-generated
# opsx/openspec skill-sync dirt.
#
# WHY: the forge image's installed @fission-ai/openspec CLI regenerates the 22
# tracked opsx/openspec command/skill paths into the checkout at every launch.
# When the image's CLI templates drift from the committed ones, those 22 paths
# come back dirty and in-forge meta-orchestration refuses the whole cycle with
# blocked: dirty-start-worktree — every cycle until an operator intervenes
# (plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md). Operator
# decision 2026-07-31: the opsx sync is INTENDED, committable, and a NORMAL part
# of meta-orchestration. This helper gives the cycle a falsifiable verdict for
# "the ONLY dirty paths are the generated opsx/openspec set" vs anything else,
# so the refusal stays fail-closed for genuinely dirty operator/sibling trees
# while the deterministic launch artifact is merged instead.
#
# Grammar (exactly one line):
#   ^(ok:|non-opsx:)([a-z0-9._/-]*)$
#     ok:        every status-visible dirty path is in the generated opsx set
#     non-opsx:  at least one dirty path is NOT in the generated opsx set
#                (a genuinely dirty operator/sibling tree — must fail closed)
#
# Exit codes:
#   0 — ok (only generated opsx dirt, and at least one dirty path present)
#   3 — non-opsx (real dirt present; do NOT treat as launch-generated sync)
#   2 — usage / infra error (worktree could not be inspected)
#   4 — ok-with-clean-tree (no dirty paths at all — nothing to sync; distinct
#       from ok so callers can skip the commit)
#
# The generated set is the exact 22-path opsx/openspec regeneration observed at
# forge launch (see the order-540 issue). It is anchored to the repo root.
set -uo pipefail

# ── generated opsx/openspec set (order 540) ─────────────────────────────────
# .opencode/commands/opsx-{apply,archive,bulk-archive,continue,explore,ff,new,onboard,propose,sync,verify}.md
# .opencode/skills/openspec-{apply-change,archive-change,bulk-archive-change,continue-change,explore,ff-change,new-change,onboard,propose,sync-specs,verify-change}/SKILL.md

OPSX_COMMANDS=(
    .opencode/commands/opsx-apply.md
    .opencode/commands/opsx-archive.md
    .opencode/commands/opsx-bulk-archive.md
    .opencode/commands/opsx-continue.md
    .opencode/commands/opsx-explore.md
    .opencode/commands/opsx-ff.md
    .opencode/commands/opsx-new.md
    .opencode/commands/opsx-onboard.md
    .opencode/commands/opsx-propose.md
    .opencode/commands/opsx-sync.md
    .opencode/commands/opsx-verify.md
)

OPSX_SKILLS=(
    .opencode/skills/openspec-apply-change/SKILL.md
    .opencode/skills/openspec-archive-change/SKILL.md
    .opencode/skills/openspec-bulk-archive-change/SKILL.md
    .opencode/skills/openspec-continue-change/SKILL.md
    .opencode/skills/openspec-explore/SKILL.md
    .opencode/skills/openspec-ff-change/SKILL.md
    .opencode/skills/openspec-new-change/SKILL.md
    .opencode/skills/openspec-onboard/SKILL.md
    .opencode/skills/openspec-propose/SKILL.md
    .opencode/skills/openspec-sync-specs/SKILL.md
    .opencode/skills/openspec-verify-change/SKILL.md
)

is_in_generated_set() {
    local path="$1"
    for candidate in "${OPSX_COMMANDS[@]}" "${OPSX_SKILLS[@]}"; do
        if [[ "$path" == "$candidate" ]]; then
            return 0
        fi
    done
    return 1
}

# ── repo detection ───────────────────────────────────────────────────────────
if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "non-opsx:not-a-git-repo"
    exit 2
fi

# ── collect dirty paths (tracked edits + untracked, respecting .gitignore) ───
mapfile -t dirty_paths < <(
    cd "$ROOT" || exit 2
    git status --porcelain=v1 -z --untracked-files=all |
        tr '\0' '\n' |
        awk 'substr($0,1,2) != "??" { $1=""; sub(/^ /, ""); print }'
)

# untracked entries carry a "?? " prefix; strip it so they join the same set
mapfile -t untracked_paths < <(
    cd "$ROOT" || exit 2
    git status --porcelain=v1 -z --untracked-files=all |
        tr '\0' '\n' |
        awk 'substr($0,1,2) == "??" { print substr($0,4) }'
)

[[ ${#dirty_paths[@]} -eq 0 && ${#untracked_paths[@]} -eq 0 ]] && {
    echo "ok:clean-tree"
    exit 4
}

# ── verdict ──────────────────────────────────────────────────────────────────
non_opsx=""
for path in "${dirty_paths[@]}" "${untracked_paths[@]}"; do
    # porcelain v1 may quote paths with special characters; strip quotes
    path="${path%\"}"
    path="${path#\"}"
    if ! is_in_generated_set "$path"; then
        if [[ -n "$non_opsx" ]]; then
            non_opsx="$non_opsx,"
        fi
        non_opsx="$non_opsx$path"
    fi
done

if [[ -n "$non_opsx" ]]; then
    echo "non-opsx:$non_opsx"
    exit 3
fi

echo "ok:opsx-only"
exit 0
