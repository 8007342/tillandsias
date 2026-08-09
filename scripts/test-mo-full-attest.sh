#!/usr/bin/env bash
# @trace order:614-2gqx, spec:meta-orchestration
set -uo pipefail

# Fixture for the full-mode terminal attestation gate (order 614-2gqx).
#
# Reproduces the breach shape — a provider ending normally between tool calls
# AFTER a local commit, with no terminal marker — and proves the outer gate
# rejects exit zero instead of discarding the commit as green. Also covers
# malformed markers, an unpushed local commit claim, a branch mismatch, a
# remote head that never converges, and a clean pass.
#
# The scenarios run inside scripts/mo-full-attest.sh fixture, which injects a
# fake remote probe (MO_FULL_REMOTE_PROBE) so nothing here touches a live
# remote. Exit 0 only when all six scenarios match their expected verdicts.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/scripts/mo-full-attest.sh" fixture
