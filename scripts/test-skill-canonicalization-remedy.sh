#!/usr/bin/env bash
# @trace order:1055-6yp8
#
# Fixture: check-skill-canonicalization.sh must judge what is COMMITTED, and its
# printed REMEDY must not damage a correct tree.
#
# WHAT IS BROKEN, measured on yolanda 2026-09-04. The check decides with
# `[ -L "$d" ]`, a WORKTREE test. On a checkout with core.symlinks=false — every
# Windows host without Developer Mode, and any host that cloned before enabling
# it — git materialises each committed symlink as a small REGULAR FILE holding
# its target text. The commit is canonical; the filesystem cannot represent it.
# So the check reported violation:harness-exclusive-skill:75 offender(s) against
# a correct tree: 5 harnesses times 15 skills, i.e. EVERY entry, which is the
# shape of an instrument failure rather than a tree that drifted.
#
# WHY THE REMEDY IS THE DANGEROUS HALF AND IS PINNED FIRST. The check prints:
#
#   REMEDY: git mv <path> skills/<name> && ln -s ../../skills/<name> <path>
#
# On the checkout that produces the false positive, skills/<name> ALREADY holds
# the canonical copy, so the `git mv` collides with it; and the `ln -s` cannot
# make a symlink on the filesystem that caused the misreport in the first place.
# An operator who trusted 75 confident violation lines and followed the printed
# fix would be moving 75 CORRECT entries. A wrong verdict costs an
# investigation; a wrong verdict with an authoritative remedy under it costs the
# tree. That is why this fixture exists before the instrument is touched.
#
# NOT THE 1049-s35z CLASS: the check fails LOUDLY. It is a check that cannot run
# on a platform the fleet targets, reported as a tree violation.
#
# ARM 4 IS THE NEGATIVE CONTROL AND IT IS THE SCORABLE HALF. A fix that simply
# stopped flagging things would pass arms 1-3 and destroy the check. Arm 4
# builds a genuinely harness-exclusive skill — a real directory in the INDEX,
# no generated marker — and requires it to be refused. Arms 1-3 say "do not red
# on a host limitation"; arm 4 says "still red on the real defect".
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNDER_TEST="$ROOT/scripts/check-skill-canonicalization.sh"
[ -f "$UNDER_TEST" ] || { echo "SKIP: check-skill-canonicalization.sh not present" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: no git(1)" >&2; exit 0; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

pass=0
fail=0
_result() { # name expected actual
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL $1: expected [$2] got [$3]" >&2
    fi
}

# A repo whose INDEX holds a symlink the WORKTREE cannot represent. This is
# built explicitly with update-index rather than by setting core.symlinks and
# hoping the host behaves: the condition under test is "index says 120000,
# worktree says regular file", and constructing it directly means the fixture
# reproduces on Linux and macOS too, not only where it was found.
build_repo() { # $1 = dir
    local r="$1"
    mkdir -p "$r/scripts" "$r/skills/hello-world" "$r/.claude/skills"
    cp "$UNDER_TEST" "$r/scripts/check-skill-canonicalization.sh"
    printf 'a canonical skill\n' > "$r/skills/hello-world/SKILL.md"
    git -C "$r" init -q
    git -C "$r" config core.symlinks false
    git -C "$r" config user.email fixture@example.invalid
    git -C "$r" config user.name fixture
    # The committed symlink: a blob holding the target, staged at mode 120000,
    # while the worktree path is the regular file git would materialise here.
    local blob
    blob="$(printf '../../skills/hello-world' | git -C "$r" hash-object -w --stdin)"
    git -C "$r" update-index --add --cacheinfo "120000,$blob,.claude/skills/hello-world"
    printf '../../skills/hello-world' > "$r/.claude/skills/hello-world"
    git -C "$r" add scripts skills >/dev/null 2>&1
    git -C "$r" commit -qm fixture >/dev/null 2>&1
}

echo "== 1055-6yp8: skill-canonicalization on a checkout that cannot make symlinks"

# ---- ARM 1: a correct tree must not be reported as a violation --------------
R1="$WORK/correct"
build_repo "$R1"
out1="$(bash "$R1/scripts/check-skill-canonicalization.sh" 2>/dev/null)"
rc1=$?
mode="$(git -C "$R1" ls-files -s .claude/skills/hello-world | awk '{print $1}')"
_result "arm1-index-really-says-symlink" "120000" "$mode"
case "$out1" in
    ok:skills-canonical:*) verdict1=ok ;;
    violation:*)           verdict1=violation ;;
    *)                     verdict1="unparsable:$out1" ;;
esac
_result "arm1-committed-symlink-is-not-a-violation" "ok" "$verdict1"
_result "arm1-exit-status" "0" "$rc1"

# ---- ARM 2: the diagnosis must describe what is actually there --------------
# The path is a regular FILE. Calling it a "real directory" sends an
# investigator looking for something that is not there.
if [ -d "$R1/.claude/skills/hello-world" ]; then kind=directory
elif [ -f "$R1/.claude/skills/hello-world" ]; then kind=file
else kind=absent; fi
_result "arm2-the-path-is-a-regular-file" "file" "$kind"
case "$out1" in
    *"real directory"*) misdiagnosed=yes ;;
    *)                  misdiagnosed=no ;;
esac
_result "arm2-does-not-call-a-file-a-directory" "no" "$misdiagnosed"

# ---- ARM 3: the remedy the check PRINTS must not be the destructive one -----
#
# 3a pins the HAZARD as a fact about git, so the reason for the guard cannot be
# lost to a later tidy-up. Measured verbatim on yolanda: because skills/<name>
# already exists as a DIRECTORY, `git mv <path> skills/<name>` does not collide
# -- git moves the source INTO it.
#
#   git mv .claude/skills/hello-world skills/hello-world   -> rc=0
#   ls skills/hello-world/  -> SKILL.md  hello-world
#
# Zero exit status, no output, harness entry deleted, stray file buried in the
# canonical skill. Across the 75 lines this check printed on a
# core.symlinks=false host, following it would delete every harness's entry and
# litter skills/ with 75 strays, silently.
#
# An earlier draft of this fixture asserted only that skills/<name>/SKILL.md
# survived. It does survive -- so that arm passed while the damage happened
# beside it. Assert the damage, not its neighbour.
R3="$WORK/remedy"
build_repo "$R3"
( cd "$R3" && git mv .claude/skills/hello-world skills/hello-world ) >/dev/null 2>&1
if [ -e "$R3/.claude/skills/hello-world" ]; then entry=present; else entry=DELETED; fi
_result "arm3a-unguarded-git-mv-IS-destructive-and-silent" "DELETED" "$entry"
if [ -e "$R3/skills/hello-world/hello-world" ]; then stray=yes; else stray=no; fi
_result "arm3a-unguarded-git-mv-buries-a-stray" "yes" "$stray"

# 3b is the one that guards the shipped text: whatever the check prints must
# carry the condition and the warning, so an operator cannot read the safe-
# looking one-liner and run it on a tree where the destination exists.
R3B="$WORK/remedy-text"
build_repo "$R3B"
mkdir -p "$R3B/.claude/skills/only-here"
printf 'hand-written\n' > "$R3B/.claude/skills/only-here/SKILL.md"
git -C "$R3B" add .claude/skills/only-here >/dev/null 2>&1
git -C "$R3B" commit -qm exclusive >/dev/null 2>&1
remedy_out="$(bash "$R3B/scripts/check-skill-canonicalization.sh" 2>/dev/null)"
case "$remedy_out" in
    *"does NOT already exist"*) guarded=yes ;;
    *)                          guarded=no ;;
esac
_result "arm3b-printed-remedy-states-the-precondition" "yes" "$guarded"
case "$remedy_out" in
    *"Never 'git mv' onto an existing directory"*) warned=yes ;;
    *)                                             warned=no ;;
esac
_result "arm3b-printed-remedy-names-the-hazard" "yes" "$warned"

# ---- ARM 4: NEGATIVE CONTROL — a real harness-exclusive skill still reds ----
R4="$WORK/genuine"
build_repo "$R4"
mkdir -p "$R4/.claude/skills/only-here"
printf 'hand-written, exclusive to one harness\n' > "$R4/.claude/skills/only-here/SKILL.md"
git -C "$R4" add .claude/skills/only-here >/dev/null 2>&1
git -C "$R4" commit -qm exclusive >/dev/null 2>&1
out4="$(bash "$R4/scripts/check-skill-canonicalization.sh" 2>/dev/null)"
case "$out4" in
    violation:harness-exclusive-skill:*) verdict4=violation ;;
    ok:*)                                verdict4=ok ;;
    *)                                   verdict4="unparsable:$out4" ;;
esac
_result "arm4-negative-control-genuine-violation-still-reds" "violation" "$verdict4"
case "$out4" in
    *only-here*) named=yes ;;
    *)           named=no ;;
esac
_result "arm4-names-the-offending-entry" "yes" "$named"

echo "PASS: $pass  FAIL: $fail"
if [ "$fail" -gt 0 ]; then
    echo "violation:skill-canonicalization-remedy:$fail arm(s) failed"
    exit 1
fi
echo "ok:skill-canonicalization-remedy:$pass arm(s)"
