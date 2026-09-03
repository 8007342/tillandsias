#!/usr/bin/env bash
# @trace spec:accel-capability-probe
# @trace order:967-6ax6, order:793-zumy
#
# ORDER 967-6ax6, exit criterion 1. The container name the accel-proof producers
# LOOK FOR and the name scripts/dev-inference-ensure.sh CREATES must not drift.
#
# THE DEFECT THIS RATCHETS, measured on yoga 2026-09-02. The producer held a
# single hardcoded "tillandsias-inference" while the dev lane creates
# "tillandsias-dev-inference", so `podman exec` found no container, the rung
# stayed at `-`, and the envelope read IDENTICAL to a machine with no
# accelerator at all — on a host whose lane demonstrably worked (devices passed
# through, /api/ps answering from inside the running container). The producer
# behaved correctly on the input it was given; the input was the wrong name.
#
# IT UNDER-CLAIMED, and the packet is explicit that this is the direction that
# survives review, "because chasing it looks like diligence". A guard is the
# only thing that catches a silent under-claim, since nothing fails.
#
# WHY A GUARD AND NOT JUST THE ENV HOOK. `TILLANDSIAS_INFERENCE_CONTAINER` is
# the real single source and dev-inference-ensure.sh exports it — but only into
# processes it spawns. A probe run from the tray, a cron, or any shell that did
# not source that script sees no such variable and falls back to the compiled
# candidate list. So the two literals still have to agree, and today they are
# two literals in two languages that nothing compares.
#
# Verdict grammar, one line on stdout:
#   ok:inference-container-name-agreement:<name>        exit 0
#   violation:inference-container-name-drift:<details>  exit 1
#   blocked:<reason>                                    exit 2
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${TILLANDSIAS_DEV_INFERENCE_SCRIPT:-$ROOT/scripts/dev-inference-ensure.sh}"
PROBE="${TILLANDSIAS_ACCEL_PROBE_SRC:-$ROOT/crates/tillandsias-headless/src/accel_probe.rs}"

[ -r "$SCRIPT" ] || { echo "blocked:script-unreadable:$SCRIPT"; exit 2; }
[ -r "$PROBE" ]  || { echo "blocked:probe-unreadable:$PROBE"; exit 2; }

# The name the CREATOR uses. Anchored on the assignment so a mention in a
# comment cannot satisfy the check — the comments in both files discuss this
# name at length, which is exactly how a lax pattern would pass over a rename.
dev_name="$(sed -n 's/^DEV_CONTAINER="\([^"]*\)".*/\1/p' "$SCRIPT" | head -1)"
[ -n "$dev_name" ] || { echo "blocked:no-dev-container-assignment-in:$SCRIPT"; exit 2; }

# The names the CONSUMER will try. Read from the candidate array's contents
# rather than by grepping the file for the string anywhere, for the same reason.
cand_line="$(sed -n '/INFERENCE_CONTAINER_CANDIDATES/,/;/p' "$PROBE" | tr -d '\n')"
[ -n "$cand_line" ] || { echo "blocked:no-candidate-list-in:$PROBE"; exit 2; }

case "$cand_line" in
    *"\"$dev_name\""*)
        echo "ok:inference-container-name-agreement:$dev_name"
        exit 0
        ;;
esac

# Report what each side actually says. A verdict that only says "drift" sends
# the reader back to both files to find out which one moved.
candidates="$(printf '%s' "$cand_line" \
    | grep -o '"[a-z0-9-]*"' | tr -d '"' | tr '\n' ',' | sed 's/,$//')"
echo "violation:inference-container-name-drift:creates=$dev_name:candidates=$candidates"
{
    echo "  $SCRIPT creates the container '$dev_name'."
    echo "  $PROBE will only try: $candidates"
    echo "  A probe that never names the running container reports the BOTTOM of"
    echo "  the accel-proof scale on a host whose lane works — indistinguishable"
    echo "  from a machine with no accelerator (967-6ax6, measured on yoga)."
    echo "  Fix: add '$dev_name' to INFERENCE_CONTAINER_CANDIDATES, or rename"
    echo "  DEV_CONTAINER to a name already in that list. Do not add a THIRD"
    echo "  literal elsewhere; the env hook TILLANDSIAS_INFERENCE_CONTAINER is"
    echo "  the override, not a substitute for these two agreeing."
} >&2
exit 1
