#!/usr/bin/env bash
# @trace spec:meta-orchestration
# forge-e2e-rate-limit.sh — host-side rate limiter for token-expensive
# in-forge agent e2e runs (operator directive, 2026-07-11).
#
# WHY: every --ci-full post-build phase (and every retry of the destructive
# gate pipeline) launched a FULL /meta-orchestration cycle inside the forge.
# Overnight loops ran that pipeline several times, sometimes killing the
# in-forge agent at the step budget — burning provider tokens (BigPickle)
# on work that was then discarded, and tripping provider rate limits that
# then masqueraded as forge-lane outages. The full-cycle e2e is allowed at
# most once per WINDOW per host; all other runs must downgrade to the cheap
# smoke prompt (see skills/meta-orchestration/SKILL.md "Smoke Mode").
#
# Usage:
#   scripts/forge-e2e-rate-limit.sh check  <class>   # exit 0 allow, 3 limited
#   scripts/forge-e2e-rate-limit.sh record <class>   # stamp a run now
#   scripts/forge-e2e-rate-limit.sh status <class>   # like check, always exit 0
#
# Classes are lowercase kebab slugs; the canonical one is `full-meta`
# (full /meta-orchestration in-forge e2e).
#
# Output grammar (exactly one line):
#   ^(allow:[a-z0-9-]+|limited:[a-z0-9-]+:[0-9]+s|recorded:[a-z0-9-]+)$
#
# Env:
#   TILLANDSIAS_E2E_RATE_WINDOW_S  override window (default 14400 = 4h)
#   TILLANDSIAS_E2E_FORCE=1        operator escape hatch: check always allows.
#                                  Using it in automation is itself a finding.
#
# Stamps live under ~/.cache/tillandsias/e2e-rate-limit/ — host-persistent,
# survives `podman system reset` (which only wipes podman storage/volumes).
set -euo pipefail

WINDOW="${TILLANDSIAS_E2E_RATE_WINDOW_S:-14400}"
STAMP_DIR="${TILLANDSIAS_E2E_RATE_DIR:-$HOME/.cache/tillandsias/e2e-rate-limit}"

usage_fail() {
    echo "FAIL: usage: $0 (check|record|status) <class>" >&2
    exit 2
}

[ $# -eq 2 ] || usage_fail
MODE="$1"
CLASS="$2"
case "$CLASS" in
    *[!a-z0-9-]*|"") usage_fail ;;
esac
STAMP="$STAMP_DIR/$CLASS.stamp"

now="$(date +%s)"
last=0
if [ -f "$STAMP" ]; then
    last="$(cat "$STAMP" 2>/dev/null || echo 0)"
    case "$last" in *[!0-9]*|"") last=0 ;; esac
fi
age=$(( now - last ))
remaining=$(( WINDOW - age ))

case "$MODE" in
    check|status)
        if [ "${TILLANDSIAS_E2E_FORCE:-0}" = "1" ] || [ "$age" -ge "$WINDOW" ]; then
            echo "allow:$CLASS"
            exit 0
        fi
        echo "limited:$CLASS:${remaining}s"
        [ "$MODE" = "status" ] && exit 0
        exit 3
        ;;
    record)
        mkdir -p "$STAMP_DIR"
        echo "$now" > "$STAMP"
        echo "recorded:$CLASS"
        ;;
    *)
        usage_fail
        ;;
esac
