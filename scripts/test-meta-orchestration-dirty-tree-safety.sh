#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
GUARD="$ROOT/scripts/meta-orchestration-worktree-guard.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/meta-orchestration-dirty-tree.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

repo="$WORK/repo"
state="$WORK/boundary"
mkdir -p "$repo/plan/issues"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
printf 'committed\n' >"$repo/tracked.txt"
printf 'ignored.tmp\n' >"$repo/.gitignore"
git -C "$repo" add tracked.txt .gitignore
git -C "$repo" commit -qm baseline

printf 'operator tracked edit\n' >"$repo/tracked.txt"
printf 'operator untracked packet\n' >"$repo/plan/issues/operator packet.md"
tracked_before="$(git -C "$repo" hash-object --no-filters -- tracked.txt)"
untracked_before="$(git -C "$repo" hash-object --no-filters -- 'plan/issues/operator packet.md')"

(cd "$repo" && "$GUARD" snapshot "$state")

# A dirty-start blocked cycle may write disposable diagnostics only outside the
# shared checkout. It performs no checkout, restore, reset, clean, or unlink in
# the worktree before verifying the startup boundary.
printf 'preflight diagnostic only\n' >"$state/tmp/probe.log"
(cd "$repo" && "$GUARD" verify "$state")

[[ "$(git -C "$repo" hash-object --no-filters -- tracked.txt)" == "$tracked_before" ]]
[[ "$(git -C "$repo" hash-object --no-filters -- 'plan/issues/operator packet.md')" == "$untracked_before" ]]

printf 'tampered during blocked exit\n' >"$repo/tracked.txt"
if (cd "$repo" && "$GUARD" verify "$state" >/dev/null 2>&1); then
    echo "FAIL: guard accepted changed startup bytes" >&2
    exit 1
fi
printf 'operator tracked edit\n' >"$repo/tracked.txt"
(cd "$repo" && "$GUARD" verify "$state" >/dev/null)

grep -Fq 'git status --porcelain=v1 -z --untracked-files=all' "$ROOT/skills/meta-orchestration/SKILL.md"
grep -Fq 'Never run broad `git clean`, `git checkout --`' "$ROOT/skills/meta-orchestration/SKILL.md"
grep -Fq 'must never delete or restore worktree paths' "$ROOT/skills/meta-orchestration/SKILL.md"
grep -Fq 'dirty-start preflight refusal is not a work cycle' "$ROOT/skills/meta-orchestration/SKILL.md"
grep -Fq 'host/orchestrator can file it durably' "$ROOT/skills/meta-orchestration/SKILL.md"
grep -Fq 'cp -rp "$ROOT/skills" "$IMAGE_DIR/skills"' "$ROOT/scripts/build-image.sh"

echo "PASS: blocked cycle preserved startup tracked and untracked bytes"
