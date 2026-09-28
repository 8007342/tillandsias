#!/usr/bin/env bash
# @trace order:1470-v67y, spec:methodology-accountability
#
# check-refusal-affordance-added.sh — a NEW refusal must say why it refused and
# what would make it not a refusal (1247-amcu criteria 1 and 2).
#
# THE OPERATOR RULING (2026-09-17): "Errors alone are not useful, they should
# all include the 'affordance' of why this was an error, and what would make
# this not an error." The fleet is agents: a bare `violation:<token>` gives an
# agent no next action, so it either stops or invents one. Slices 1-3 convert
# scripts one at a time; this guard keeps the next bare verdict from undoing
# them, so the tree does not have to be swept twice.
#
# WHAT COUNTS AS A REFUSAL: a line that EMITS (echo / printf / say / die /
# _error / fail) a `refused:`, `blocked:` or `violation:` verdict token. A line
# that only MATCHES one (case arms, grep patterns, comments) emits nothing.
#
# WHAT COUNTS AS ITS AFFORDANCE, from $BACK lines before the verdict line to
# $WINDOW lines after it (before, because a script often prints the affordance
# and then repeats the bare token on stdout for its caller):
#   * a call to an affordance helper: any function whose name contains
#     `afford` (the fleet convention is `_afford "<why>" "<remedy>"`, printing
#     `  why:` / `  remedy:` lines — 1247-lwek, 1247-omqr); or
#   * both a why and a remedy in the text: `why` and one of `remedy`,
#     `WHAT TO DO`, `to clear`, `fix:` (case-insensitive); or
#   * `affordance-ok: <reason>` on the verdict line or the line above it, for a
#     verdict only a PROGRAM reads (a machine-to-machine token whose consumer
#     prints the affordance). The reason is required: an empty marker does not
#     count.
# An affordance names the RULE and how to find the local answer, never a
# hardcoded branch; that is a review point this guard cannot judge.
#
# DIFF-SCOPED: only lines this change ADDS (tracked and untracked scripts/*.sh,
# build.sh), so the standing corpus is not re-litigated. Fixtures
# (scripts/test-*.sh) print verdicts as EXPECTATIONS and are skipped. This
# file is NOT exempt: its own verdict carries its affordance.
#
#   ok:refusal-affordance-added:<n> checked
#   violation:refusal-affordance-added:<n>        (rc 1; each site on stderr)
#   ok:refusal-affordance-added:base-unavailable  (no base ref; nothing judged)
#
# --audit: every verdict SITE in the standing tree, one line each
#   covered <file>:<line> <token>   |   bare <file>:<line> <token>
# then `audit:refusal-affordance:covered=<c> bare=<b> sites=<n>`. PER SITE, not
# per file: a file with one good message and ten bare verdicts counts ten bare.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2
base_ref="${TILLANDSIAS_AFFORDANCE_BASE:-origin/linux-next}"
WINDOW=8
BACK=3

EMIT='(echo|printf|say|die|_error|fail|warn|log)[^#]*(refused|blocked|violation):[a-z0-9]'
TOKEN='(refused|blocked|violation):[a-z0-9][a-z0-9:_.-]*'

# covered <file> <line> -> 0 when the site at <line> carries an affordance
covered() {
    local f="$1" ln="$2" from to window prev
    from=$((ln > 1 ? ln - 1 : 1)); to=$((ln + WINDOW))
    prev="$(sed -n "${from},${ln}p" "$f")"
    if grep -qE 'affordance-ok:[[:space:]]*[^[:space:]]' <<<"$prev"; then return 0; fi
    # The window also looks BACK: a script often prints the affordance and
    # then repeats the bare token on stdout for its caller to parse.
    window="$(sed -n "$((ln > BACK ? ln - BACK : 1)),${to}p" "$f")"
    grep -qE '[A-Za-z_]*afford[A-Za-z_]*[[:space:]]' <<<"$window" && return 0
    grep -qiE 'why' <<<"$window" && grep -qiE 'remedy|what to do|to clear|fix:' <<<"$window" && return 0
    return 1
}

# emits <line text> -> 0 when the line emits a refusal verdict
emits() {
    local t="${1#"${1%%[![:space:]]*}"}"
    case "$t" in '#'*) return 1 ;; esac
    grep -qE "$EMIT" <<<"$t"
}

in_scope() {
    case "$1" in
        scripts/test-*.sh) return 1 ;;
        scripts/*.sh|build.sh) return 0 ;;
    esac
    return 1
}

if [ "${1:-}" = "--audit" ]; then
    c=0; b=0
    while IFS= read -r f; do
        in_scope "$f" || continue
        [ -f "$f" ] || continue
        while IFS=: read -r ln _; do
            [ -n "$ln" ] || continue
            line="$(sed -n "${ln}p" "$f")"
            emits "$line" || continue
            tok="$(grep -oE "$TOKEN" <<<"$line")"; tok="${tok%%$'\n'*}"
            if covered "$f" "$ln"; then c=$((c+1)); echo "covered $f:$ln $tok"
            else b=$((b+1)); echo "bare $f:$ln $tok"; fi
        done <<EOF
$(grep -nE "$EMIT" "$f" 2>/dev/null)
EOF
    done <<EOF
$(git ls-files -- 'scripts/*.sh' build.sh)
EOF
    echo "audit:refusal-affordance:covered=$c bare=$b sites=$((c+b))"
    exit 0
fi

if ! git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
    echo "ok:refusal-affordance-added:base-unavailable"
    echo "  note: base ref '$base_ref' unavailable — added-line enforcement skipped" >&2
    exit 0
fi

files="$( { git diff --name-only --diff-filter=AM "$base_ref" -- 'scripts/*.sh' build.sh 2>/dev/null
           git ls-files --others --exclude-standard -- 'scripts/*.sh' build.sh 2>/dev/null; } | sort -u)"

checked=0; violations=0
while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    in_scope "$f" || continue
    checked=$((checked + 1))
    if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        added="$(git diff -U0 "$base_ref" -- "$f" 2>/dev/null | awk '
            /^@@/ { split($3, a, ","); n = substr(a[1], 2) + 0; next }
            /^\+\+\+/ { next }
            /^\+/ { print n; n++; next }
            /^-/ { next }
        ')"
    else
        added="$(awk '{ print NR }' "$f")"
    fi
    while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        line="$(sed -n "${ln}p" "$f")"
        emits "$line" || continue
        covered "$f" "$ln" && continue
        violations=$((violations + 1))
        tok="$(grep -oE "$TOKEN" <<<"$line")"; tok="${tok%%$'\n'*}"
        {
            echo "REFUSED: $f:$ln adds a refusal with no affordance: $tok"
            echo "  why: a bare verdict tells an agent it is stuck without telling it how to stop"
            echo "       being stuck (operator ruling 2026-09-17, 1247-amcu)."
            echo "  remedy: within $WINDOW lines after it, say WHY (the rule that refused) and the"
            echo "       REMEDY (what clears it) — e.g. _afford \"<why>\" \"<remedy>\" — or, for a"
            echo "       token only a program reads, mark it: # affordance-ok: <who prints it>."
        } >&2
    done <<EOF
$added
EOF
done <<EOF
$files
EOF

if [ "$violations" -gt 0 ]; then
    echo "violation:refusal-affordance-added:$violations"
    echo "  why: each site above emits a refusal verdict with no why/remedy near it (1247-amcu)" >&2
    echo "  remedy: add the affordance each REFUSED block names, then re-run this check" >&2
    exit 1
fi
echo "ok:refusal-affordance-added:$checked checked"
exit 0
