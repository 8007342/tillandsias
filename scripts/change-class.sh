#!/usr/bin/env bash
# @trace order:765-xpct, spec:ci-release
#
# change-class.sh — the change-class set for THIS tree, computed once, and the
# integration tier that follows from it. SOURCE this; it defines functions and
# runs nothing.
#
# ═══ THE APPROVAL THIS RESTS ON, AND WHAT IT DOES NOT COVER ═══
#
# Reducing how much gate runs before code reaches trunk is a scope reduction,
# and this row's fifth exit criterion makes it the symmetric twin of
# bar_raise_governance (methodology/convergence.yaml:425): the loop must not
# self-enact it. The operator approved BOTH LIGHT AND SCOPED on 2026-09-20,
# recorded verbatim on 765-xpct (yoga's record at 302118c56, macuahuitl's
# independently from their own channel). The approval is ONE criterion of six.
# Nothing here is licensed by it alone — the fail-closed paths below are the
# other five, and a reader who finds this file skipping a gate it should not
# should treat the approval as irrelevant to that bug.
#
# ═══ IT DOES NOT OWN A TAXONOMY ═══
#
# gate_stamp_classify_path (scripts/gate-stamp.sh:167, order 765-dt8h) is
# already TOTAL, and its final `*)` arm exists so "an unclassified path fails
# closed instead of silently belonging to whatever a scoped gate claimed" —
# this row's requirement, written down before this row. So the classes come
# from `gate-stamp.sh classify`, which takes paths on stdin and emits the sorted
# unique set in ONE spawn. A second classifier here would eventually disagree
# with that one about a single path, and two taxonomies disagreeing is worse
# than either alone.
#
# ═══ THE FAILURE DIRECTION IS INVERTED FROM THE PLAN-ONLY LANE'S ═══
#
# The plan-only lane (668-2xeh, 1056-5344) also classifies a diff, and when it
# is wrong it lands ungated ledger appends. When THIS is wrong it ships unbuilt
# Rust. So every uncertainty raises the tier and none lowers it: an unknown path
# classifies `other` and `other` is FULL by construction, a base ref that cannot
# be resolved is FULL, and a tree whose last full gate is stale refuses to skip
# at all.
set -uo pipefail

CHANGE_CLASS_ROOT="${CHANGE_CLASS_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CHANGE_CLASS_TRUNK="${TILLANDSIAS_TRUNK_BRANCH:-linux-next}"
CHANGE_CLASS_REMOTE="${TILLANDSIAS_CHANGE_CLASS_REMOTE:-origin}"
# Where a completed FULL gate records itself. In $GIT_DIR, never the worktree:
# a marker inside the tree would be enumerated by the very diff that reads it —
# the same reason 970-7fqk keeps the stamp manifest out of the worktree.
CHANGE_CLASS_FULL_MARKER="${TILLANDSIAS_FULL_GATE_MARKER:-$(git rev-parse --absolute-git-dir 2>/dev/null || echo .)/tillandsias-last-full-gate}"
# How long a FULL run stays good enough to permit skipping. The row's criterion.
CHANGE_CLASS_FULL_MAX_AGE_S="${TILLANDSIAS_FULL_GATE_MAX_AGE_S:-86400}"

# THE TIERS, ENTIRELY IN gate-stamp's CLASSES. Written as the ALLOWED set per
# tier rather than as the forbidden one, so a class added to the taxonomy later
# is not silently admitted to a cheap tier: it will simply not be in either list
# and the tree will be FULL until someone decides otherwise. That is the right
# default for a new, unconsidered kind of file.
CHANGE_CLASS_LIGHT_SET="plan-ledger docs"
CHANGE_CLASS_SCOPED_SET="plan-ledger docs specs methodology build-scripts"

# Classes that force FULL however they arrive. build-scripts is in the SCOPED
# set above because most script edits are scoped work — but the four files that
# decide what the gate itself DOES cannot be judged by the gate they configure.
CHANGE_CLASS_SELF_PATHS="build.sh scripts/local-ci.sh scripts/run-litmus-test.sh scripts/change-class.sh"

_cc_say() { printf '%s\n' "$*"; }

# change_class_paths [base] — the paths this tree changes: the diff against the
# merge-base with the base ref, PLUS uncommitted and untracked files.
#
# WHY UNCOMMITTED AND UNTRACKED ARE IN THE SET (634-39ik's shape). The question
# is "what does this GATE RUN cover", not "what is committed". A gate runs over
# the worktree; a dirty file it never classified is a file that skipped its
# gate. Untracked especially: a new .rs nobody has added yet is invisible to
# every committed-only view and compiles all the same.
change_class_paths() {
    local base="${1:-$CHANGE_CLASS_REMOTE/$CHANGE_CLASS_TRUNK}" mb
    mb="$(git -C "$CHANGE_CLASS_ROOT" merge-base HEAD "$base" 2>/dev/null)" || return 1
    [ -n "$mb" ] || return 1
    {
        git -C "$CHANGE_CLASS_ROOT" diff --name-only "$mb" HEAD 2>/dev/null
        git -C "$CHANGE_CLASS_ROOT" diff --name-only HEAD 2>/dev/null
        git -C "$CHANGE_CLASS_ROOT" diff --name-only --cached 2>/dev/null
        git -C "$CHANGE_CLASS_ROOT" ls-files --others --exclude-standard 2>/dev/null
    } | LC_ALL=C sort -u
}

# change_class_set [base] — the class set, one per line. Empty output with a
# non-zero status means COULD NOT DETERMINE, which every caller must read as
# FULL rather than as "nothing changed". Those two look identical otherwise,
# and that is the silent-empty false negative this fleet keeps finding.
change_class_set() {
    local base="${1:-$CHANGE_CLASS_REMOTE/$CHANGE_CLASS_TRUNK}" paths
    paths="$(change_class_paths "$base")" || return 1
    [ -n "$paths" ] || { printf '\n'; return 0; }
    printf '%s\n' "$paths" | bash "$CHANGE_CLASS_ROOT/scripts/gate-stamp.sh" classify
}

# _cc_touches_self <paths> — does the change edit what decides the gate?
_cc_touches_self() {
    local p self
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        for self in $CHANGE_CLASS_SELF_PATHS; do
            [ "$p" = "$self" ] && return 0
        done
    done <<< "$1"
    return 1
}

# change_class_full_run_age_s — seconds since the last recorded FULL gate, or
# the literal "never". Never is not a number and callers must not coerce it:
# `${x:-0}` on a missing producer fabricates a favourable answer, which is a
# defect this fleet has already paid for once.
change_class_full_run_age_s() {
    local ts now
    [ -f "$CHANGE_CLASS_FULL_MARKER" ] || { printf 'never\n'; return 0; }
    ts="$(cat "$CHANGE_CLASS_FULL_MARKER" 2>/dev/null)" || { printf 'never\n'; return 0; }
    case "$ts" in ''|*[!0-9]*) printf 'never\n'; return 0 ;; esac
    now="$(date -u +%s)"
    printf '%s\n' "$((now - ts))"
}

# change_class_record_full_run — called by a FULL gate on success, and by
# nothing else. A scoped run must never write this: that would let a chain of
# scoped runs keep renewing the licence to be scoped.
change_class_record_full_run() {
    date -u +%s > "$CHANGE_CLASS_FULL_MARKER" 2>/dev/null || true
}

# change_class_tier [base] — LIGHT | SCOPED | FULL on stdout, and one evidence
# line on stderr naming WHY, with the base SHA and the last-full age. The
# evidence is not optional: a tier printed without its reason is a verdict
# nobody can check.
change_class_tier() {
    local base="${1:-$CHANGE_CLASS_REMOTE/$CHANGE_CLASS_TRUNK}"
    local mb paths classes c age tier allowed

    mb="$(git -C "$CHANGE_CLASS_ROOT" merge-base HEAD "$base" 2>/dev/null || true)"
    if [ -z "$mb" ]; then
        _cc_say FULL
        echo "change-class: FULL because the base ref '$base' could not be resolved — an unanswerable question is not an absent constraint" >&2
        return 0
    fi

    paths="$(change_class_paths "$base")" || {
        _cc_say FULL
        echo "change-class: FULL because the changed-path set could not be computed against $mb" >&2
        return 0
    }

    if [ -z "$paths" ]; then
        _cc_say LIGHT
        echo "change-class: LIGHT because nothing changed against ${mb:0:9} (empty diff, clean worktree, no untracked files)" >&2
        return 0
    fi

    if _cc_touches_self "$paths"; then
        _cc_say FULL
        echo "change-class: FULL because the change edits what decides the gate ($CHANGE_CLASS_SELF_PATHS) — a selector cannot judge its own change with itself" >&2
        return 0
    fi

    classes="$(printf '%s\n' "$paths" | bash "$CHANGE_CLASS_ROOT/scripts/gate-stamp.sh" classify)" || {
        _cc_say FULL
        echo "change-class: FULL because the classifier did not answer" >&2
        return 0
    }

    # LIGHT first, then SCOPED; a class outside a set disqualifies that tier.
    for tier in LIGHT SCOPED; do
        case "$tier" in
            LIGHT)  allowed="$CHANGE_CLASS_LIGHT_SET" ;;
            SCOPED) allowed="$CHANGE_CLASS_SCOPED_SET" ;;
        esac
        local ok=1
        while IFS= read -r c; do
            [ -n "$c" ] || continue
            local hit=1
            for a in $allowed; do [ "$c" = "$a" ] && hit=0 && break; done
            [ "$hit" -eq 0 ] || { ok=1; break; }
            ok=0
        done <<< "$classes"
        if [ "$ok" -eq 0 ]; then
            age="$(change_class_full_run_age_s)"
            if [ "$age" = "never" ]; then
                _cc_say FULL
                # `last-full=never` is a STABLE TOKEN, not prose. ARM 7 of the
                # fixture first matched on the sentence and failed against
                # correct behaviour, because a guess at wording reads exactly
                # like the absence of the property. The sentence stays for the
                # human; the token is what a checker is entitled to rely on.
                echo "change-class: FULL last-full=never classes=$(printf '%s' "$classes" | tr '\n' ',') — the classes qualify $tier, but no FULL gate has ever been recorded on this tree and a first run must be the whole one" >&2
                return 0
            fi
            if [ "$age" -gt "$CHANGE_CLASS_FULL_MAX_AGE_S" ]; then
                _cc_say FULL
                echo "change-class: FULL although the classes ($(printf '%s' "$classes" | tr '\n' ',')) qualify $tier — the last FULL gate was ${age}s ago, over the ${CHANGE_CLASS_FULL_MAX_AGE_S}s bound; a branch must not ride cheap tiers indefinitely" >&2
                return 0
            fi
            _cc_say "$tier"
            echo "change-class: $tier base=${mb:0:9} classes=$(printf '%s' "$classes" | tr '\n' ',') last-full=${age}s-ago" >&2
            return 0
        fi
    done

    _cc_say FULL
    echo "change-class: FULL base=${mb:0:9} classes=$(printf '%s' "$classes" | tr '\n' ',')" >&2
    return 0
}
