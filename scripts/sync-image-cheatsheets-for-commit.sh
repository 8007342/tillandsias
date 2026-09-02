#!/usr/bin/env bash
# @trace order:448, spec:cheatsheet-tooling, spec:default-image
# sync-image-cheatsheets-for-commit.sh — ORDER 448. Keep the tracked, derived
# forge-image cheatsheet tree in step with the authored one AT AUTHORING TIME,
# in the same commit, instead of discovering the drift at push time on someone
# else's host.
#
# WHY THIS EXISTS, and why it re-syncs rather than refuses.
#
# images/default/cheatsheets/ is a straight copy of the canonical cheatsheets/,
# and it is TRACKED on purpose (decision 2026-08-16): build.rs embeds images/
# into the binary and the end-user lane builds the forge image from that
# embedded snapshot, where no authored tree and no staging script exist.
# Untracking it would break `tillandsias --init` for every curl-installed user.
# So the "make it generated and uncommitted" half of 448's exit criteria is
# closed off by a recorded decision, and the commit-time guard is what is left.
#
# THE COST OF NOT HAVING IT, measured three times. A forge lands an authored
# cheatsheet without staging the derived copy; the v5 pre-push hook then
# refuses EVERY host's push until someone fixes forward. The author's own
# commit succeeds, so the person who created the drift is the one person who
# does not see it — it surfaces on unrelated hosts, as a push refusal about a
# file they never touched. Third measured instance 2026-09-02.
#
# RE-SYNC, NOT REFUSE. scripts/stage-image-cheatsheets.sh already prints the
# exact remedy ("--stage && git add -f images/default/cheatsheets") when it
# finds drift; a guard that refuses would print that same line and make a
# human type it. The tree is purely derived and cheap, so the honest move is
# to run it. This also keeps the pre-commit hook's stated philosophy — it
# never blocks a commit — while still closing the drift, because the commit
# that authors a cheatsheet now carries its own derived copy.
#
# NO-OP unless the commit actually touches cheatsheets/: a commit that touches
# nothing authored gets no regeneration, no staging, and no output.
#
# Grammar (exactly one line, or silence when not applicable):
#   ^(ok:cheatsheet-image-synced:[0-9]+|ok:cheatsheet-image-current|skip:[a-z-]+|warn:[a-z-]+)$
#
# Exit codes: 0 always. This runs inside a hook that must not block, and a
# failure to regenerate a derived tree is a loud warning, never a lost commit.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "skip:not-a-git-repo"; exit 0; }
cd "$ROOT" || { echo "skip:worktree-unreadable"; exit 0; }

STAGER="$ROOT/scripts/stage-image-cheatsheets.sh"

# Only act when the COMMIT touches the authored tree. --cached is the staged
# set, which is exactly what is about to become the commit.
staged_authored="$(git diff --cached --name-only --diff-filter=ACMRD -- cheatsheets/ 2>/dev/null)"
if [ -z "$staged_authored" ]; then
    echo "skip:no-authored-cheatsheet-change"
    exit 0
fi

if [ ! -x "$STAGER" ] && [ ! -r "$STAGER" ]; then
    echo "warn:stager-missing"
    echo "[cheatsheets] WARNING: this commit edits cheatsheets/ but $STAGER is missing," >&2
    echo "[cheatsheets] so the tracked images/default/cheatsheets/ copy was NOT regenerated." >&2
    echo "[cheatsheets] The v5 pre-push hook will refuse EVERY host's push until it is synced." >&2
    exit 0
fi

if ! bash "$STAGER" --stage >/dev/null 2>&1; then
    echo "warn:stage-failed"
    echo "[cheatsheets] WARNING: regenerating images/default/cheatsheets/ FAILED." >&2
    echo "[cheatsheets] This commit edits cheatsheets/, so the tracked derived copy is now stale," >&2
    echo "[cheatsheets] and the v5 pre-push hook will refuse EVERY host's push until it is synced." >&2
    echo "[cheatsheets] Remedy: scripts/stage-image-cheatsheets.sh --stage && git add -f images/default/cheatsheets" >&2
    exit 0
fi

# -f because .gitignore lists the derived tree (inert against the ~230 paths
# already tracked, but it would refuse newly-added ones without the force).
git add -f images/default/cheatsheets >/dev/null 2>&1 || true

synced="$(git diff --cached --name-only -- images/default/cheatsheets/ 2>/dev/null | wc -l | tr -d ' ')"
authored_count="$(printf '%s\n' "$staged_authored" | wc -l | tr -d ' ')"
if [ "${synced:-0}" -gt 0 ]; then
    echo "ok:cheatsheet-image-synced:$synced"
    echo "[cheatsheets] ${authored_count} authored change(s) -> ${synced} derived file(s) staged into this commit (order 448)." >&2
else
    echo "ok:cheatsheet-image-current"
fi
exit 0
