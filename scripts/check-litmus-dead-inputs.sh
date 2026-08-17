#!/usr/bin/env bash
# @trace spec:litmus-framework
# =============================================================================
# check-litmus-dead-inputs.sh — order 765-mza8, the 634-39ik/698-7n6q family.
#
# An `inputs:` glob that matches NOTHING is the dangerous kind of wrong. It
# cannot make a test run; it can only make it skip. So a typo'd or stale glob
# ("crate/**", a renamed script, a deleted image dir) silently subtracts that
# test from every `--diff-scope` run while the suite still reports green. This
# guard makes that class impossible to commit.
#
# THE PROPERTY, not the literal. It does not pin which globs exist or how many.
# It asserts of every declared glob: it resolves to at least one tracked file
# today. That stays true as annotations are added, renamed, and removed, and it
# fails exactly when an annotation stops describing the tree.
#
# Matching is bash `[[ == ]]` against `git ls-files`, DELIBERATELY the same
# matcher run-litmus-test.sh uses at selection time (see
# litmus_inputs_intersect_diff there). Checking with git's pathspec engine
# instead would be checking a different question than the one that gets asked
# at runtime — `**` and `*` do not mean the same thing to both.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ok:litmus-dead-inputs:not-a-git-repo (nothing to resolve against)"
    exit 0
fi

tracked="$(git ls-files)"
if [ -z "$tracked" ]; then
    echo "ok:litmus-dead-inputs:no-tracked-files"
    exit 0
fi

dead=0
checked=0
annotated=0

for file in openspec/litmus-tests/litmus-*.yaml; do
    [ -f "$file" ] || continue

    # Same top-level block parse as the runner's awk fallback.
    globs="$(awk '
        /^inputs:[[:space:]]*$/ { collecting=1; next }
        collecting && /^[[:space:]]*-[[:space:]]+/ {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]+/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            print line
            next
        }
        collecting && /^[^[:space:]]/ { collecting=0 }
    ' "$file")"

    [ -n "$globs" ] || continue
    annotated=$((annotated + 1))

    while IFS= read -r g; do
        [ -n "$g" ] || continue
        checked=$((checked + 1))

        hit=0
        while IFS= read -r p; do
            # shellcheck disable=SC2053
            if [[ "$p" == $g ]]; then
                hit=1
                break
            fi
        done <<<"$tracked"

        if [ "$hit" -eq 0 ]; then
            dead=$((dead + 1))
            echo "REFUSED: $file declares inputs glob '$g', which matches no tracked file." >&2
            echo "         A glob that matches nothing can only SUBTRACT this test from" >&2
            echo "         --diff-scope runs. Fix the glob, or drop it if the dependency" >&2
            echo "         is gone. Matching is bash [[ == ]], so '*' crosses '/'." >&2
        fi
    done <<<"$globs"
done

if [ "$dead" -gt 0 ]; then
    echo "violation:litmus-dead-inputs:$dead"
    exit 1
fi

echo "ok:litmus-dead-inputs:$checked glob(s) across $annotated annotated test(s)"
exit 0
