#!/usr/bin/env bash
# test-jq-multiword-prefix.sh — order 914-ahsy.
#
# fast_tool (scripts/lib/tool-materialize.sh) falls back to resolve_tool when
# the host has no jq, and resolve_tool answers a MULTI-WORD prefix
# (`toolbox run -c tillandsias-builder jq`). A caller that writes "$JQ" hands
# that whole string to exec as ONE command name, so every jq call fails on
# exactly the host the fallback exists for. The idiom is unquoted $JQ, as in
# scripts/loop-success-probe.sh.
#
# ARM 1 (control, jq-absent): a two-word JQ built from a stub on a scratch
#   PATH. Quoted must fail and unquoted must succeed, or this fixture cannot
#   tell the two apart and proves nothing.
# ARM 2 (guard): no script that assigns JQ from fast_tool double-quotes it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0
fail=0
ok() { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/jq-multiword.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
printf '#!/bin/sh\necho stub-ok\n' > "$scratch/stubjq"
chmod +x "$scratch/stubjq"

JQ="env stubjq"
if out="$(PATH="$scratch:$PATH"; $JQ -n . 2>/dev/null)" && [ "$out" = "stub-ok" ]; then
    ok "ARM 1: unquoted two-word JQ runs the tool"
else
    bad "ARM 1: unquoted two-word JQ did not run the tool"
fi
if (PATH="$scratch:$PATH"; "$JQ" -n . >/dev/null 2>&1); then
    bad "ARM 1: quoted two-word JQ ran — the control no longer discriminates"
else
    ok "ARM 1: quoted two-word JQ fails (the defect this guards)"
fi

# The needle is assembled at runtime so this file cannot match itself.
quoted="\"\$""JQ\""
offenders=""
while IFS= read -r f; do
    [ "$f" = "$REPO_ROOT/scripts/test-jq-multiword-prefix.sh" ] && continue
    grep -q 'JQ="$(fast_tool jq' "$f" || continue
    if grep -qF "$quoted" "$f"; then
        offenders="$offenders ${f#"$REPO_ROOT"/}"
    fi
done < <(find "$REPO_ROOT/scripts" -name '*.sh' -type f | sort)
if [ -z "$offenders" ]; then
    ok "ARM 2: no fast_tool JQ caller double-quotes \$JQ"
else
    bad "ARM 2: double-quoted \$JQ in:$offenders"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'PASS: jq-multiword-prefix %d/%d (914-ahsy)\n' "$pass" "$total"
    exit 0
fi
printf 'FAIL: jq-multiword-prefix %d/%d (914-ahsy)\n' "$pass" "$total"
exit 1
