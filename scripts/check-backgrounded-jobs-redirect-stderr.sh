#!/usr/bin/env bash
# @trace spec:runtime-diagnostics-stream, spec:logging-accountability
# @trace order:702-6jza
#
# ORDER 702-6jza D4. Refuse a BACKGROUNDED invocation in an agent entrypoint
# that redirects only fd 1.
#
# THE DEFECT. `cmd >>/tmp/forge-lifecycle.log &` redirects stdout and leaves fd 2
# on the container tty. The job then writes stderr concurrently with the
# foreground entrypoint and, later, with a live agent TUI — the "screen
# bleeding" half of the operator's 2026-08-12 macOS report. The tree already
# documented the hazard twice, including lib-common.sh's own note that these
# functions are "backgrounded by the agent entrypoints and share the TTY with a
# live TUI", and the redirect still dropped stderr on the floor.
#
# THE PACKET NAMED ONE FILE; FIVE HAD IT. entrypoint-forge-claude.sh was the one
# reported, and claude, codex, opencode, opencode-web and antigravity all
# carried the identical two lines — ten sites. That is the same shape as D3 in
# the same packet, where a 2026-07-27 TERM fix was applied to the OpenCode lane
# and never carried to the other four. A defect found on one lane of a repeated
# pattern is a defect on the pattern; this guard exists so the next one cannot
# be fixed on one lane and left on four.
#
# WHY A GUARD AND NOT JUST THE FIX. Nothing prevents the next entrypoint from
# being written the same way, and the symptom appears on a live TUI on ANOTHER
# platform — the slowest possible feedback path.
#
# Verdict grammar, one line on stdout:
#   ok:backgrounded-stderr:<n> site(s) checked      exit 0
#   violation:backgrounded-stderr:<n>               exit 1
#   blocked:<reason>                                exit 2
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

SCAN_GLOB="${TILLANDSIAS_ENTRYPOINT_GLOB:-images/default/entrypoint-forge-*.sh}"

# shellcheck disable=SC2206
files=($SCAN_GLOB)
if [ "${#files[@]}" -eq 0 ] || [ ! -e "${files[0]}" ]; then
    echo "blocked:no-entrypoints-matched:$SCAN_GLOB"
    exit 2
fi

checked=0
bad=""

for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    # A backgrounded line is one ending in `&` (not `&&`). Of those, flag any
    # that redirects stdout without also redirecting stderr — either `2>&1`
    # after the stdout redirect, or an explicit `2>`.
    while IFS= read -r entry; do
        lineno="${entry%%:*}"
        line="${entry#*:}"
        checked=$((checked + 1))
        case "$line" in
            *"2>&1"*|*"2>"*) : ;;                      # stderr is handled
            *) bad="${bad}${f}:${lineno}:${line}"$'\n' ;;
        esac
    done < <(grep -nE '(>>?)[[:space:]]*[^[:space:]|&]+.*[^&]&[[:space:]]*$' "$f" || true)
done

if [ -n "$bad" ]; then
    printf 'violation:backgrounded-stderr:%s\n' "$(printf '%s' "$bad" | grep -c .)"
    printf '%s' "$bad" | sed 's/^/  fd1-only backgrounded job: /' >&2
    echo "  A backgrounded job that redirects only stdout leaves fd 2 on the" >&2
    echo "  container tty, where it writes over a live agent TUI (702-6jza D4)." >&2
    echo "  REMEDY: >>/tmp/forge-lifecycle.log 2>&1 &" >&2
    exit 1
fi

echo "ok:backgrounded-stderr:${checked} site(s) checked"
