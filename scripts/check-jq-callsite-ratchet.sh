#!/usr/bin/env bash
# check-jq-callsite-ratchet.sh — order 1375-tsfu.
#
# WHY: an equivalent that is merely AVAILABLE does not become ADOPTION
# (`rust_queries:` had one adopter in 454 litmus files, 902-5bf9). This guard
# is the forcing function for `tillandsias-plan json get` (1375-rn9b): it
# counts bare jq call sites on every --check, never reds the standing debt,
# refuses a NEW site whose filter the binary already answers, warns on a new
# site outside that subset, and moves the recorded floor one way only.
#
# THE PATTERN — the one the fleet argues about from now on. A jq call site is
# `jq` (or `$JQ`, `${JQ}`, `"$JQ"`, the fast_tool spelling) in COMMAND
# POSITION followed by a flag, a quote, a dot or a `$`:
#   P1  ^[[:space:]]*(jq|"?\$\{?JQ\}?"?)[[:space:]]+(-|'|"|\.|\$)
#   P2  ^[^#]*([|;&({`!:]|[[:space:]](if|then|do|else|elif|while|until))[[:space:]]*(jq|"?\$\{?JQ\}?"?)[[:space:]]+(-|'|"|\.|\$)
#   P3  ^[[:space:]]*(if|then|do|else|elif|while|until|!)[[:space:]]+(jq|"?\$\{?JQ\}?"?)[[:space:]]+(-|'|"|\.|\$)
# A line counts once if it matches any (`grep -cE -e P1 -e P2 -e P3`).
# KNOWN NON-MATCHES, by construction: `resolve_tool jq`, `fast_tool jq`,
# `command -v jq` (jq is an ARGUMENT there, not in command position), and any
# line whose `jq` follows a `#` (comments). KNOWN LIMITS: a `#` inside a string
# before the jq hides the site; a jq spelled through another variable name is
# not seen.
#
# POPULATION: tracked *.sh under scripts/, build.sh, launch.sh and
# openspec/litmus-tests/*.yaml (their `command:` fields), excluding this
# guard and its fixture, which quote the pattern.
#
# FLOOR: scripts/portability/jq-callsite-floor.txt, `<count> <path>` lines
# sorted by path. A NEW site is a file whose count exceeds its floor line, or
# a file with no line. Which lines are new is not recorded, so for a file over
# its floor the LAST (count - floor) sites are taken as the new ones (code is
# appended far more often than prepended); a brand-new file's sites are all new.
#
#   ok:jq-callsites:<n>:floor:<f>                     no new site in the subset
#   blocked:jq-callsite-added:<file>:<filter>         new site json get answers (rc 1)
#   warn:jq-callsite-added-unsupported:<file>:<filter>  new site outside the subset
#   blocked:jq-ratchet-empty-population               nothing to count (rc 1)
#   could-not-run:jq-ratchet:no-plan-binary           a new site needs classifying, no binary (rc 3)
#
# MIGRATION IDIOMS (1375-2x4e) — the subset does NOT grow @tsv, join or
# sort_by. A row of N values is emitted with `,` on alternating lines and paired
# by POSIX `paste - -` (N=2), which gives the same <a>TAB<b> rows @tsv gave;
# ordering is `| sort -n` after the pair. Object construction is assembled from
# `json get -c` literals (already escaped) and pretty-printed through `json get .`.
#
#   --ratchet   rewrite the floor down to today's counts (never up)
#   --root DIR  scan DIR instead of the repository (fixtures)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ratchet=0
while [ $# -gt 0 ]; do
    case "$1" in
        --ratchet) ratchet=1; shift ;;
        --root) ROOT="$2"; shift 2 ;;
        *) echo "could-not-run:jq-ratchet:unknown-argument:$1"; exit 3 ;;
    esac
done
FLOOR="$ROOT/scripts/portability/jq-callsite-floor.txt"

P1='^[[:space:]]*(jq|"?\$\{?JQ\}?"?)[[:space:]]+(-|'"'"'|"|\.|\$)'
P2='^[^#]*([|;&({`!:]|[[:space:]](if|then|do|else|elif|while|until))[[:space:]]*(jq|"?\$\{?JQ\}?"?)[[:space:]]+(-|'"'"'|"|\.|\$)'
P3='^[[:space:]]*(if|then|do|else|elif|while|until|!)[[:space:]]+(jq|"?\$\{?JQ\}?"?)[[:space:]]+(-|'"'"'|"|\.|\$)'

population() {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$ROOT" ls-files -- 'scripts/*.sh' build.sh launch.sh 'openspec/litmus-tests/*.yaml'
    else
        ( cd "$ROOT" && { find scripts -type f -name '*.sh' 2>/dev/null
            for f in build.sh launch.sh; do [ -f "$f" ] && echo "$f"; done
            find openspec/litmus-tests -maxdepth 1 -type f -name '*.yaml' 2>/dev/null; } )
    fi | grep -vE '^scripts/(check|test-check)-jq-callsite-ratchet\.sh$' | sort
}

files="$(population)"
if [ -z "$files" ]; then
    echo "blocked:jq-ratchet-empty-population"
    exit 1
fi

# One grep over the population: "<path>:<count>" for every file with a site.
counts="$(cd "$ROOT" && printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -cE -e "$P1" -e "$P2" -e "$P3" /dev/null 2>/dev/null | grep -v ':0$' | grep -v '^/dev/null:' | sed 's/:\([0-9]*\)$/ \1/' | sort)"

# Join counts with the floor: "<path> <count> <floor or -1>".
floor_text=""
[ -f "$FLOOR" ] && floor_text="$(grep -vE '^[[:space:]]*(#|$)' "$FLOOR")"
# The floor goes in through the ENVIRONMENT, never `awk -v`: BSD awk rejects a
# newline in a -v value ("newline in string") where gawk and mawk accept it, so
# on macOS the join came out empty and the guard printed ok:jq-callsites:0:floor:0
# with rc 0 — a silent false green (macbookair, 2026-09-26).
joined="$(FT="$floor_text" awk '
    BEGIN { n = split(ENVIRON["FT"], L, "\n"); for (i = 1; i <= n; i++) { split(L[i], p, " "); if (p[2] != "") F[p[2]] = p[1] } }
    NF == 2 { f = ($1 in F) ? F[$1] : -1; print $1, $2, f; seen[$1] = 1 }
    END { for (k in F) if (!(k in seen)) print k, 0, F[k] }
' <<EOF
$counts
EOF
)"
# A join that lost its input is a broken instrument, not a clean tree: sites
# were counted, so the join must carry them. Refuse rather than read as ok:0.
if [ -n "$counts" ] && [ -z "$joined" ]; then
    echo "could-not-run:jq-ratchet:join-produced-nothing (counted sites vanished in the floor join)"
    exit 3
fi
total=0; floor_sum=0
while read -r path n f; do
    [ -n "$path" ] || continue
    total=$((total + n))
    [ "$f" -ge 0 ] && floor_sum=$((floor_sum + f))
done <<EOF
$joined
EOF

if [ "$ratchet" -eq 1 ]; then
    tmp="$FLOOR.tmp.$$"
    mkdir -p "$(dirname "$FLOOR")"
    {
        printf '# jq call-site floor (1375-tsfu): "<count> <path>", sorted by path.\n'
        printf '# Rewritten DOWN ONLY by scripts/check-jq-callsite-ratchet.sh --ratchet.\n'
        while read -r path n f; do
            [ -n "$path" ] || continue
            if [ "$f" -lt 0 ]; then keep=$n; elif [ "$n" -lt "$f" ]; then keep=$n; else keep=$f; fi
            [ "$keep" -gt 0 ] && printf '%s %s\n' "$keep" "$path"
        done <<EOF
$(printf '%s\n' "$joined" | sort)
EOF
    } > "$tmp" && mv "$tmp" "$FLOOR"
    echo "ok:jq-callsite-floor-rewritten:$(grep -cvE '^[[:space:]]*(#|$)' "$FLOOR")"
    exit 0
fi

# The filter of a matching line: the first single-quoted string after the jq
# token, else a bare dot-path argument.
filter_of() {
    printf '%s\n' "$1" | sed -nE "s/.*(jq|JQ\}?\"?)[[:space:]][^']*'([^']*)'.*/\2/p" | head -n 1 | grep . \
        || printf '%s\n' "$1" | sed -nE 's/.*(jq|JQ\}?"?)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(\.[^[:space:]|;)]*).*/\3/p' | head -n 1
}

PLAN=""
resolve_plan() {
    [ -n "$PLAN" ] && return 0
    # shellcheck source=scripts/plan-binary-probe.sh
    . "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh" 2>/dev/null || return 1
    PLAN="$(resolve_plan_binary 2>/dev/null)" || return 1
}

blocked=0
while read -r path n f; do
    [ -n "$path" ] || continue
    if [ "$f" -lt 0 ]; then new=$n; else new=$((n - f)); fi
    [ "$new" -gt 0 ] || continue
    if ! resolve_plan; then
        echo "could-not-run:jq-ratchet:no-plan-binary (new site in $path cannot be classified)"
        exit 3
    fi
    grep -E -e "$P1" -e "$P2" -e "$P3" "$ROOT/$path" | tail -n "$new" | while IFS= read -r line; do
        flt="$(filter_of "$line")"
        if [ -n "$flt" ] && "$PLAN" json get --parse-only "$flt" >/dev/null 2>&1; then
            echo "blocked:jq-callsite-added:$path:$flt"
            echo "  remedy: tillandsias-plan json get '$flt' (same flags, same argument order as jq)"
        else
            echo "warn:jq-callsite-added-unsupported:$path:${flt:-<no literal filter>}"
        fi
    done > "$ROOT/.jq-ratchet.$$" 2>&1
    cat "$ROOT/.jq-ratchet.$$"
    grep -q '^blocked:' "$ROOT/.jq-ratchet.$$" && blocked=1
    rm -f "$ROOT/.jq-ratchet.$$"
done <<EOF
$joined
EOF

if [ "$blocked" -eq 1 ]; then
    echo "FAIL:jq-callsites:$total:floor:$floor_sum"
    exit 1
fi
echo "ok:jq-callsites:$total:floor:$floor_sum"
exit 0
