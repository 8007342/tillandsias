#!/usr/bin/env bash
# @trace order:1908-9q4c
#
# check-glossary-retired-synonyms.sh — WARN when a change ADDS a line using a
# retired synonym from methodology/glossary.yaml, naming its replacement.
#
# WHY (1908-9q4c, operator 2026-10-27). One word carried up to seven senses
# across methodology, specs and skills ("lane", "tier", "gate"), so an agent
# reading a rule could read a different rule than its author wrote. The
# glossary gives each term one meaning; this check keeps new text on it.
#
# ADVISORY: it always exits 0. Old lines are never re-litigated and there is
# no repo-wide rewrite; only lines this change ADDS (tracked and untracked
# .md/.yaml/.yml/.sh files) are read. The glossary itself and the audit note
# quote the retired phrases by design and are skipped.
#
#   ok:glossary-retired-synonyms:<n> checked
#   warn:glossary-retired-synonyms:<n>          (each site on stderr; rc 0)
#   ok:glossary-retired-synonyms:base-unavailable
#   ok:glossary-retired-synonyms:no-glossary
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 0
base_ref="${TILLANDSIAS_GLOSSARY_BASE:-${TILLANDSIAS_GATE_DIFF_BASE:-origin/linux-next}}"
GLOSSARY=methodology/glossary.yaml

if [ ! -f "$GLOSSARY" ]; then
    echo "ok:glossary-retired-synonyms:no-glossary"
    exit 0
fi
if ! git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
    echo "ok:glossary-retired-synonyms:base-unavailable"
    echo "  note: base ref '$base_ref' unavailable — added-line check skipped" >&2
    exit 0
fi

# "phrase<TAB>replacement" from the retired_synonyms list's flow mappings.
pairs="$(sed -n 's/^[[:space:]]*- {phrase: \([^,]*\), replacement: \([^}]*\)}[[:space:]]*$/\1\t\2/p' "$GLOSSARY")"
[ -n "$pairs" ] || { echo "ok:glossary-retired-synonyms:0 checked"; exit 0; }

files="$( { git diff --name-only --diff-filter=AM "$base_ref" -- '*.md' '*.yaml' '*.yml' '*.sh' 2>/dev/null
           git ls-files --others --exclude-standard -- '*.md' '*.yaml' '*.yml' '*.sh' 2>/dev/null; } | sort -u)"

checked=0; warnings=0
while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    case "$f" in
        "$GLOSSARY"|plan/issues/glossary-vocabulary-audit-*|scripts/check-glossary-retired-synonyms.sh|scripts/test-glossary-retired-synonyms.sh) continue ;;
    esac
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
    [ -n "$added" ] || continue
    while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        line="$(sed -n "${ln}p" "$f")"
        while IFS="$(printf '\t')" read -r phrase replacement; do
            [ -n "$phrase" ] || continue
            /usr/bin/grep -qiwF -- "$phrase" <<<"$line" || continue
            warnings=$((warnings + 1))
            echo "WARN: $f:$ln uses retired \"$phrase\"; the glossary term is \"$replacement\" (methodology/glossary.yaml)" >&2
        done <<EOF
$pairs
EOF
    done <<EOF
$added
EOF
done <<EOF
$files
EOF

if [ "$warnings" -gt 0 ]; then
    echo "warn:glossary-retired-synonyms:$warnings"
    echo "  advisory: new lines should use the glossary term (1908-9q4c); nothing is refused" >&2
    exit 0
fi
echo "ok:glossary-retired-synonyms:$checked checked"
exit 0
