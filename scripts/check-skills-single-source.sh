#!/usr/bin/env bash
# @trace spec:methodology-accountability
#
# Order 631-wpkd. Canonical `skills/` is the single source of truth; every
# runtime reaches a skill through a symlink into it.
#
# WHY THIS IS A CHECK AND NOT A CONVENTION
#
# The layout section already CLAIMED this, and on 2026-08-09 an audit found it
# false: thirteen skills existed only under `.claude/skills/`, including
# `build-macos-tray` — a macOS BUILD skill that agents launched under opencode,
# codex or gemini simply did not have. What a host can do must not depend on
# which harness started it, and a claim in prose could not notice that it had
# stopped being true.
#
# It drifts in BOTH directions, which is why both are checked:
#   * a real directory where a symlink belongs = a second source of truth;
#   * a canonical skill missing from a runtime = a skill that host cannot see.
# The second was still live on 2026-08-13: `multihost-orchestration` was linked
# from .gemini ONLY, and `hello-world` from two runtimes of five.
#
# THE INDEX, NOT THE FILESYSTEM. `git ls-files -s` reports mode 120000 for a
# symlink regardless of what the working tree materialized. A Windows checkout
# without symlink support turns them into real directories on disk, so a
# filesystem test would report every entry as a violation on exactly the host
# most likely to be running this. The committed shape is the shape that matters.
#
# Declared exceptions live in skills/HARNESS-SCOPED.txt with their reason.
#
# Grammar (exactly one line on stdout):
#   ok:skills-single-source:<runtimes>:<canonical>
#   violation:second-source:<runtime>/<skill>
#   violation:missing-from-runtime:<runtime>/<skill>
#   skip:not-a-git-repo
#
# Exit 0 on ok/skip, 1 on violation.

set -uo pipefail

ROOT="${SKILLS_CHECK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" 2>/dev/null || { echo "skip:not-a-git-repo"; exit 0; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "skip:not-a-git-repo"; exit 0; }

RUNTIMES="${SKILLS_CHECK_RUNTIMES:-.claude .opencode .codex .github .gemini}"
DECL="$ROOT/skills/HARNESS-SCOPED.txt"

# ORDER 1255-rvr7, HOLE A. THE POPULATION IS ASSERTED, NOT REPORTED.
#
# This loop used to `continue` past any runtime whose skills tree was untracked,
# and the verdict printed the surviving count without pinning it. MEASURED on
# macbookair 2026-09-22, same script, only the list differing:
#   default                                   -> ok:skills-single-source:5:18  rc=0
#   ".claude .nonexistent-runtime"            -> ok:skills-single-source:1:18  rc=0
#   ".nonexistent-a .nonexistent-b"           -> ok:skills-single-source:0:18  rc=0
# The row predicted that last line; it is measured now. A guard over a population
# that accepts a population of ZERO is not a weak guard, it is not a guard —
# deleting the tree it protects would have read as green.
#
# THE DECLARATION IS THE THING ASSERTED, which is the shape this row's own
# unscoreable asks for. Pinning a fixed five would refuse any checkout that
# legitimately lacks a runtime, and whether a host may is a fleet-policy question
# two hosts cannot settle. So the expected set is DECLARED — in skills/RUNTIMES.txt
# when it exists, else the built-in list — and dropping a runtime becomes an edit
# someone makes on purpose and a reviewer sees in a diff, rather than a silence.
RUNTIME_DECL="$ROOT/skills/RUNTIMES.txt"
if [ -f "$RUNTIME_DECL" ] && [ -z "${SKILLS_CHECK_RUNTIMES:-}" ]; then
    RUNTIMES="$(grep -vE '^[[:space:]]*(#|$)' "$RUNTIME_DECL" | tr '\n' ' ')"
fi

is_declared() { # <skill>
    [ -f "$DECL" ] || return 1
    while IFS= read -r pattern; do
        case "$pattern" in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2254 — the pattern is a glob on purpose.
        case "$1" in $pattern) return 0 ;; esac
    done < "$DECL"
    return 1
}

canonical="$(git ls-files skills/ | sed 's|^skills/||' | cut -d/ -f1 | sort -u | grep -v '^HARNESS-SCOPED.txt$')"
[ -n "$canonical" ] || { echo "skip:not-a-git-repo"; exit 0; }

# ORDER 1255-rvr7, HOLES B, C AND D — RESOLVE THE TARGET, do not admire the mode.
#
# The guard asserted "is a symlink" (mode 120000) and never asked where the link
# POINTS, so three different broken trees passed a shape-only test:
#   B  a link to a stale or DIVERGENT tree — the alias-tree drift arriving
#      through the front door of the fix meant to prevent it
#   C  a DANGLING link — target absent, every canonical skill "reachable"
#      purely because nothing looked
#   D  an ABSOLUTE target — resolves on the author's host and nowhere else,
#      including inside the builder toolbox where the gate actually runs
# One rule kills all three: the target must resolve, inside this repo, to
# canonical `skills/`.
#
# READ FROM THE INDEX, NOT THE WORKTREE, which is the same discipline the rest of
# this guard already follows (1055-6yp8). `git cat-file blob` gives the TRACKED
# target — what every other host will check out — so the verdict does not depend
# on this filesystem's state, and an absolute target is caught even on the one
# host where it happens to resolve.
#
# TEXTUAL NORMALISATION, because `readlink -f` is GNU and this fleet has bash 3.2
# hosts (761-g36m). The link's directory plus the target, with `.` and `..`
# folded; a target that walks above the repo root fails the prefix test below,
# which is exactly the divergent-tree case.
_link_target_in_index() {  # <tracked link path> -> prints the tracked target
    _sha="$(git ls-files -s -- "$1" 2>/dev/null | awk '$1=="120000"{print $2}' | head -1)"
    [ -n "$_sha" ] || return 1
    git cat-file blob "$_sha" 2>/dev/null
}

_normalise() {  # <dir> <target> -> prints a repo-relative normalised path, or ABSOLUTE
    case "$2" in
        /*) printf 'ABSOLUTE'; return 0 ;;
    esac
    _n_parts=""
    for _seg in $(printf '%s/%s' "$1" "$2" | tr '/' ' '); do
        case "$_seg" in
            .|'') continue ;;
            ..) _n_parts="${_n_parts% *}" ;;
            *)  _n_parts="$_n_parts $_seg" ;;
        esac
    done
    printf '%s' "$(printf '%s' "$_n_parts" | sed 's/^ //; s/ /\//g')"
}

# <runtime dir> <tracked link path> <what it should reach>
_assert_resolves_into_canonical() {
    _t="$(_link_target_in_index "$2")" || {
        echo "violation:unresolvable-link:$2 — tracked as a symlink but its target could not be read from the index"
        exit 1
    }
    _r="$(_normalise "$(dirname "$2")" "$_t")"
    if [ "$_r" = "ABSOLUTE" ]; then
        echo "violation:absolute-link-target:$2 -> $_t — an absolute target resolves on the author's host and nowhere else, including inside the builder toolbox where the gate runs"
        exit 1
    fi
    case "$_r" in
        skills|skills/*) ;;
        *)
            echo "violation:link-leaves-canonical:$2 -> $_t (resolves to '$_r') — a runtime skills link must reach canonical skills/, or it is a second source wearing a symlink"
            exit 1 ;;
    esac
    # C — DANGLING: the resolved path must actually be tracked. A link nothing
    # looked at is the whole reason this criterion exists.
    _resolved_tracked="$(git ls-files "$_r" | head -1)"
    if [ -z "$_resolved_tracked" ]; then
        echo "violation:dangling-link:$2 -> $_t (resolves to '$_r') — nothing is tracked there, so every skill it claims to reach is unreachable"
        exit 1
    fi
}

runtime_count=0
for d in $RUNTIMES; do
    # CAPTURE FIRST, do not decide a verdict inside a pipeline (795-imz3 family,
    # caught here by check-sigpipe-verdict-pipelines-added): `git ls-files | head
    # -1 | grep -q .` lets SIGPIPE from the early-exiting head decide the
    # pipeline under pipefail, so a MATCH can surface as a failure — a runtime
    # that IS present reading as missing, which is the opposite of this fix.
    _rt_tracked="$(git ls-files "$d/skills" | head -1)"
    if [ -z "$_rt_tracked" ]; then
        # Name the declaration that ACTUALLY governs this run. Saying
        # "RUNTIMES.txt" when no such file exists would be a remedy pointing at
        # something absent, which is the defect class this milestone is about.
        if [ -f "$RUNTIME_DECL" ] && [ -z "${SKILLS_CHECK_RUNTIMES:-}" ]; then
            _decl_name="skills/RUNTIMES.txt"
        elif [ -n "${SKILLS_CHECK_RUNTIMES:-}" ]; then
            _decl_name="SKILLS_CHECK_RUNTIMES"
        else
            _decl_name="the built-in list in scripts/check-skills-single-source.sh"
        fi
        # REFUSE BY NAME rather than skip. A declared runtime with no tracked
        # skills tree is either a deletion nobody meant or a declaration nobody
        # updated, and both are things a reader must be told.
        echo "violation:runtime-missing:$d/skills — declared in $_decl_name but nothing is tracked there. Restore it, or remove it from the declaration deliberately."
        exit 1
    fi
    runtime_count=$((runtime_count + 1))

    # Direction 1: a real entry where a symlink belongs.
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        is_declared "$entry" && continue
        echo "violation:second-source:$d/skills/$entry"
        exit 1
    done <<EOF
$(git ls-files -s "$d/skills" | awk '$1!="120000"{print $4}' | sed "s|^$d/skills/||" | cut -d/ -f1 | sort -u)
EOF

    # A WHOLLY-LINKED RUNTIME TREE SATISFIES DIRECTION 2 BY CONSTRUCTION.
    # 51db2c14c (1238-u84w) collapsed .gemini/skills from per-skill symlinks to
    # a SINGLE directory symlink, so a plain `grep -r` would reach it. git then
    # tracks ONE entry -- the link itself -- and has no entries for paths
    # beneath it, so the per-skill probe below can never match and reported
    # EVERY canonical skill missing. That turned the trunk gate red for every
    # host on 2026-09-18.
    # The directory link is the STRONGEST form of the property this check
    # exists to enforce: one source, zero copies, nothing that can drift. It is
    # a pass, not an exemption.
    # The discriminator is the tracked PATH, not the entry count. "exactly one
    # tracked symlink" ALSO describes a runtime with per-skill links that is
    # missing all but one -- which is case 4 of this check's own test, the
    # negative control for the other drift direction. Only a tracked entry whose
    # path IS "$d/skills" means the whole tree is one link.
    _ds_path="$(git ls-files "$d/skills" | head -1)"
    _ds_mode="$(git ls-files -s "$d/skills" | cut -d" " -f1 | head -1)"
    if [ "$_ds_path" = "$d/skills" ] && [ "$_ds_mode" = "120000" ]; then
        # 1255-rvr7: the directory link is the STRONGEST form of the property —
        # but only if it points somewhere. Resolve it before accepting it.
        _assert_resolves_into_canonical "$d" "$d/skills" "the whole tree"
        continue
    fi

    # Direction 2: a canonical skill this runtime cannot see.
    for s in $canonical; do
        # Captured, not decided in a pipeline — same reason as above.
        _skill_entry="$(git ls-files -s "$d/skills/$s")"
        case "$_skill_entry" in
            120000*)
                # 1255-rvr7: per-skill links are resolved too, or B, C and D
                # simply move here from the directory-link path.
                _assert_resolves_into_canonical "$d" "$d/skills/$s" "$s"
                continue ;;
        esac
        is_declared "$s" && continue
        echo "violation:missing-from-runtime:$d/skills/$s"
        exit 1
    done
done

echo "ok:skills-single-source:$runtime_count:$(printf '%s\n' "$canonical" | grep -c .)"
exit 0
