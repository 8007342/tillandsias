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
    if printf '%s\n' "$bound" | grep -qxF "$name"; then
        bound_n=$((bound_n + 1))
        continue
    fi
    if grep -qE '^phase: *retired *$' "$f"; then
        retired=$((retired + 1))
        continue
    fi
    if [ -n "$grand" ] && printf '%s\n' "$grand" | grep -qxF "$name"; then
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
    printf '%s' "$on_disk" | grep -qxF "$b" || {
        [ -n "$dangling" ] && dangling="$dangling,"
        dangling="$dangling$b"
    }
done <<< "$bound"
if [ -n "$dangling" ]; then
    echo "violation:dangling-binding:$dangling"
    echo "each name above is registered in litmus-bindings.yaml with NO file behind it — the suite claims coverage that cannot execute" >&2
    exit 1
fi

echo "ok:litmus-bindings:files=$files bound=$bound_n retired=$retired grandfathered=$grandfathered"
exit 0
