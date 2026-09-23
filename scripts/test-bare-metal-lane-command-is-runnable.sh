#!/usr/bin/env bash
# @trace order:1356-u6xe, spec:git-mirror-service
#
# The substrate checker's mirror/router/inference todo: lines print a command a
# worker COPIES AND RUNS. Until 1356-u6xe that command interpolated the bare
# project name — `tillandsias --bash tillandsias` — and the binary answered
# `Error: Project not found: tillandsias` with rc=1, because it resolves a
# CHECKOUT PATH there, not a name. This fixture pins the property that makes
# the affordance worth printing: the argument after `--bash` is a directory
# that exists on this host, and the project root is its parent.
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

# The path is the token after --bash.
path="${cmd##*--bash }"
[ -n "$path" ] || fail "no-argument-after---bash:$cmd"

case "$path" in
    /*) ;;
    *) fail "argument-after---bash-is-not-a-path:$path" ;;
esac
[ -d "$path" ] || fail "argument-after---bash-is-not-a-directory:$path"

# The project root must be the PARENT of that checkout, since the binary scans
# the root for projects.
root_kv="${cmd%% tillandsias --bash*}"
root="${root_kv#TILLANDSIAS_HOST_PROJECT_ROOT=}"
[ -d "$root" ] || fail "project-root-is-not-a-directory:$root"
[ "$root" = "$(dirname "$path")" ] || fail "project-root-is-not-the-parent:root=$root path=$path"

echo "ok:bare-metal-lane-command-is-runnable:root=$root path=$path"
