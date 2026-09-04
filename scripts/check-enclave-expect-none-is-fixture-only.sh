#!/usr/bin/env bash
# @trace order:1004-inkc
#
# check-enclave-expect-none-is-fixture-only.sh — `--expect none` disables the
# absent detection, so only the fixture may pass it.
#
# WHY THIS EXISTS. 1004-inkc fixed a check that `podman rm` could satisfy: with
# a required service DELETED it printed ok:...:absent=0, because the expected
# set came from the caller and the bare invocation supplied none. The fix moved
# the default into the check — and introduced `none` as an explicit
# enumeration-only opt-out, needed because an empty value now means "use the
# default" and three legacy fixture arms model a vault without a proxy while
# testing something else entirely.
#
# That opt-out is a door back into the defect. A production caller passing
# `none` gets exactly the old behaviour: a health check that cannot fail on a
# missing service. So the escape hatch is confined to the fixture, and the
# confinement is CHECKED rather than commented, because a rule only an attentive
# reader honours is a suggestion — the same reasoning 994-8r3w's own unmet
# criterion 3 recorded when its declaration lived in one caller.
#
# WHY A LINT AND NOT A RUNTIME GUARD. The obvious alternative is to accept
# `none` only when some TILLANDSIAS_*_TEST variable is set. That variable is
# settable from production too, so it moves the hole rather than closing it, and
# it adds a second thing that must stay true. A lint over the tree needs nothing
# to be true at runtime.
#
# GRAMMAR (one line on stdout)
#   ok:expect-none-fixture-only:<n> caller(s) checked
#   violation:expect-none-fixture-only:<count>

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

G=/usr/bin/grep
[ -x "$G" ] || G=grep

# The one file allowed to pass it, and the check that defines it.
ALLOWED_RE='^(scripts/test-enclave-service-health\.sh|scripts/check-enclave-service-health\.sh|scripts/check-enclave-expect-none-is-fixture-only\.sh)$'

# Callers are lines that PASS the token, not lines that merely mention it in
# prose. `--expect none`, `--expect=none`, or the env assigned literal none.
hits="$($G -rnE -- '(--expect[= ]+none|TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES=("|'"'"')?none)' \
    scripts images crates openspec 2>/dev/null \
    | $G -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)"

violations=0
checked=0
if [ -n "$hits" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        f="${line%%:*}"
        checked=$((checked + 1))
        if printf '%s' "$f" | $G -qE "$ALLOWED_RE"; then continue; fi
        violations=$((violations + 1))
        echo "  $line"
    done <<EOF
$hits
EOF
fi

if [ "$violations" -eq 0 ]; then
    echo "ok:expect-none-fixture-only:${checked} caller(s) checked"
    exit 0
fi
echo "      \`--expect none\` disables the absent detection (1004-inkc). A production"
echo "      caller passing it restores a health check that cannot fail on a DELETED"
echo "      service — the defect that order removed. Only the fixture may pass it."
echo "violation:expect-none-fixture-only:${violations}"
exit 1
