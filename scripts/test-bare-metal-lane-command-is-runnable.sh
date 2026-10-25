#!/usr/bin/env bash
# @trace order:1356-u6xe, spec:git-mirror-service
#
# The substrate checker's mirror/router/inference todo: lines print a command a
# worker COPIES AND RUNS. Until 1356-u6xe that command interpolated the bare
# project name — `tillandsias --bash tillandsias` — and the binary answered
# `Error: Project not found: tillandsias` with rc=1, because it resolves a
# CHECKOUT PATH there, not a name. 776-jcf3 then retired path launches, so
# this fixture now pins the cloud form: `tillandsias --cloud <owner>/<repo>
# --bash`, which is the only launch the binary accepts.
#
# It asserts the SHAPE of the printed command, never the binary's behaviour:
# it runs no lane and starts no container, so it is safe on a host with no
# podman and inside a forge.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECKER="scripts/check-bare-metal-host-initialized.sh"
fail() { echo "fail:bare-metal-lane-command:$*"; exit 1; }

[ -x "$CHECKER" ] || fail "checker-not-executable:$CHECKER"

# Force the mirror probe to miss by naming a project no container serves. That
# is the ONLY branch that prints the lane command, and it prints it without
# touching anything.
line="$(TILLANDSIAS_PROJECT=definitely-no-such-project-1356u6xe "$CHECKER" 2>/dev/null || true)"

case "$line" in
    todo:initialize-bare-metal-host:mirror:*) ;;
    skip:bare-metal-host:no-podman)
        echo "skip:bare-metal-lane-command:no-podman"; exit 0 ;;
    todo:initialize-bare-metal-host:vault:*|todo:initialize-bare-metal-host:proxy:*)
        # The enclave is down, so the run never reaches the mirror probe. That
        # is a substrate state, not a failure of this property.
        echo "skip:bare-metal-lane-command:enclave-down"; exit 0 ;;
    *) fail "unexpected-verdict:${line:-<empty>}" ;;
esac

cmd="${line#todo:initialize-bare-metal-host:mirror:}"

# 776-jcf3: the lane command is the cloud form, `tillandsias --cloud
# <owner>/<repo> --bash`, with no positional host path and no
# TILLANDSIAS_HOST_PROJECT_ROOT (both retired).
case "$cmd" in
    *TILLANDSIAS_HOST_PROJECT_ROOT*) fail "names-retired-project-root:$cmd" ;;
esac
case "$cmd" in
    "tillandsias --cloud "*" --bash") ;;
    *) fail "not-the-cloud-lane-form:$cmd" ;;
esac
nwo="${cmd#tillandsias --cloud }"
nwo="${nwo% --bash}"
case "$nwo" in
    */*) ;;
    *) fail "cloud-argument-is-not-owner-repo:$nwo" ;;
esac
case "$nwo" in
    /*|*/*/*|*" "*) fail "cloud-argument-is-a-path:$nwo" ;;
esac

echo "ok:bare-metal-lane-command-is-runnable:cloud=$nwo"
