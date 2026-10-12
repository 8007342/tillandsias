#!/usr/bin/env bash
# @trace order:1637-cnxq
#
# test-check-scratch-location-added.sh — the fixture for
# scripts/lua/check-scratch-location-added.lua (run through tillandsias-plan
# script run): a planted site outside the checkout
# is refused with its path and line; a site routed through
# scripts/scratch-dir.sh, a recorded exception and a comment are admitted; an
# unrecorded exception key is refused; the real tree is green at its own HEAD.
#
# THE PREMISE IS ASSERTED FIRST (arm 1): the guard must report files=1 for a
# planted file before any refusal is read, because a guard that never saw the
# file prints nothing and silence reads as "admitted". Every refusal arm then
# asserts the verdict NAMES the planted path and line, not just the exit code.
#
# The scratch repository the arms run in is made under the checkout's own
# scratch dir, through the helper this fixture exists to enforce. Planted
# refused tokens are assembled with printf from variables, so this file holds
# no mktemp in command position for the bare-mktemp guard (1619-7i9r) to
# count; the guard under test excludes this file by exact path anyway.
#
# Verdict: ok:scratch-location-fixture:<arms>   exit 0
#          FAIL: ... lines, exit 1
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
SUT="$ROOT/scripts/lua/check-scratch-location-added.lua"
PLAN_BIN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
if [ -z "$PLAN_BIN" ] || ! grep -qx script <<<"$("$PLAN_BIN" capabilities 2>/dev/null)"; then
    echo "skip:scratch-location-fixture:no-script-runner — no tillandsias-plan with \`script run\` resolves; rebuild it (cargo build --release -p tillandsias-plan)"
    exit 0
fi
HELPER="$ROOT/scripts/scratch-dir.sh"
EXC="$ROOT/scripts/portability/scratch-exceptions.txt"
[ -f "$SUT" ] || { echo "FAIL: $SUT is missing"; exit 1; }
[ -x "$HELPER" ] || { echo "FAIL: $HELPER is not executable"; exit 1; }

SCRATCH="$("$HELPER" fixtures)" || { echo "FAIL: scratch-dir.sh refused"; exit 1; }
case "$SCRATCH" in "$ROOT"/scratch/fixtures) ;; *) echo "FAIL: scratch-dir.sh printed $SCRATCH, expected $ROOT/scratch/fixtures"; exit 1 ;; esac
T="$(mktemp -d "$SCRATCH/check-scratch-location.XXXXXX")" || { echo "FAIL: cannot make the fixture dir"; exit 1; }
trap 'rm -rf "$T"' EXIT

MK=mktemp
TD=TMPDIR
WT=worktree
pass=0; fail=0
_ok()   { pass=$((pass + 1)); echo "PASS: $1"; }
_fail() { fail=$((fail + 1)); echo "FAIL: $1"; }

# One scratch repository with a committed, compliant base script.
R="$T/repo"
mkdir -p "$R/scripts/portability"
git -C "$T" init -q repo
git -C "$R" config user.email fixture@example.invalid
git -C "$R" config user.name fixture
git -C "$R" config commit.gpgsign false
cp "$EXC" "$R/scripts/portability/scratch-exceptions.txt"
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf 'root="$(cd "$(dirname "$0")/.." && pwd -P)"\n'
    printf 'echo "$root"\n'
} > "$R/scripts/base.sh"
git -C "$R" add -A
git -C "$R" commit -q -m base
BASE="$(git -C "$R" rev-parse HEAD)"

# run <planted-file-name> <content-printf-args...>: plant an untracked file
# under scripts/ and run the guard against the base commit. Output and rc land
# in $OUT and $RC. The planted file is removed afterwards.
run_planted() {
    local name="$1"; shift
    printf "$@" > "$R/scripts/$name"
    OUT="$(cd "$R" && TILLANDSIAS_REPO_ROOT="$R" TILLANDSIAS_SCRATCH_LOCATION_BASE="$BASE" "$PLAN_BIN" script run "$SUT" 2>"$T/err")"; RC=$?
    rm -f "$R/scripts/$name"
}

# ARM 1 — premise: a compliant new file is SEEN (files=1) and admitted (sites=1).
run_planted new-ok.sh 'tmp="$(%s -d "$(scripts/scratch-dir.sh fixtures)/x.XXXXXX")"\n' "$MK"
if [ "$RC" -eq 0 ] && [ "$OUT" = "ok:scratch-location-added:files=1:sites=1:exempt=0" ]; then
    _ok "arm 1: a compliant site is seen and admitted ($OUT)"
else
    _fail "arm 1: expected ok files=1 sites=1, got rc=$RC '$OUT' — the guard did not see the planted file, so no later refusal means anything"
    echo "ok:scratch-location-fixture:premise-failed"; exit 1
fi

# ARM 2 — a bare mktemp is refused, with path and line.
run_planted new-bare.sh 'set -u\nt="$(%s -d)"\n' "$MK"
case "$OUT" in
    *"violation:scratch-location-added:mktemp:scripts/new-bare.sh:2"*) [ "$RC" -eq 1 ] && _ok "arm 2: bare mktemp refused at scripts/new-bare.sh:2" || _fail "arm 2: rc=$RC, expected 1" ;;
    *) _fail "arm 2: expected violation mktemp at scripts/new-bare.sh:2, got rc=$RC '$OUT'" ;;
esac
grep -q 'remedy:' "$T/err" || _fail "arm 2: the refusal names no remedy"

# ARM 3 — a templated mktemp under ${TMPDIR:-/tmp} is refused (tmp rule after
# the mktemp rule: it is a mktemp site that does not route through scratch).
run_planted new-tmp.sh 'd="$(%s -d "${%s:-/tmp}/x.XXXXXX")"\n' "$MK" "$TD"
case "$OUT" in
    *"violation:scratch-location-added:mktemp:scripts/new-tmp.sh:1"*) _ok "arm 3: a TMPDIR-templated mktemp is refused" ;;
    *) _fail "arm 3: expected violation at scripts/new-tmp.sh:1, got rc=$RC '$OUT'" ;;
esac

# ARM 4 — a /tmp path with no mktemp is refused by the tmp rule.
run_planted new-log.sh 'log=/tmp/fixture.log\n'
case "$OUT" in
    *"violation:scratch-location-added:tmp:scripts/new-log.sh:1"*) _ok "arm 4: a literal /tmp path is refused" ;;
    *) _fail "arm 4: expected violation tmp at scripts/new-log.sh:1, got rc=$RC '$OUT'" ;;
esac

# ARM 5 — a worktree outside scratch is refused.
run_planted new-wt.sh 'git %s add --detach ../wt HEAD\n' "$WT"
case "$OUT" in
    *"violation:scratch-location-added:worktree:scripts/new-wt.sh:1"*) _ok "arm 5: a worktree outside scratch/ is refused" ;;
    *) _fail "arm 5: expected violation worktree, got rc=$RC '$OUT'" ;;
esac

# ARM 6 — a write climbing to ../ is refused; a cd resolution through .. is not.
run_planted new-parent.sh 'cd "$(dirname "$0")/.."\nmkdir -p ../agent-target\n'
case "$OUT" in
    *"violation:scratch-location-added:parent:scripts/new-parent.sh:2"*)
        case "$OUT" in *":scripts/new-parent.sh:1"*) _fail "arm 6: the cd resolution on line 1 was refused" ;; *) _ok "arm 6: mkdir ../ refused at line 2, the cd on line 1 admitted" ;; esac ;;
    *) _fail "arm 6: expected violation parent at scripts/new-parent.sh:2, got rc=$RC '$OUT'" ;;
esac

# ARM 7 — a recorded exception admits the line and is counted.
run_planted new-exempt.sh 'log=/tmp/forge.log # scratch-exception:user-runtime\n'
if [ "$RC" -eq 0 ] && [ "$OUT" = "ok:scratch-location-added:files=1:sites=0:exempt=1" ]; then
    _ok "arm 7: a recorded exception is admitted and counted"
else
    _fail "arm 7: expected ok exempt=1, got rc=$RC '$OUT'"
fi

# ARM 8 — an unrecorded exception key is refused.
run_planted new-unrec.sh 'log=/tmp/forge.log # scratch-exception:because\n'
case "$OUT" in
    *"violation:scratch-location-added:unrecorded-exception:scripts/new-unrec.sh:1"*) _ok "arm 8: an unrecorded exception key is refused" ;;
    *) _fail "arm 8: expected violation unrecorded-exception, got rc=$RC '$OUT'" ;;
esac

# ARM 9 — a comment is not a site.
run_planted new-comment.sh '# the old form was %s -d "${%s:-/tmp}/x.XXXXXX"\n' "$MK" "$TD"
if [ "$RC" -eq 0 ] && [ "$OUT" = "ok:scratch-location-added:files=1:sites=0:exempt=0" ]; then
    _ok "arm 9: a comment is not a site"
else
    _fail "arm 9: expected ok sites=0, got rc=$RC '$OUT'"
fi

# ARM 10 — an unstaged addition to a TRACKED file is refused at its real line.
printf 't="$(%s -d)"\n' "$MK" >> "$R/scripts/base.sh"
OUT="$(cd "$R" && TILLANDSIAS_REPO_ROOT="$R" TILLANDSIAS_SCRATCH_LOCATION_BASE="$BASE" "$PLAN_BIN" script run "$SUT" 2>/dev/null)"; RC=$?
git -C "$R" checkout -q -- scripts/base.sh
case "$OUT" in
    *"violation:scratch-location-added:mktemp:scripts/base.sh:5"*) _ok "arm 10: an addition to a tracked file is refused at line 5" ;;
    *) _fail "arm 10: expected violation at scripts/base.sh:5, got rc=$RC '$OUT'" ;;
esac

# ARM 11 — no added shell: ok with files=0.
OUT="$(cd "$R" && TILLANDSIAS_REPO_ROOT="$R" TILLANDSIAS_SCRATCH_LOCATION_BASE="$BASE" "$PLAN_BIN" script run "$SUT" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "ok:scratch-location-added:files=0:sites=0:exempt=0" ]; then
    _ok "arm 11: an empty change is ok with files=0"
else
    _fail "arm 11: expected ok files=0, got rc=$RC '$OUT'"
fi

# ARM 12 — a base that does not resolve is a refusal, not an ok.
OUT="$(cd "$R" && TILLANDSIAS_REPO_ROOT="$R" TILLANDSIAS_SCRATCH_LOCATION_BASE=no-such-ref "$PLAN_BIN" script run "$SUT" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 2 ] && [ "$OUT" = "refused:scratch-location-added:no-base:no-such-ref" ]; then
    _ok "arm 12: an unresolvable base is refused"
else
    _fail "arm 12: expected refused no-base rc=2, got rc=$RC '$OUT'"
fi

# ARM 13 — the real tree at its own HEAD: green (nothing added relative to HEAD
# is the trunk condition; the guard is diff-scoped, so the corpus is not flagged).
OUT="$(cd "$ROOT" && TILLANDSIAS_REPO_ROOT="$ROOT" TILLANDSIAS_SCRATCH_LOCATION_BASE=HEAD "$PLAN_BIN" script run "$SUT" 2>/dev/null)"; RC=$?
case "$OUT" in
    ok:scratch-location-added:*) [ "$RC" -eq 0 ] && _ok "arm 13: the real tree is green at HEAD ($OUT)" || _fail "arm 13: rc=$RC" ;;
    *) _fail "arm 13: expected ok on the real tree at HEAD, got rc=$RC '$OUT'" ;;
esac

# ARM 14 — the helper refuses a climbing subdir and an absolute one.
if "$HELPER" ../x >/dev/null 2>&1; then _fail "arm 14: scratch-dir.sh accepted ../x"; else _ok "arm 14: scratch-dir.sh refuses a climbing subdir"; fi
if "$HELPER" /abs >/dev/null 2>&1; then _fail "arm 14b: scratch-dir.sh accepted /abs"; else _ok "arm 14b: scratch-dir.sh refuses an absolute subdir"; fi

# ARM 15 — the canonical dir is ignored by git.
if git -C "$ROOT" check-ignore -q scratch/anything; then _ok "arm 15: scratch/ is gitignored"; else _fail "arm 15: scratch/ is not gitignored"; fi

echo "summary: pass=$pass fail=$fail"
if [ "$fail" -gt 0 ]; then
    echo "violation:scratch-location-fixture:$fail"
    exit 1
fi
echo "ok:scratch-location-fixture:$pass"
exit 0
