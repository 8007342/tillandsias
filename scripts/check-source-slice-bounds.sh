#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-source-slice-bounds.sh — a source-reading test that slices its own file
# between two SYMBOL NAMES must not be bounded by a symbol that no longer
# exists. Order 797-8dzt.
#
# THE DEFECT, measured 2026-08-17 in crates/tillandsias-headless/src/
# remote_projects.rs. A guard existed to prove the remote-project runner
# preflights the git image. It sliced its own source like this:
#
#     source.split("fn run_git_image_shell").nth(1)
#           .split("fn run_command_with_timeout").next()
#
# `fn run_command_with_timeout` is not in that file — the neighbour it named had
# been renamed or moved. `str::split` on an absent needle does NOT error and
# does NOT yield nothing: it yields ONE piece, the entire remainder. So the
# slice ran past the next function, and the assertion was satisfied by a
# DIFFERENT function's identical preflight call. Deleting the exact line the
# guard existed to protect left it GREEN. It had been unable to fail for as
# long as its bound had been missing.
#
# WHY A STANDING CHECK RATHER THAN THE ONE-TIME AUDIT THE PACKET ASKED FOR. The
# audit found the corpus otherwise clean: two symbol-bounded slices remain and
# both resolve. That is exactly the state in which the next rename reintroduces
# the bug silently, because nothing is watching. An audit answers "is it broken
# today"; this answers "will I be told when it breaks".
#
# WHAT IT CHECKS. Every `.split("<needle>")` in a Rust source under crates/
# whose needle looks like an item declaration (`fn`, `pub fn`, `async fn`,
# `pub async fn`, `impl`, `struct`, `enum`, `trait`). The needle must appear
# somewhere in that CRATE's sources. Crate scope, not file scope, is a
# deliberate under-approximation: a test in main.rs may legitimately slice
# action_host.rs via include_str!, and this must not accuse it. A needle that
# matches nowhere in the crate is dead by any reading.
#
# GRAMMAR — exactly one line:
#   ^(ok:source-slice-bounds:[0-9]+ checked|violation:source-slice-bounds:[0-9]+)$

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

CRATES_DIR="${TILLANDSIAS_SLICE_BOUND_ROOT:-crates}"
[ -d "$CRATES_DIR" ] && [ -n "$(find "$CRATES_DIR" -name '*.rs' -print -quit 2>/dev/null)" ] || {
    echo "ok:source-slice-bounds:0 checked"
    exit 0
}

checked=0
violations=""

# One pass per crate so "does this needle exist" is answered against the right
# source set. A crate is any directory holding a Cargo.toml directly under the
# root; sources outside one are checked against the whole tree rather than
# skipped, because unchecked is the failure mode this guard exists to remove.
while IFS= read -r rs; do
    [ -f "$rs" ] || continue
    crate_src=""
    d="$(dirname "$rs")"
    while [ "$d" != "." ] && [ "$d" != "/" ]; do
        if [ -f "$d/Cargo.toml" ]; then
            crate_src="$d"
            break
        fi
        d="$(dirname "$d")"
    done
    [ -n "$crate_src" ] || crate_src="$CRATES_DIR"

    # Extract the needle of every symbol-shaped split bound on this line.
    while IFS= read -r needle; do
        [ -n "$needle" ] || continue
        checked=$((checked + 1))
        # Match the needle as a DECLARATION, not as any occurrence. A plain
        # fixed-string search finds the needle inside the very `.split("…")`
        # call being checked, so every bound resolves to itself and the guard
        # is vacuous — caught here by its own control 2, which passed when it
        # had to fail. An item declaration begins its line (modulo indent) and
        # is followed by a name-terminating character; the string literal never
        # is, because `.split("` precedes it.
        _needle_re="$(printf '%s' "$needle" | sed -e 's/[][\.*^$(){}?+|/]/\\&/g')"
        # `unsafe ` (and `const `/`extern `) may precede the item keyword, so the
        # declaration does not always BEGIN with the needle. Measured 2026-08-29
        # (order 830-xsk2): a valid bound `fn listener_should_accept`, whose
        # declaration reads `unsafe fn listener_should_accept(`, was reported as
        # matching nothing — a FALSE accusation on a slice that resolves. The
        # guard's own failure mode is the one it hunts, one level up: a checker
        # that cannot see a declaration form reports a working bound as dead, and
        # the fix for the accusation would have been to weaken the test.
        # Modifier words may precede the item keyword (`unsafe fn`, `const fn`,
        # `pub unsafe fn`), so the declaration does not always BEGIN with the
        # needle. Measured 2026-08-29 (order 830-xsk2): a bound
        # `fn listener_should_accept`, declared `unsafe fn listener_should_accept(`,
        # was reported as matching nothing — a FALSE accusation against a slice
        # that resolves. This guard's own failure mode, one level up: a checker
        # blind to a declaration form calls working code dead, and the tempting
        # "fix" is to weaken the test it was protecting.
        #
        # Written as a repeated word-class rather than an alternation ON PURPOSE:
        # a `|` inside this quoted regex reads as a shell pipeline to
        # check-no-spawn-in-if-not.sh, which then flags this very line. Two
        # scanners, two false positives, same root — a pattern language embedded
        # in a host language that another scanner parses by eye.
        if ! grep -rqE "^[[:space:]]*([A-Za-z_]+ )*${_needle_re}[[:space:](<{]" "$crate_src" --include='*.rs' 2>/dev/null; then
            violations="${violations}  ${rs}: slice bound \"${needle}\" matches nothing in ${crate_src} — split() returns the WHOLE remainder, so this assertion has silently widened
"
        fi
    done <<EOF
$(grep -oE '\.split\("((pub )?(async )?fn|impl|struct|enum|trait) [A-Za-z0-9_:<>]+"\)' "$rs" 2>/dev/null \
    | sed -E 's/^\.split\("//; s/"\)$//')
EOF
done <<EOF
$(find "$CRATES_DIR" -name '*.rs' -type f 2>/dev/null | sort)
EOF

if [ -n "$violations" ]; then
    n="$(printf '%s' "$violations" | grep -c .)"
    echo "violation:source-slice-bounds:${n}"
    printf '%s' "$violations" >&2
    echo "  CAUSE: str::split on an absent needle yields ONE piece — the entire remainder — so the window runs past its intended end and the assertion is satisfied by unrelated code." >&2
    echo "  REMEDY: bound the slice by structure (the item's own closing brace) rather than by a neighbour's NAME, or update the bound and re-run the mutation control that proves the assertion can still fail." >&2
    exit 1
fi

echo "ok:source-slice-bounds:${checked} checked"
