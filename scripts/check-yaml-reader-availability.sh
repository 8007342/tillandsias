#!/usr/bin/env bash
# ORDER 746-htj9. Prove the sanctioned YAML reader EXISTS where the gates run.
#
# The packet's exit criteria say this, and the word is load-bearing:
#
#   "An executable check proves availability in each environment RATHER THAN
#    ASSERTING IT: run the reader in the forge, on the host, and in the
#    toolbox and record the verdicts."
#
# The 2026-08-15 double outage was not caused by a bad YAML reader. It was
# caused by two correct ones that were ABSENT where they were called: ruby
# broke the forge, and the yq rewrite that fixed the forge broke the host and
# the builder toolbox on the same day. Nothing could have caught either,
# because availability was a claim in a table and not a command anyone ran.
#
# So this script does not check that YAML parses. It checks that the thing
# which parses YAML is reachable from HERE, and it names where "here" is.
#
# Verdict grammar (one line, stdout):
#   ok:yaml-reader:<env>:<reader-path>
#   blocked:yaml-reader-absent:<env>
#   blocked:yaml-reader-broken:<env>:<verdict-it-gave>
#
# Pinned by scripts/test-yaml-reader-availability.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# WHICH ENVIRONMENT AM I. Deliberately the same three the outage table names,
# because a verdict that cannot say where it ran does not answer the criterion.
detect_env() {
    if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then echo forge; return; fi
    # The builder toolbox exports this; see scripts/with-tillandsias-builder.sh.
    if [ -n "${TOOLBOX_PATH:-}" ] || [ -f /run/.toolboxenv ]; then echo toolbox; return; fi
    echo host
}
ENV_NAME="$(detect_env)"

. "$ROOT/scripts/plan-binary-probe.sh"
READER="$(resolve_plan_binary 2>/dev/null || true)"

if [ -z "$READER" ] || [ ! -x "$READER" ]; then
    echo "blocked:yaml-reader-absent:$ENV_NAME"
    exit 1
fi

# PROVE IT RUNS, do not just stat it. A binary built for another libc or
# another architecture stats fine and fails to exec — which is exactly the
# class of thing that only shows up in the environment you did not test.
# The probe target is the real ledger, so this doubles as the 720-24u6
# regression check: 231 bare ISO-8601 timestamps must still load.
PROBE="$ROOT/plan/index.yaml"
verdict="$("$READER" validate-yaml "$PROBE" 2>&1 || true)"

case "$verdict" in
    ok:yaml-loads:*)
        echo "ok:yaml-reader:$ENV_NAME:${READER#"$ROOT/"}"
        ;;
    *)
        echo "blocked:yaml-reader-broken:$ENV_NAME:${verdict%%$'\n'*}"
        exit 1
        ;;
esac
