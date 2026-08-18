#!/usr/bin/env bash
# =============================================================================
# check-wsl-exe-single-constructor.sh — order 795-jjw3
#
# Exactly ONE module in the workspace may construct a `wsl.exe` child, so a
# policy about wsl.exe (encoding, window flags, timeouts) is set once and
# cannot be forgotten N times.
#
# This is the durable half of 795-jjw3. Collapsing the duplicate constructors
# was a one-time edit; without a check, the next crate that cannot reach
# tillandsias-core will grow a third mirror and nothing will say so. The cost
# of the previous duplication was not hypothetical: WSL_UTF8 landed at 6 of 17
# call sites and the other 11 hand-scrubbed NUL bytes out of UTF-16LE output,
# indistinguishable by grep from the LEGITIMATE scrubs on hcsdiag.exe and CIM
# output, which are different binaries WSL_UTF8 never reaches.
#
# BASH 3.2 CLEAN (order 761-g36m): no mapfile, no associative arrays, no ${x^^}.
# The first draft used `mapfile` and the dialect gate caught it — macOS ships
# bash 3.2 and this check has to run everywhere the gate does.
#
# Prints exactly one line matching
#   ^(ok:wsl-single-constructor:[0-9]+ scanned|violation:wsl-extra-constructor:.*)$
# and exits 0 only when the sole constructor module owns every construction.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

# The one module allowed to say Command::new("wsl...").
OWNER='crates/tillandsias-core/src/wsl.rs'

if [ ! -f "$OWNER" ]; then
    printf 'violation:wsl-extra-constructor:owner-module-missing:%s\n' "$OWNER"
    exit 1
fi

# Match both `Command::new("wsl")` and `Command::new("wsl.exe")`, std or tokio,
# anywhere under crates/ — excluding the owner and excluding comment lines.
hits="$(
    grep -rn --include='*.rs' -E 'Command::new\("wsl(\.exe)?"\)' crates/ 2>/dev/null \
        | grep -v "^${OWNER}:" \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|///|//!)' \
        || true
)"

scanned="$(grep -rl --include='*.rs' -E 'Command::new\(' crates/ 2>/dev/null | wc -l | tr -d ' ')"

if [ -n "$hits" ]; then
    count=0
    # Here-doc, not a pipe: the loop must run in THIS shell so `count` survives.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf 'violation:wsl-extra-constructor:%s\n' "${line%%:*}"
        count=$((count + 1))
    done <<EOF
$hits
EOF
    printf 'violation:wsl-extra-constructor:%d site(s) outside %s\n' "$count" "$OWNER"
    exit 1
fi

printf 'ok:wsl-single-constructor:%s scanned\n' "$scanned"
exit 0
