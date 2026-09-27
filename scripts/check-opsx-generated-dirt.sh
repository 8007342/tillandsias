#!/usr/bin/env bash
# @trace plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md (order 540, reversed by 1440-w8g8)
# check-opsx-generated-dirt.sh — deterministic detector for launch-generated
# opsx/openspec skill-sync dirt, which it REFUSES (order 1440-w8g8).
#
# WHY: until order 1422-w3p8, every forge launch ran the installed @latest
# @fission-ai/openspec CLI's `init` against the checkout, which regenerated the
# tracked opsx/openspec command/skill paths whenever the CLI's templates drifted
# from the committed ones, so the forge started dirty. Order 540 (2026-07-31)
# ruled that dirt INTENDED and had meta-orchestration commit it as a
# `chore(opsx): sync` change. The operator REVERSED that on 2026-09-27: the dirt
# "should not exist", a launch must land on a clean checkout. 1422-w3p8 stopped
# the launch from producing it (openspec_init_if_absent, lib-common.sh), and
# order 1440-w8g8 made this detector REFUSE it: launch-generated opsx dirt is a
# regression of 1422-w3p8 to report, never content to commit. Moving the
# generated set to a new CLI version is a deliberate `openspec update` + commit
# made by a person or packet, not by a cycle that found it dirty.
#
# This helper still names the generated set precisely, so a cycle can say
# WHICH kind of dirt it refused on (a launch regression vs operator/sibling
# work), and salvage + refuse both the same way.
#
# Grammar (exactly one line):
#   ^(ok:clean-tree|launch-dirt:opsx-only|non-opsx:[a-z0-9._/-]*)$
#     ok:clean-tree         nothing dirty
#     launch-dirt:opsx-only every dirty path is in the generated opsx set — a
#                           launch rewrote tracked files (1422-w3p8 regressed)
#     non-opsx:             at least one dirty path is NOT in the generated set
#                           (a genuinely dirty operator/sibling tree)
#
# Exit codes:
#   4 — ok:clean-tree (no dirty paths at all)
#   5 — launch-dirt:opsx-only (refuse; report the launch regression)
#   3 — non-opsx (real dirt present; refuse)
#   2 — usage / infra error (worktree could not be inspected)
# No verdict other than a clean tree is an ok: — there is no longer a dirt
# this detector licenses (order 1440-w8g8; it used to print ok:opsx-only, 0).
#
# The generated set is the 22-path opsx/openspec regeneration observed at forge
# launch, in EITHER harness locus (.opencode/ or .claude/ — see the order-540
# and order-964-fwvh issues). It is anchored to the repo root.
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

# ── the SAME generated set, in the .claude/ locus ───────────────────────────
# The openspec CLI writes its command/skill templates once per agent harness it
# detects. A forge launched under OpenCode gets the `.opencode/` set above; a
# forge launched under Claude Code gets the identical 22 artifacts under
# `.claude/`, with the CLI's Claude layout: commands nest under a per-namespace
# directory (`commands/opsx/<verb>.md`) instead of flattening to a
# `opsx-<verb>.md` filename. Same CLI, same cadence, so the same verdict must
# apply to both loci (today: launch-dirt:opsx-only, a refusal — 1440-w8g8; the
# locus was added under order 540's since-reversed commit-the-sync ruling).
# Measured on macuahuitl-tillandsias-forge 2026-09-02: 22 dirty paths, all in
# this set, `non-opsx:` verdict, cycle refused (order 964-fwvh).

CLAUDE_OPSX_COMMANDS=(
    .claude/commands/opsx/apply.md
    .claude/commands/opsx/archive.md
    .claude/commands/opsx/bulk-archive.md
    .claude/commands/opsx/continue.md
    .claude/commands/opsx/explore.md
    .claude/commands/opsx/ff.md
    .claude/commands/opsx/new.md
    .claude/commands/opsx/onboard.md
    .claude/commands/opsx/propose.md
    .claude/commands/opsx/sync.md
    .claude/commands/opsx/verify.md
)

CLAUDE_OPSX_SKILLS=(
    .claude/skills/openspec-apply-change/SKILL.md
    .claude/skills/openspec-archive-change/SKILL.md
    .claude/skills/openspec-bulk-archive-change/SKILL.md
    .claude/skills/openspec-continue-change/SKILL.md
    .claude/skills/openspec-explore/SKILL.md
    .claude/skills/openspec-ff-change/SKILL.md
    .claude/skills/openspec-new-change/SKILL.md
    .claude/skills/openspec-onboard/SKILL.md
    .claude/skills/openspec-propose/SKILL.md
    .claude/skills/openspec-sync-specs/SKILL.md
    .claude/skills/openspec-verify-change/SKILL.md
)

is_in_generated_set() {
    local path="$1"
    for candidate in \
        "${OPSX_COMMANDS[@]}" "${OPSX_SKILLS[@]}" \
        "${CLAUDE_OPSX_COMMANDS[@]}" "${CLAUDE_OPSX_SKILLS[@]}"; do
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
# bash-3.2 compatible (macOS /bin/bash): mapfile/readarray are bash-4+ builtins,
# so classify the -z porcelain records in a single while-read pass instead.
# With -z, git never quotes or escapes paths: every record is "XY <path>" with
# the path starting at byte 3, so no quote-stripping or awk munging is needed.
dirty_paths=()
untracked_paths=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ "${line:0:2}" == "??" ]]; then
        untracked_paths+=("${line:3}")
    else
        dirty_paths+=("${line:3}")
    fi
done < <(
    cd "$ROOT" || exit 2
    git status --porcelain=v1 -z --untracked-files=all | tr '\0' '\n'
)

[[ ${#dirty_paths[@]} -eq 0 && ${#untracked_paths[@]} -eq 0 ]] && {
    echo "ok:clean-tree"
    exit 4
}

# ── verdict ──────────────────────────────────────────────────────────────────
# ${arr[@]+"${arr[@]}"} guards the expansion: under bash 3.2's set -u, an
# empty array counts as unset and a bare "${arr[@]}" would abort the script.
non_opsx=""
for path in ${dirty_paths[@]+"${dirty_paths[@]}"} ${untracked_paths[@]+"${untracked_paths[@]}"}; do
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

echo "launch-dirt:opsx-only"
exit 5
