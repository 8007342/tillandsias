#!/usr/bin/env bash
# Enforces that `if ! <pipeline containing a spawn>` is banned in scripts/.
# This prevents inverted guards caused by pipefail and early-exiting consumers like grep -q.
# @trace plan 795-imz3
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
cd "$ROOT"

if [ "$#" -gt 0 ]; then
    files=("$@")
else
    files=()
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(git ls-files 'scripts/*.sh' 'build.sh' 2>/dev/null || true)
fi

violations=()
for f in "${files[@]}"; do
    [ -n "$f" ] || continue
    # Skip non-files or the checker itself
    if [ ! -f "$f" ] || [[ "$f" == "scripts/check-no-spawn-in-if-not.sh" ]]; then
        continue
    fi

    # Read the file line by line
    line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        # Ignore lines explicitly marked safe
        if [[ "$line" == *"# sigpipe-ok:"* ]]; then
            continue
        fi

        # We are looking for `if !` or `elif !` followed by a pipeline `|`
        if [[ "$line" =~ ^[[:space:]]*(if|elif)[[:space:]]+![[:space:]] ]] && [[ "$line" =~ (^|[^\|])\|([^\|]|$) ]]; then
            violations+=("$f:$line_num:$line")
        fi
    done < "$f"
done < <(git ls-files 'scripts/*.sh' 'build.sh' 2>/dev/null || true)

if [ "${#violations[@]}" -gt 0 ]; then
    echo "violation:spawn-in-if-not: found ${#violations[@]} violations" >&2
    for v in "${violations[@]}"; do
        echo "  $v" >&2
    done
    echo "Do not use 'if ! <pipeline>' because pipefail + SIGPIPE can invert the guard." >&2
    echo "Instead, capture output and use the case idiom, or append '# sigpipe-ok: <reason>'." >&2
    exit 1
fi

echo "ok:no-spawn-in-if-not"
