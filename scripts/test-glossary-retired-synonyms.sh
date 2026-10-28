#!/usr/bin/env bash
# @trace order:1908-9q4c
#
# Fixture for scripts/check-glossary-retired-synonyms.sh (order 1908-9q4c),
# over scratch repos whose origin/linux-next is their first commit:
#
#   0. PREMISE: the scratch glossary lists "build stamp" as retired, so the
#      arms below test the check and not an empty phrase list;
#   1. an ADDED line using "build stamp" warns, naming file:line and the
#      replacement "gate stamp", and still exits 0 (advisory);
#   2. NEGATIVE CONTROL: the same phrase on an UNCHANGED base line is silent;
#   3. the canonical "gate stamp" on an added line is silent;
#   4. an untracked new file is read whole;
#   5. the real methodology/glossary.yaml yields a non-empty phrase list.
#
# PRE-FIX RESULT: FAILS — the check did not exist.
set -uo pipefail
unset TILLANDSIAS_GATE_DIFF_BASE
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-glossary-retired-synonyms.sh"
pass=0; total=6
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

[ -f "$GUARD" ] || { echo "fail:glossary-retired-synonyms-fixture:0/$total (check missing)"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "skip:glossary-retired-synonyms-fixture:no-git"; exit 0; }

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/glossary-synonyms.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# repo <name> <base content of docs/a.md> -> a scratch repo whose base holds it
repo() {
    local r="$W/$1"
    mkdir -p "$r/scripts" "$r/methodology" "$r/docs"
    cp "$GUARD" "$r/scripts/"
    printf 'glossary:\n  retired_synonyms:\n    - {phrase: build stamp, replacement: gate stamp}\n' > "$r/methodology/glossary.yaml"
    printf '%s\n' "$2" > "$r/docs/a.md"
    git -C "$r" init -q && git -C "$r" -c user.email=f@x -c user.name=f add -A \
        && git -C "$r" -c user.email=f@x -c user.name=f commit -qm base
    git -C "$r" update-ref refs/remotes/origin/linux-next HEAD
    echo "$r"
}
run() { OUT="$(cd "$1" && bash scripts/check-glossary-retired-synonyms.sh 2>&1)"; RC=$?; }

# 0 — premise: the phrase list the arms rely on is really there.
R="$(repo zero 'base line')"
if /usr/bin/grep -qF '{phrase: build stamp, replacement: gate stamp}' "$R/methodology/glossary.yaml"; then
    ok "arm 0: premise — the scratch glossary retires \"build stamp\""
else
    bad "arm 0: scratch glossary lacks the phrase"
fi

# 1 — an added retired phrase warns by file:line with the replacement, rc 0.
R="$(repo one 'base line')"
printf 'base line\nRefresh the Build Stamp after the gate.\n' > "$R/docs/a.md"
run "$R"
if [ "$RC" -eq 0 ] && /usr/bin/grep -qx 'warn:glossary-retired-synonyms:1' <<<"$OUT" \
    && /usr/bin/grep -qF 'docs/a.md:2 uses retired "build stamp"; the glossary term is "gate stamp"' <<<"$OUT"; then
    ok "arm 1: an added \"build stamp\" warns at docs/a.md:2 naming \"gate stamp\", rc 0"
else
    bad "arm 1: rc=$RC [$OUT]"
fi

# 2 — negative control: the phrase on an unchanged base line is silent.
R="$(repo two 'the old build stamp line')"
printf 'the old build stamp line\na new neutral line\n' > "$R/docs/a.md"
run "$R"
if [ "$RC" -eq 0 ] && /usr/bin/grep -q '^ok:glossary-retired-synonyms:' <<<"$OUT"; then
    ok "arm 2: a retired phrase on an unchanged line is not flagged"
else
    bad "arm 2: rc=$RC [$OUT]"
fi

# 3 — the canonical term is silent.
R="$(repo three 'base line')"
printf 'base line\nRefresh the gate stamp after the gate.\n' > "$R/docs/a.md"
run "$R"
if [ "$RC" -eq 0 ] && /usr/bin/grep -q '^ok:glossary-retired-synonyms:' <<<"$OUT"; then
    ok "arm 3: the canonical \"gate stamp\" is not flagged"
else
    bad "arm 3: rc=$RC [$OUT]"
fi

# 4 — an untracked file is read whole.
R="$(repo four 'base line')"
printf 'line one\nwrite the build stamp\n' > "$R/docs/new.md"
run "$R"
if [ "$RC" -eq 0 ] && /usr/bin/grep -qF 'docs/new.md:2 uses retired "build stamp"' <<<"$OUT"; then
    ok "arm 4: an untracked file's line is flagged"
else
    bad "arm 4: rc=$RC [$OUT]"
fi

# 5 — the real glossary parses to a non-empty phrase list.
n="$(sed -n 's/^[[:space:]]*- {phrase: \([^,]*\), replacement: \([^}]*\)}[[:space:]]*$/\1/p' "$ROOT/methodology/glossary.yaml" | wc -l)"
if [ "$n" -gt 0 ]; then
    ok "arm 5: methodology/glossary.yaml lists $n retired phrase(s)"
else
    bad "arm 5: the real glossary yields no retired phrases"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:glossary-retired-synonyms-fixture:$pass/$total"
    exit 0
fi
echo "fail:glossary-retired-synonyms-fixture:$pass/$total"
exit 1
