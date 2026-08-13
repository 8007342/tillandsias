#!/usr/bin/env bash
# @trace spec:methodology-accountability
#
# Order 718-nkm2 / operator directive 2026-08-13. Rebuild and re-establish what
# a cycle depends on, at the START of every cycle, idempotently.
#
# THE DIRECTIVE, in the operator's words: the project believes in idempotency
# and ephemerality — everything should be safe to destroy and relaunch at any
# moment, Erlang style. A cycle should therefore never inherit a component from
# a previous cycle and hope it is current.
#
# It is not hypothetical hygiene. On 2026-08-13 a selector change added a
# subcommand every host's binary predated, and this checkout's Windows binary
# went on refusing until someone rebuilt it by hand. A stale component is the
# one failure this loop cannot reason its way out of, because the tool it would
# reason WITH is the stale thing.
#
# WHAT IS REBUILT, and why only this
#
#   tillandsias-plan  — every expert call, the batch selector, the ledger
#                       writes and the closure checks go through it. It is the
#                       cycle's own instrument.
#
# Deliberately NOT everything: a full workspace build costs minutes and the
# cycle's own gate (`./build.sh --check`) already compiles what it validates.
# Rebuilding the instrument is the property that matters; rebuilding the product
# on a schedule is a different, heavier decision.
#
# WHAT IS RE-ESTABLISHED
#
#   dev inference     — scripts/dev-inference-ensure.sh, the local endpoint the
#                       expert system's semantic tier calls. Idempotent; a
#                       running endpoint costs one HTTP round trip.
#
# GRAMMAR (exactly one line on stdout)
#   ok:cycle-preflight:<plan-verdict>:<inference-verdict>
#   blocked:preflight:<component>:<detail>
#
# Exit 0 on ok, 1 on blocked. A blocked preflight means the cycle must not
# start: it would be selecting work with an instrument it has not verified.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "blocked:preflight:root:cannot-cd"; exit 1; }

plan_verdict="skipped"
if [ "${CYCLE_PREFLIGHT_SKIP_BUILD:-0}" != "1" ]; then
    if ! command -v cargo >/dev/null 2>&1; then
        # Name the fault. A cycle that cannot rebuild its instrument should say
        # so rather than proceed on whatever binary happens to be lying around.
        echo "blocked:preflight:plan:cargo-absent"
        exit 1
    fi
    build_log="$(mktemp)"
    if cargo build --release -p tillandsias-plan >"$build_log" 2>&1; then
        # `cargo build` is a no-op when nothing changed, so this is cheap on the
        # common path and correct on the uncommon one.
        plan_verdict="rebuilt"
    else
        reason="$(grep -m1 '^error' "$build_log" | cut -c1-120)"
        rm -f "$build_log"
        echo "blocked:preflight:plan:${reason:-build-failed}"
        exit 1
    fi
    rm -f "$build_log"

    # Prove the freshly built binary answers, rather than assuming a successful
    # compile means a working instrument.
    #
    # Resolve through the SHARED probe, never a hardcoded path. On a shared
    # Windows/WSL checkout a WSL build leaves a Linux ELF at exactly
    # ./target/release/tillandsias-plan beside the runnable .exe, so the
    # hardcoded path this check first shipped with refused
    # `capabilities-refused` on a host whose instrument was freshly built and
    # perfectly healthy — blocking the cycle for a filename. That is the same
    # bug 704-zcgi centralised the probe to stop recurring, and the fourth site
    # to reintroduce it.
    . "$ROOT/scripts/plan-binary-probe.sh"
    if ! plan_bin="$(resolve_plan_binary)"; then
        echo "blocked:preflight:plan:capabilities-refused"
        exit 1
    fi
fi

# Inference is a REPORT, not a gate: the deterministic expert tiers work without
# it, and a cycle that cannot reach a model is degraded, not broken. Blocking
# here would strand work on a host with no network — the same reasoning that
# keeps the windows-only source report advisory.
inference_verdict="$(bash "$ROOT/scripts/dev-inference-ensure.sh" 2>/dev/null | tail -1)"
case "$inference_verdict" in
    ok:*) inference_verdict="${inference_verdict%%:*}:${inference_verdict#*:}" ;;
    "") inference_verdict="unknown" ;;
esac

echo "ok:cycle-preflight:${plan_verdict}:${inference_verdict}"
exit 0
