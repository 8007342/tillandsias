#!/usr/bin/env bash
# @trace order:851-gpb5
#
# pre-push-linux-next-merged.sh — enforce the merge half of methodology's
# pre-push gate (`pull_merge_cadence.pre_push_gate`,
# methodology/multi-host-development.yaml): non-linux-next platform branches
# MUST merge `origin/linux-next` before EVERY push.
#
# Until order 851-gpb5 the rule was stated in methodology, CLAUDE.md and two
# script comments and enforced by NO code anywhere — and the phrase "pre-push
# gate" simultaneously named `./build.sh --check` in the meta-orchestration
# skill, so the unenforced rule hid behind an enforced namesake. This guard is
# the executable half; the skill's Finalization now states the rule under its
# methodology name.
#
# SCOPE, deliberately narrower than the prose rule. The methodology text covers
# "any shared non-trunk branch" and excludes `agent/*`/`salvage/*`
# (pre_push_gate_amendment). This guard gates exactly the two named platform
# branches — refs/heads/osx-next and refs/heads/windows-next — because those
# are the refs where an unmerged push is unambiguously a breach; on transient
# shared branches the rule stays procedural rather than risk a false refusal
# that trains `--no-verify` (the failure mode the VERSION guard's history
# warns about). Widen only with a fixture case proving the new ref class.
#
# WHAT IT CANNOT SEE: whether you fetched. The check compares against the
# `origin/linux-next` your last fetch recorded, which is exactly what makes it
# immune to the fetch-window race in the methodology's race_exception — a
# sibling advancing linux-next between your fetch and your push cannot fail
# you. The fetch half of the gate stays procedural (skill Finalization).
#
# THE SUBSET EXCEPTION (order 1259-kn83; coordinator ruling 2026-09-26). The
# rule assumes a gate is fast next to trunk's landing cadence, and on a slow
# host it is not: over 24h of origin/linux-next, 78% of the gaps between CODE
# landings were shorter than one full osx-next gate (1799s), so "merge, gate,
# push" was overtaken about four times in five and never converged. A push is
# therefore ADMITTED without containing origin/linux-next when, for every path
# outside plan/ (the fragment lanes), the pushed tip's TREE is byte-identical to
# the tree of a commit that IS on origin/linux-next's first-parent line. Then
# every byte of code the push carries is code trunk already gated. Trees are
# compared, not a diff against the moving base, which can miss a file the
# branch changed and trunk later changed back. The matched commit is named.
#
# Verdict grammar (single stdout line; diagnostics on stderr):
#   ok:linux-next-merged:<n>                 n gated refs verified (0 = none gated)
#   ok:pre-push:platform-subset-of:<sha>     admitted: code identical to trunk commit <sha>
#   ok:no-linux-next-ref                     no origin/linux-next tracking ref here
#   blocked:linux-next-not-merged:<br>       exit 1 — merge origin/linux-next first
#
# Pinned by scripts/test-pre-push-linux-next-merged.sh (hermetic fixture with
# a mutation-control arm) via litmus:pre-push-linux-next-merged-shape.
#
# stdin: the git pre-push ref list, "<local ref> <local sha> <remote ref>
# <remote sha>" per line. Runs under macOS bash 3.2 — no arrays, no mapfile.

set -uo pipefail

ZERO_SHA="0000000000000000000000000000000000000000"

LINUX_NEXT="$(git rev-parse --verify --quiet refs/remotes/origin/linux-next)"
if [ -z "$LINUX_NEXT" ]; then
    # A repo with no linux-next remote ref (end-user project, hermetic
    # fixture) has nothing to merge; the gate does not apply.
    echo "ok:no-linux-next-ref"
    exit 0
fi

# subset_of <sha> — print the first commit on origin/linux-next's first-parent
# line, from its tip back to where <sha> diverged from it, whose tree equals
# <sha>'s tree outside plan/. Prints nothing (rc 1) when there is none.
subset_of() {
    local tip="$1" base cand
    base="$(git merge-base "$LINUX_NEXT" "$tip" 2>/dev/null)" || return 1
    [ -n "$base" ] || return 1
    for cand in $(git rev-list --first-parent "$LINUX_NEXT" "^$base" 2>/dev/null) "$base"; do
        if git diff --quiet "$cand" "$tip" -- . ':(exclude)plan/' 2>/dev/null; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

checked=0
subset_sha=""
while read -r _lref lsha rref _rsha; do
    [ -n "${rref:-}" ] || continue
    case "$rref" in
        refs/heads/osx-next|refs/heads/windows-next) ;;
        *) continue ;;
    esac
    # Branch deletion pushes a zero local sha; there is no tree to contain
    # anything, so the gate does not apply.
    [ "$lsha" = "$ZERO_SHA" ] && continue
    if git merge-base --is-ancestor "$LINUX_NEXT" "$lsha" 2>/dev/null; then
        checked=$((checked + 1))
    elif matched="$(subset_of "$lsha")"; then
        # 1259-kn83: no code this push carries is new to trunk.
        checked=$((checked + 1))
        subset_sha="$matched"
    else
        branch="${rref#refs/heads/}"
        {
            echo "pre-push: refused — $branch does not contain origin/linux-next"
            echo "  ($LINUX_NEXT)."
            echo "  Methodology pull_merge_cadence.pre_push_gate requires, before EVERY push"
            echo "  of a non-linux-next branch:"
            echo "      git fetch origin && git merge origin/linux-next"
            echo "  Resolve conflicts locally, re-run the local gate, then push again."
            echo "  Never --no-verify past this: an unmerged platform push is the divergence"
            echo "  hazard the rule exists to prevent (version_divergence_hazard)."
        } >&2
        echo "blocked:linux-next-not-merged:$branch"
        exit 1
    fi
done

if [ -n "$subset_sha" ]; then
    echo "ok:pre-push:platform-subset-of:$subset_sha"
    exit 0
fi
echo "ok:linux-next-merged:$checked"
exit 0
