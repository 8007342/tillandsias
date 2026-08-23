#!/usr/bin/env bash
# @trace order:850-bif2, order:859-b2zc, spec:accel-capability-probe
#
# check-capability-row.sh — is THIS host visible in the capability matrix?
#
# WHY (order 850-bif2). Five of seven known hosts were silent in the matrix —
# not failed, simply never asked to publish — and capability-aware routing
# (847-wgy4) cannot route to hardware the matrix cannot see. This makes the
# question falsifiable so the meta-orchestration Start-Of-Day gate can act on
# it: a joining host's first cycle answers `due:` and publishes, every later
# cycle answers `ok:` for free.
#
# HOST IDENTITY IS NOT RE-DERIVED HERE (order 859-b2zc). This script used to
# resolve the host inline with `hostname -s || hostname`, and the `hostname`
# BINARY IS ABSENT from every Fedora image this project runs on — both WSL
# distros on the Windows hosts and `localhost/tillandsias-forge`, the last
# verified directly under podman on 2026-08-23. The check therefore answered
# `unavailable:host-unresolvable` (exit 2) in precisely the environments the
# 850-bif2 gate exists to prompt, which is why the forge has never once been
# asked to publish a row: `unavailable:` is the one verdict that asks nobody
# to do anything.
#
# The correct chain already existed as a sourceable helper —
# tillandsias_agent_workstation() in scripts/agent-identity.sh, added under
# 743-mgf3, whose own comment says in as many words that "some environments
# ship no `hostname`". So source the helper; never re-derive the chain. This is
# the 704-zcgi shape on a different probe: three scripts independently
# re-implemented one probe and all three got it wrong the same way, and the
# lesson there was that fixing instances is not enough — the copy has to go.
#
# Grammar (exactly one line):
#   ^(ok:capability-row-reported:[a-z0-9-]+|due:no-capability-row:[a-z0-9-]+|unavailable:[a-z-]+)$
#
# Exit codes: 0 = row present; 1 = due (publish one via
# scripts/host-capability-probe.sh --fragment); 2 = could not determine
# (report, never guess — an unavailable matrix is not an absent row).
#
# Advisory to the gate, like the health probe: `due:` asks the cycle to
# publish and commit a row, it never blocks work.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "unavailable:worktree-unreadable"; exit 2; }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
# shellcheck source=scripts/agent-identity.sh
. "$ROOT/scripts/agent-identity.sh"

PLAN="$(resolve_plan_binary)" || { echo "unavailable:no-runnable-plan-binary"; exit 2; }

# An EPHEMERAL identity must not be published (order 859-b2zc, criterion 3).
#
# Fixing the fallback chain alone is not enough, and getting this wrong is
# worse than the bug it replaces. A forge container has no stable node name:
# `run-forge-project.sh` passes no `--hostname` and no entrypoint exports
# TILLANDSIAS_WORKSTATION, so HOSTNAME, /etc/hostname and `uname -n` all report
# the container id (measured: `d872da8c03df`). With the chain repaired and
# nothing else, the forge would stop answering `unavailable:` and start
# answering `due:` under a name that changes every launch — and a matrix that
# grows a row per container is a regression, not progress. Turning a silent
# host into a noisy one is not a fix.
#
# So when this IS a forge and no stable identity was launch-provided, decline
# and name the remedy. The platform test is the canonical one
# (TILLANDSIAS_HOST_KIND=forge, else the .forge-startup-context.md marker), not
# a guess at the image name.
if [ -z "${TILLANDSIAS_WORKSTATION:-}" ] && [ "$(tillandsias_agent_platform)" = "forge" ]; then
    echo "[check-capability-row] This forge has no stable identity: TILLANDSIAS_WORKSTATION is unset and every other source (HOSTNAME, /etc/hostname, uname -n) reports the container id, which changes on every launch. Publishing under it would add a matrix row per container. Export TILLANDSIAS_WORKSTATION with the forge's fleet name before asking it to publish." >&2
    echo "unavailable:forge-identity-ephemeral"
    exit 2
fi

# tillandsias_agent_workstation honours TILLANDSIAS_WORKSTATION first, then
# HOSTNAME, /etc/hostname and the tillandsias_node_name probe, domain-stripping
# the result. It does NOT lowercase (the launch-provided value is authoritative
# as given), and the matrix fold key is lowercase — `Esmeraldinha` on the
# Windows hosts would miss `host:esmeraldinha` — so lowercase here with the
# shared helper rather than another inline `tr`.
host="$(tillandsias_lower "$(tillandsias_agent_workstation)")"
[ -n "$host" ] || { echo "unavailable:host-unresolvable"; exit 2; }

if ! matrix="$("$PLAN" capability-matrix 2>/dev/null)"; then
    echo "unavailable:capability-matrix-failed"
    exit 2
fi

if printf '%s\n' "$matrix" | grep -q "^host:$host	"; then
    echo "ok:capability-row-reported:$host"
    exit 0
fi
echo "due:no-capability-row:$host"
exit 1
