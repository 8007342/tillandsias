#!/usr/bin/env bash
# @trace order:741-3y48, spec:meta-orchestration
set -uo pipefail

# Fixture for the forge findings-persistence gate (order 741-3y48).
#
# Reproduces the loss shape recorded on 2026-08-15: an in-forge agent files a
# well-formed fragment into the ephemeral container checkout, the ledger accepts
# it, and teardown destroys it. Covers the state `git status` is blind to — a
# COMMITTED but unpushed fragment, which reads as a clean tree and is one
# teardown from gone.
#
# The negative control runs FIRST and is the hard requirement: a cycle that
# files nothing must print ok:no-findings and stay silent. A gate that nags
# every clean cycle is one every agent learns to ignore.
#
# Each scenario builds a throwaway repo with a real bare remote, so persisted vs
# unpersisted is decided by actual git state rather than a mock. Exit 0 only
# when all scenarios match.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/scripts/check-forge-findings-persisted.sh" fixture
