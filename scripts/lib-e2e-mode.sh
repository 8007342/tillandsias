#!/usr/bin/env bash
# @trace spec:meta-orchestration
# @trace order:404, order:781-6gys
#
# Shared full-vs-smoke mode decision for the in-forge e2e launchers.
#
# WHY THIS IS SHARED RATHER THAN COPIED (order 404). The OpenCode launcher owned
# this logic alone, and 404 asks for a Codex lane scored EXACTLY like it —
# "the same forge-e2e-rate-limit class so the 4h/full-cycle budget is shared,
# not doubled". A copied decision is a budget that drifts: the moment one lane's
# limiter class or de-escalation rule changes and the other's does not, the two
# lanes stop being comparable and the shared budget quietly becomes two budgets.
#
# This week produced two live instances of that exact shape in one packet
# (702-6jza D3 and D4): a fix applied to the OpenCode lane and never carried to
# the other four. Extracting the decision is the cheap way not to author a
# third.
#
# WHAT IS DELIBERATELY NOT SHARED: each launcher's own
# `tillandsias . --<harness> --prompt "$PROMPT"` invocation stays written out in
# full, in its own file. litmus-forge-e2e-rate-limit-shape greps that literal,
# and more importantly a reader should be able to see which binary flag a lane
# actually launches without following an indirection.
#
# Contract: source this, then call `e2e_resolve_mode`. It sets MODE to
# full|smoke, honours the de-escalation-only override, and prints its own NOTE
# lines. It never records budget — recording is the caller's, because only the
# caller knows it is really about to launch.

# TILLANDSIAS_E2E_FORCE_MODE=smoke forces the smoke path even when the limiter
# would allow full (order 781-6gys).
#
# Order 781-6gys criterion 2: the smoke path — the one EVERY rate-limited lane
# takes, and the one that packet's exit criterion must produce evidence for —
# was unreachable on demand. Mode came solely from the limiter, so deliberately
# exercising smoke meant recording a full-meta run that never happened, i.e.
# falsifying the very budget ledger the directive exists to protect.
#
# The override is DE-ESCALATION ONLY, and that asymmetry is the whole safety
# argument: forcing `smoke` can only ever make a run cheaper, so it cannot be
# used to evade the 2026-07-11 token-budget directive. Forcing `full` would do
# exactly that, so it is refused loud rather than silently ignored — an override
# that quietly does nothing is how a budget guard rots. The escalating direction
# already has a reviewed owner: TILLANDSIAS_E2E_FORCE=1 on the limiter itself.
e2e_resolve_mode() {
    if scripts/forge-e2e-rate-limit.sh check full-meta >/dev/null 2>&1; then
        MODE=full
    else
        MODE=smoke
        echo "NOTE: full-meta e2e rate-limited ($(scripts/forge-e2e-rate-limit.sh status full-meta)) — running smoke mode"
    fi

    case "${TILLANDSIAS_E2E_FORCE_MODE:-}" in
        "") ;;
        smoke)
            if [ "$MODE" = full ]; then
                echo "NOTE: TILLANDSIAS_E2E_FORCE_MODE=smoke — de-escalating full -> smoke (no full-meta budget consumed)"
            fi
            MODE=smoke
            ;;
        *)
            echo "FAIL: TILLANDSIAS_E2E_FORCE_MODE='${TILLANDSIAS_E2E_FORCE_MODE}' — only 'smoke' is accepted (de-escalation only; use TILLANDSIAS_E2E_FORCE=1 on scripts/forge-e2e-rate-limit.sh to escalate)" >&2
            exit 2
            ;;
    esac
}
