#!/usr/bin/env bash
# @trace spec:methodology-accountability
#
# Fixture for scripts/check-skills-single-source.sh (order 631-wpkd).
#
# The check exists because the layout rule was CLAIMED in prose and was false
# for months. A checker for that which had never been seen to fail would be the
# same mistake in a new place, so both drift directions get a negative control:
# a real directory where a symlink belongs, and a canonical skill a runtime
# cannot see. The declared-exception path gets one too, since an allowlist that
# swallows everything is how a check quietly stops checking.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-skills-single-source.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$CHECK" ] || fail "checker not found: $CHECK"

git init -q -b main "$WORK"
cd "$WORK"
git config user.email fixture@example.invalid
git config user.name Fixture
mkdir -p skills/alpha skills/beta .harnessA/skills .harnessB/skills
echo "# alpha" > skills/alpha/SKILL.md
echo "# beta" > skills/beta/SKILL.md
printf 'generated-*\n' > skills/HARNESS-SCOPED.txt
git add -A
git commit -qm base

link() { # <runtime> <skill>
    # Make a REAL symlink where the platform allows one, and fall back to the
    # placeholder file Git writes when it does not — which is exactly what the
    # two hosts this fixture runs on do (WSL: symlinks; Git Bash on Windows:
    # placeholder files). Writing only the placeholder made this fixture pass in
    # Git Bash and fail in WSL, because a `git update-index` on a sibling path
    # refreshes an entry whose recorded mode disagrees with what is on disk.
    mkdir -p "$1/skills"
    rm -rf "$1/skills/$2"
    # `ln -s` EXIT STATUS is not the test: MSYS returns 0 and copies (or, with a
    # not-yet-existing target, leaves nothing behind). Ask what actually landed.
    ln -s "../../skills/$2" "$1/skills/$2" 2>/dev/null || true
    if [ -L "$1/skills/$2" ]; then
        git update-index --add "$1/skills/$2"
    else
        rm -rf "$1/skills/$2"
        printf '../../skills/%s' "$2" > "$1/skills/$2"
        blob=$(printf '../../skills/%s' "$2" | git hash-object -w --stdin)
        git update-index --add --cacheinfo "120000,$blob,$1/skills/$2"
    fi
}

run() { SKILLS_CHECK_ROOT="$WORK" SKILLS_CHECK_RUNTIMES=".harnessA .harnessB" bash "$CHECK"; }

# --- case 1: both runtimes link both canonical skills ------------------------
for d in .harnessA .harnessB; do for s in alpha beta; do link "$d" "$s"; done; done
out="$(run)"
[ "$out" = "ok:skills-single-source:2:2" ] || fail "case 1: a correct layout must pass, got '$out'"
echo "ok: case 1 — fully symlinked layout passes"

# --- case 2 (NEGATIVE CONTROL): a real directory is a second source ----------
# This is the shape the 2026-08-09 audit found thirteen of.
mkdir -p .harnessA/skills/rogue
echo "# rogue" > .harnessA/skills/rogue/SKILL.md
# `git update-index --add <path>`, never `git add`: staging is incidental to
# what this fixture tests, and `git add` behaves differently depending on
# whether the host's git has symlink support — which made this fixture pass in
# Git Bash and fail in WSL on the same tree. Stage exactly the one path.
git update-index --add .harnessA/skills/rogue/SKILL.md
out="$(run)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 2: a real directory must be refused"
[ "$out" = "violation:second-source:.harnessA/skills/rogue" ] \
    || fail "case 2: expected the rogue entry to be named, got '$out'"
echo "ok: case 2 — a real directory where a symlink belongs is caught and named"

# --- case 3: declaring it makes it legitimate --------------------------------
# Harness-specific is allowed; UNDOCUMENTED divergence is not.
printf 'generated-*\nrogue\n' > skills/HARNESS-SCOPED.txt
git add -A
out="$(run)"
[ "$out" = "ok:skills-single-source:2:2" ] \
    || fail "case 3: a declared exception must pass, got '$out'"
echo "ok: case 3 — a declared exception is accepted"

# --- case 4 (NEGATIVE CONTROL): the other drift direction --------------------
# A canonical skill a runtime cannot see is the defect that was STILL live on
# 2026-08-13 (multihost-orchestration linked from one runtime of five).
git rm -q --cached .harnessB/skills/beta >/dev/null
out="$(run)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 4: a missing skill must be refused"
[ "$out" = "violation:missing-from-runtime:.harnessB/skills/beta" ] \
    || fail "case 4: expected the missing link to be named, got '$out'"
echo "ok: case 4 — a canonical skill missing from a runtime is caught and named"

# --- case 5: the index is the truth, not the filesystem ----------------------
# A Windows checkout without symlink support materializes links as real
# directories on disk. A filesystem test would call every entry a violation on
# exactly the host most likely to run this, so the check reads git's index.
link .harnessB beta
rm -rf .harnessB/skills/beta
mkdir -p .harnessB/skills/beta
echo "# materialized as a real dir, as Windows does" > .harnessB/skills/beta/SKILL.md
out="$(run)"
[ "$out" = "ok:skills-single-source:2:2" ] \
    || fail "case 5: a link materialized as a directory must still pass, got '$out'"
echo "ok: case 5 — committed shape wins over what the filesystem materialized"

echo "PASS: skills single source of truth (5/5)"
