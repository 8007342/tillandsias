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

run() { SKILLS_CHECK_ROOT="$WORK" SKILLS_CHECK_RUNTIMES="${RUNTIMES_OVERRIDE:-.harnessA .harnessB}" bash "$CHECK"; }

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

# --- case 6: the whole skills tree as ONE directory symlink (1238-u84w) ------
# 51db2c14c collapsed .gemini/skills to a single directory symlink so a plain
# `grep -r` would reach it. git then tracks one entry and NOTHING beneath it, so
# the per-skill probe found every canonical skill "missing" and turned the trunk
# gate red for every host. The shape is legitimate -- it is the strongest form
# of single-source -- so it must pass.
git rm -q --cached .harnessB/skills/alpha >/dev/null 2>&1 || true
git rm -q --cached .harnessB/skills/beta  >/dev/null 2>&1 || true
rm -rf .harnessB/skills
blob=$(printf '../skills' | git hash-object -w --stdin)
git update-index --add --cacheinfo "120000,$blob,.harnessB/skills"
out="$(run)"
[ "$out" = "ok:skills-single-source:2:2" ] \
    || fail "case 6: a whole-tree directory symlink must pass, got '$out'"
echo "ok: case 6 — a runtime linked as ONE directory symlink passes"

# MUTANT, because a pass that cannot fail is not evidence: the discriminator is
# the tracked PATH. If it degraded to "exactly one tracked symlink", case 4's
# shape -- one surviving per-skill link, the rest missing -- would silently pass.
git rm -q --cached .harnessB/skills >/dev/null
link .harnessB alpha
out="$(run)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 6 mutant: one per-skill link is NOT a whole-tree link"
[ "$out" = "violation:missing-from-runtime:.harnessB/skills/beta" ] \
    || fail "case 6 mutant: expected the missing skill named, got '$out'"
echo "ok: case 6 mutant — a lone per-skill link is still held to Direction 2"


# --- case 7 (1255-rvr7): the POPULATION is asserted, not reported -------------
# MEASURED pre-fix on macbookair, same script, only the list differing:
#   ".claude .nonexistent-runtime" -> ok:skills-single-source:1:18  rc=0
#   ".nonexistent-a"               -> ok:skills-single-source:0:18  rc=0
# A guard over a population that accepts a population of ZERO is not a weak
# guard, it is not a guard: deleting the tree it protects read as green.
out="$(RUNTIMES_OVERRIDE=".harnessA .nonexistent-runtime" run)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 7: a declared runtime that does not exist must REFUSE"
case "$out" in
    violation:runtime-missing:.nonexistent-runtime/skills*) ;;
    *) fail "case 7: expected the missing runtime named, got '$out'" ;;
esac
echo "ok: case 7 — a declared runtime with no tracked skills tree is refused by name"

# The refusal must name the declaration that ACTUALLY governs the run. Saying
# "RUNTIMES.txt" when no such file exists would be a remedy pointing at
# something absent — the defect class this milestone is about, and a mistake
# this fix made in its first draft.
case "$out" in
    *"declared in SKILLS_CHECK_RUNTIMES"*) ;;
    *) fail "case 7: the refusal must name the governing declaration, got '$out'" ;;
esac
echo "ok: case 7b — the refusal names the declaration that governs this run"

# --- case 8 (1255-rvr7): an ABSOLUTE link target is refused (hole D) ----------
# Resolves on the author's host and nowhere else, including inside the builder
# toolbox where the gate actually runs. Read from the INDEX so the verdict does
# not depend on whether it happens to resolve HERE.
git rm -q --cached .harnessB/skills >/dev/null 2>&1 || true
git rm -q --cached .harnessB/skills/alpha >/dev/null 2>&1 || true
blob=$(printf '/home/someone/skills' | git hash-object -w --stdin)
git update-index --add --cacheinfo "120000,$blob,.harnessB/skills"
out="$(run)"; rc=$?
[ "$rc" -ne 0 ] || fail "case 8: an absolute link target must REFUSE"
case "$out" in
    violation:absolute-link-target:.harnessB/skills*) ;;
    *) fail "case 8: expected the absolute target named, got '$out'" ;;
esac
echo "ok: case 8 — an absolute link target is refused (hole D)"

# --- case 9 (1255-rvr7): a DIVERGENT target is refused (hole B) ---------------
# A link that satisfies "is a symlink" while pointing outside canonical skills/
# is the alias-tree drift arriving through the front door of the fix meant to
# prevent it.
git rm -q --cached .harnessB/skills >/dev/null
blob=$(printf '../other-tree' | git hash-object -w --stdin)
git update-index --add --cacheinfo "120000,$blob,.harnessB/skills"
out="$(run)"; rc=$?
[ "$rc" -ne 0 ] || fail "case 9: a link leaving canonical skills/ must REFUSE"
case "$out" in
    violation:link-leaves-canonical:.harnessB/skills*) ;;
    *) fail "case 9: expected the divergent target named, got '$out'" ;;
esac
echo "ok: case 9 — a link that leaves canonical skills/ is refused (hole B)"

# --- case 10 (1255-rvr7): a DANGLING target is refused (hole C) ---------------
# Tracked, shaped correctly, pointing at nothing — every canonical skill
# "reachable" purely because nothing looked.
git rm -q --cached .harnessB/skills >/dev/null
blob=$(printf '../skills/does-not-exist' | git hash-object -w --stdin)
git update-index --add --cacheinfo "120000,$blob,.harnessB/skills"
out="$(run)"; rc=$?
[ "$rc" -ne 0 ] || fail "case 10: a dangling link must REFUSE"
case "$out" in
    violation:dangling-link:.harnessB/skills*) ;;
    *) fail "case 10: expected the dangling target named, got '$out'" ;;
esac
echo "ok: case 10 — a dangling link is refused (hole C)"

# --- case 11 (1255-rvr7), THE CONTROL ON THE FIX: the invariant still bites ---
# A fix that merely stopped walking per-skill paths would satisfy every
# reachability arm above and quietly destroy the thing this guard exists for. So
# the ORIGINAL invariant is re-asserted after all the widening: a real SKILL.md
# under a runtime, not a link to canonical, is still a second source.
git rm -q --cached .harnessB/skills >/dev/null
blob=$(printf '../skills' | git hash-object -w --stdin)
git update-index --add --cacheinfo "120000,$blob,.harnessB/skills"
mkdir -p .harnessA/skills/gamma
echo "# a genuine second source" > .harnessA/skills/gamma/SKILL.md
git add -f .harnessA/skills/gamma/SKILL.md >/dev/null 2>&1
out="$(run)"; rc=$?
[ "$rc" -ne 0 ] || fail "case 11: a genuine second source must still REFUSE"
case "$out" in
    violation:second-source:.harnessA/skills/gamma*) ;;
    *) fail "case 11: expected the second source named, got '$out'" ;;
esac
echo "ok: case 11 — a genuine second source is still refused after the widening"


# --- case 12 (1255-rvr7): resolution applies to PER-SKILL links too -----------
# FOUND BY MUTATION, not by design: cases 8-10 all plant a bad DIRECTORY link,
# so deleting the per-skill resolution call left every arm green. Both layouts
# are supported, so both must be resolved, or holes B/C/D simply move from one
# shape to the other.
git rm -q --cached .harnessB/skills >/dev/null 2>&1 || true
git rm -q --cached .harnessA/skills/gamma/SKILL.md >/dev/null 2>&1 || true
rm -rf .harnessA/skills/gamma
for s in alpha beta; do link .harnessB "$s"; done
git rm -q --cached .harnessB/skills/alpha >/dev/null
blob=$(printf '/somewhere/else/alpha' | git hash-object -w --stdin)
git update-index --add --cacheinfo "120000,$blob,.harnessB/skills/alpha"
out="$(run)"; rc=$?
[ "$rc" -ne 0 ] || fail "case 12: a per-skill link with an absolute target must REFUSE"
case "$out" in
    violation:absolute-link-target:.harnessB/skills/alpha*) ;;
    *) fail "case 12: expected the per-skill absolute target named, got '$out'" ;;
esac
echo "ok: case 12 — per-skill links are resolved too, not only the directory link"

# ORDER 1256-f7td criterion 4. The gate's refusal must not offer
# skills/HARNESS-SCOPED.txt as the remedy for a link-shape mismatch: a skill
# that is REACHABLE is not harness-scoped, and "declare it" silences this check
# for good. Read from build.sh's skills step with comments STRIPPED, because
# the explanation beside the fix quotes the very phrase it forbids.
# PRE-FIX: FAILS — the refusal read "declare it in skills/HARNESS-SCOPED.txt or
# link it (631-wpkd)".
_skills_err="$(sed 's/[[:space:]]#.*$//; /^[[:space:]]*#/d' "$ROOT/build.sh" \
    | awk '/Checking skills have exactly one source of truth/{on=1} on&&/_error /{print; exit}')"
[ -n "$_skills_err" ] || fail "case 13: could not find the skills-step _error in build.sh (the fixture must not pass blind)"
case "$_skills_err" in
    *"declare it in skills/HARNESS-SCOPED"*) fail "case 13: the refusal still offers HARNESS-SCOPED as the remedy: $_skills_err" ;;
esac
case "$_skills_err" in
    *LINK*) ;;
    *) fail "case 13: the refusal must tell the reader to LINK the runtime tree: $_skills_err" ;;
esac
echo "ok: case 13 — the gate's refusal does not offer HARNESS-SCOPED for a link-shape mismatch"

# ORDER 1255-rvr7. DERIVED, not a literal. This printed "(7/7)" while THIRTEEN
# `ok: case` lines ran — the five arms added by this row passed and were reported
# as seven. A self-reported count that cannot move cannot tell a reader it
# measured less than it claims, and this is the SECOND instrument on this host
# with that defect today (scripts/test-script-exec-bits.sh printed 14/14 while
# seventeen scenarios ran).
#
# Counted from the `ok:` lines this run actually emitted, so adding or losing a
# case moves the number without anyone maintaining it.
_cases="$(grep -c '^echo "ok: case' "$ROOT/scripts/test-skills-single-source.sh")"
echo "PASS: skills single source of truth ($_cases/$_cases)"
