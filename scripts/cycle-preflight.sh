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
#   ok:cycle-preflight:<plan-verdict>:<inference-report>
#   blocked:preflight:<component>:<detail>
#
# On windows hosts <plan-verdict> carries a `+wsl-<report>` suffix (order
# 770-f6u4, cadence decision): the instrument-rebuild principle applies to the
# WSL-side expert binary too — the MCP servers the harness launches live in the
# WSL distro and exec ~/.local/bin/tillandsias-plan there (770-ehym), so a
# cycle that rebuilds only the PE can still start with stale-or-missing
# experts after a sweep. scripts/wsl-plan-expert-ensure.sh is invoked after
# the host rebuild; its verdict is folded INTO the plan segment with colons
# re-spelled as dashes (e.g. `rebuilt+wsl-ok`,
# `rebuilt+wsl-degraded-wsl-build-failed`) so the pinned colon arity of this
# line is unchanged and no gate word appears inside an ok line. The ensure
# script is advisory by contract (always exit 0): a degraded WSL lane is a
# degraded read path, never a blocked cycle.
#
# <inference-report> is ok:*, skip:*, degraded:<reason>, or unknown — never
# blocked:*. Inference is advisory (see below), and on 2026-08-15 a failed
# forge saw the ensure script's own gating verdict pass through verbatim:
# `ok:cycle-preflight:rebuilt:blocked:install-failed:runtime-download`.
# Embedding `blocked` inside an `ok` line is contradictory to every caller
# that greps verdict grammars — it scares a grep for blocked:* and lies to a
# grep asserting ok lines carry no gate words — so an advisory fault is
# re-spelled `degraded:<reason>` here. The gating blocked:preflight:* verdicts
# below are untouched.
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

    # Windows: the WSL-side expert lifecycle is part of the instrument too
    # (770-f6u4 cadence decision; mechanism 770-ehym). Advisory — the ensure
    # script always exits 0 — and its verdict is folded into the plan segment
    # colon-free so the pinned line arity is preserved.
    case "$(uname -s 2>/dev/null)" in
        MINGW* | MSYS* | CYGWIN*)
            wsl_verdict="$(bash "$ROOT/scripts/wsl-plan-expert-ensure.sh" 2>/dev/null | tail -1)"
            case "$wsl_verdict" in
                ok:wsl-plan-expert:*) wsl_report="wsl-ok" ;;
                skip:* | degraded:*) wsl_report="wsl-$(printf '%s' "$wsl_verdict" | tr ':' '-' | cut -c1-60)" ;;
                *) wsl_report="wsl-degraded-no-verdict" ;;
            esac
            plan_verdict="${plan_verdict}+${wsl_report}"
            ;;
    esac
fi

# Inference is a REPORT, not a gate: the deterministic expert tiers work without
# it, and a cycle that cannot reach a model is degraded, not broken. Blocking
# here would strand work on a host with no network — the same reasoning that
# keeps the windows-only source report advisory.
inference_verdict="$(bash "$ROOT/scripts/dev-inference-ensure.sh" 2>/dev/null | tail -1)"
case "$inference_verdict" in
    ok:* | skip:*) : ;;
    # An advisory fault must not wear a gate word. dev-inference-ensure.sh
    # speaks blocked:* for ITS callers; inside this ok line it is a report, so
    # it is re-spelled degraded:<reason> (2026-08-15 failed-forge finding; the
    # exit-0 semantics are unchanged).
    blocked:*) inference_verdict="degraded:${inference_verdict#blocked:}" ;;
    "") inference_verdict="unknown" ;;
    # Anything unrecognized is still only a report — carry it under degraded
    # rather than letting arbitrary output shape the ok grammar. Whitespace is
    # squashed to '-' so the verdict stays one greppable token.
    *) inference_verdict="degraded:$(printf '%s' "$inference_verdict" | tr -s '[:space:]' '-' | cut -c1-80)" ;;
esac

echo "ok:cycle-preflight:${plan_verdict}:${inference_verdict}"
exit 0
