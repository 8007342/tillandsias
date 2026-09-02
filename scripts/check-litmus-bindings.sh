#!/usr/bin/env bash
# @trace order:660-ryhn, spec:ci-release
#
# check-litmus-bindings.sh — a litmus file that is not bound never runs, and
# nothing said so.
#
# WHY (order 660-ryhn). The runner resolves tests through
# openspec/litmus-bindings.yaml; a file absent from that registry is invisible,
# and the suite prints PASS while the author's new assertions have never
# executed once. 26 files were in that state when the packet was filed —
# including security-critical ones — and the author of two of them was the
# very host that found the gap: writing the file is one act, registering it a
# separate manual one nothing prompted for. This makes the gap a CREATION-TIME
# refusal instead of a periodic archaeology dig.
#
# THE RATCHET, not a blind binding: the packet's own triage warns that binding
# all historical strays at once converts one silent problem into an
# undiagnosed red suite. So: a file carrying `phase: retired` is intentionally
# unbound and exempt; a file listed in unbound-grandfathered.txt is a KNOWN
# historical stray (bind it in small batches and shrink the list — additions
# are refused by the fixture's negative control); anything else unbound is a
# NEW stray and fails the gate the moment it is created. Dangling bindings
# (a registered name with no file behind it) fail in the other direction.
#
# Grammar (exactly one line on stdout):
#   ok:litmus-bindings:files=<n> bound=<n> retired=<n> grandfathered=<n>   exit 0
#   violation:unbound-litmus:<name>[,<name>...]                            exit 1
#   violation:dangling-binding:<name>[,<name>...]                          exit 1
#
# Seam: LITMUS_BINDINGS_ROOT points the scan at a fixture tree laid out as
# <root>/openspec/litmus-tests + <root>/openspec/litmus-bindings.yaml.
set -uo pipefail

ROOT="${LITMUS_BINDINGS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TESTS_DIR="$ROOT/openspec/litmus-tests"
BINDINGS="$ROOT/openspec/litmus-bindings.yaml"
GRANDFATHERED="$TESTS_DIR/unbound-grandfathered.txt"

[ -d "$TESTS_DIR" ] && [ -f "$BINDINGS" ] || {
    echo "violation:bindings-tree-missing"
    exit 2
}

bound="$(grep -oE 'litmus:[a-z0-9._-]+' "$BINDINGS" | sort -u)"
grand=""
[ -f "$GRANDFATHERED" ] && grand="$(grep -v '^#' "$GRANDFATHERED" | grep . | sort -u || true)"

files=0 retired=0 grandfathered=0 bound_n=0
unbound=""
on_disk=""
for f in "$TESTS_DIR"/litmus-*.yaml; do
    [ -e "$f" ] || continue
    name="$(grep -m1 '^name:' "$f" | sed 's/name: *//' | tr -d ' ')"
    [ -n "$name" ] || continue
    files=$((files + 1))
    on_disk="${on_disk}${name}"$'\n'
    # Herestrings, NEVER `printf | grep -q`: under this file's pipefail,
    # grep -q exiting at first match can SIGPIPE the printf and flip a MATCH
    # into a failed pipeline — under suite load the race fired on random
    # files each run, reporting phantom unbound/dangling names (observed
    # live on yoga 2026-08-23, three runs, three different name sets). The
    # sigpipe-verdict-pipeline lesson, one gate later.
    if grep -qxF "$name" <<< "$bound"; then
        bound_n=$((bound_n + 1))
        continue
    fi
    if grep -qE '^phase: *retired *$' "$f"; then
        retired=$((retired + 1))
        continue
    fi
    if [ -n "$grand" ] && grep -qxF "$name" <<< "$grand"; then
        grandfathered=$((grandfathered + 1))
        continue
    fi
    [ -n "$unbound" ] && unbound="$unbound,"
    unbound="$unbound$name"
done

if [ -n "$unbound" ]; then
    echo "violation:unbound-litmus:$unbound"
    {
        echo "each name above is an executable assertion NOTHING has ever run (660-ryhn)."
        echo "Bind it to its spec in openspec/litmus-bindings.yaml and RUN it, mark it"
        echo "'phase: retired' if intentionally shelved, or — for a historical stray"
        echo "only, never new work — add it to $GRANDFATHERED"
    } >&2
    exit 1
fi

dangling=""
while IFS= read -r b; do
    [ -n "$b" ] || continue
    # Herestring for the same SIGPIPE-under-pipefail reason as above.
    grep -qxF "$b" <<< "$on_disk" || {
        [ -n "$dangling" ] && dangling="$dangling,"
        dangling="$dangling$b"
    }
done <<< "$bound"
if [ -n "$dangling" ]; then
    echo "violation:dangling-binding:$dangling"
    echo "each name above is registered in litmus-bindings.yaml with NO file behind it — the suite claims coverage that cannot execute" >&2
    exit 1
fi


# ORDER 958-b36m. BOUND IS NOT RUNNABLE.
#
# Everything above answers "will anything ever run this file?". Nothing asked
# "can the runner actually run it?", and those are different questions with the
# same green light. litmus:codex-e2e-launch-parity landed 2026-09-01 keyed
# `steps:` where run-litmus-test.sh reads `critical_path:`: valid YAML (the
# 933-4gm8 gate passed it), correctly bound (this gate passed it), steps
# asserting behaviour rather than source (634-39ik passed it) — three green
# checks over a file the runner could not enter, reddening every full pre-build
# run fleet-wide for about four hours.
#
# The check ASKS THE RUNNER rather than imitating it. `--parse-only` runs the
# runner's own parse and executes nothing. A second parser here would assert
# THIS script's idea of the format and could go green while the runner refuses
# the file — strictly worse than no check, and this corpus produced two
# copied-rule divergences in one week (702-6jza D3, D4).
#
# DIFF-SCOPED, per 699-dycj: only files ADDED to the bindings registry in this
# change are gated, so a pre-existing unparseable file cannot flip the whole
# fleet red at once. The existing corpus gets an ADVISORY count instead — one
# line, never a refusal — because the corpus demonstrably carried such a file
# for four hours and whether it carries more is worth stating on every run.
RUNNER="$ROOT/scripts/run-litmus-test.sh"
BASE_REF="${TILLANDSIAS_LITMUS_BIND_BASE:-origin/linux-next}"

if [ -x "$RUNNER" ] && git -C "$ROOT" rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    # Names added to the registry in this change, mapped back to their files.
    #
    # The character class is repeated rather than written `\+`: BSD sed (every
    # macOS host) has no `\+` in a BRE and matches a literal plus, so the
    # extraction returned NOTHING there — `added_names` empty, `checked_new=0`,
    # and the gate reported ok over a newly-bound unrunnable file. A gate that
    # silently stops gating on one platform is worse than one that fails there.
    added_names="$(git -C "$ROOT" diff -U0 "$BASE_REF" -- openspec/litmus-bindings.yaml 2>/dev/null \
        | sed -n 's/^+[[:space:]]*-[[:space:]]*\(litmus:[A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p' | sort -u || true)"
    unrunnable=""
    checked_new=0
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        file="$(grep -rlF "name: $nm" "$TESTS_DIR" 2>/dev/null | head -1)"
        [ -n "$file" ] || continue
        checked_new=$((checked_new + 1))
        if ! "$RUNNER" --parse-only "$file" >/dev/null 2>&1; then
            [ -n "$unrunnable" ] && unrunnable="$unrunnable,"
            unrunnable="$unrunnable$nm"
        fi
    done <<< "$added_names"

    if [ -n "$unrunnable" ]; then
        echo "violation:bound-but-unrunnable:$unrunnable"
        echo "each name above is newly bound and the RUNNER cannot extract its steps (958-b36m)." >&2
        echo "Being valid YAML and correctly bound is not being runnable. Reproduce with:" >&2
        echo "  scripts/run-litmus-test.sh --parse-only <file>" >&2
        exit 1
    fi

    # ADVISORY over the whole bound corpus. Never a refusal (699-dycj): a
    # pre-existing hole is worth a number, not a fleet-wide red.
    #
    # RUN ONLY WHEN THE CORPUS COULD HAVE MOVED. Parsing 394 files costs ~36s,
    # which is a 29% tax on a 126s gate paid by every cycle on every host —
    # most of them touching no litmus file at all. If neither the registry nor
    # any litmus file changed against the base, the count cannot have changed
    # either, so the sweep is skipped rather than re-derived. This is the same
    # reasoning as diff-scoping the gate above, applied to cost instead of
    # blast radius.
    corpus_touched="$(git -C "$ROOT" diff --name-only "$BASE_REF" -- openspec/litmus-bindings.yaml openspec/litmus-tests 2>/dev/null || true)"
    corpus_bad=0
    if [ -z "$corpus_touched" ]; then
        corpus_bad=-1
    else
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        bf="$(grep -rlF "name: $b" "$TESTS_DIR" 2>/dev/null | head -1)"
        [ -n "$bf" ] || continue
        # A `phase: retired` file is DELIBERATELY shelved and never executed, so
        # its steps being unextractable harms nobody. Counting it here would be
        # crying wolf — the same defect the stranded sweep had (946-pdpi), where
        # a number that looked like abandonment actually measured something
        # else. Both of this corpus's current hits are retired.
        grep -qE "^phase:[[:space:]]*retired[[:space:]]*$" "$bf" && continue
        "$RUNNER" --parse-only "$bf" >/dev/null 2>&1 || corpus_bad=$((corpus_bad + 1))
    done <<< "$bound"
    fi
    if [ "$corpus_bad" -gt 0 ]; then
        echo "advisory:bound-but-unrunnable-existing=$corpus_bad (not gating; find them with scripts/run-litmus-test.sh --parse-only)" >&2
    fi
fi
echo "ok:litmus-bindings:files=$files bound=$bound_n retired=$retired grandfathered=$grandfathered"
exit 0
