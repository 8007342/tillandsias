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

# Resolve the DEVELOPMENT ENVIRONMENT declaration before anything reads an
# expert. The resolver exports TILLANDSIAS_HOST_EXPERTS only on a host that has
# declared itself, refuses inside a forge (the enclave's END USER RUNTIME owns
# its own expert lifecycle), and never overrides a value the caller already
# set. Sourcing it is a no-op on every other host, and it sets no shell options.
if [ -f "$ROOT/scripts/dev-host-experts.sh" ]; then
    . "$ROOT/scripts/dev-host-experts.sh"
fi
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

    # Order 799-m2vk. The instrument this step rebuilds is the one under
    # ./target/release. The MCP experts the harness actually queries exec a
    # DIFFERENT copy — $HOME/.local/bin/tillandsias-plan, the PLAN_BIN_CANONICAL
    # of images/default/config-overlay/mcp/forge-plan.sh. Rebuilding one and
    # reading the other is how a cycle opens with a fresh binary and a stale
    # expert, and "rebuild the instrument before using it" quietly stops being
    # true for every read that goes through MCP — which CLAUDE.md makes the
    # DEFAULT read path.
    #
    # Measured on macuahuitl 2026-08-17: the installed expert was ~9h old, so
    # methodology_ask answered `unsupported` for a rule that had just landed and
    # that the freshly built binary routed at confidence=exact. Nothing was
    # broken and nothing said so.
    #
    # The Windows lane below already acts on exactly this principle for its WSL
    # copy (770-f6u4 / 770-ehym). This is the same fix for the local copy.
    #
    # Conservative by construction: only refreshes a path that ALREADY exists,
    # so a host that does not install the expert is untouched; installs the
    # binary that just passed resolve_plan_binary, never a hardcoded path
    # (704-zcgi); and never blocks — a failed refresh is a report, because a
    # stale expert is bad but refusing to start the cycle is worse.
    expert_bin="${HOME}/.local/bin/tillandsias-plan"
    expert_report="absent"
    if [ -e "$expert_bin" ]; then
        if cmp -s "$plan_bin" "$expert_bin"; then
            expert_report="current"
        elif install -m0755 "$plan_bin" "$expert_bin" 2>/dev/null; then
            expert_report="refreshed"
        else
            expert_report="refresh-failed"
        fi
    fi
    plan_verdict="${plan_verdict}+expert-${expert_report}"

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

# Enclave service health (order 798-tk7b). The blind spot this closes is
# EXACTLY this position in the cycle: tillandsias-nix sat Exited(143) for three
# days and tillandsias-vault Exited(137) for five hours while cycle after cycle
# started on this host, several of them using podman heavily, and nothing on
# the path a cycle actually walks ever said so. This is that path.
#
# A REPORT, never a gate, and folded colon-free like +expert-* so the pinned
# line arity is preserved. A host whose stack is simply not running has every
# service down; blocking there would strand every cycle on a freshly booted
# laptop, and a check that stops honest work is a check someone switches off.
# The per-service detail — exit code, derived signal, age, and whether podman
# is still advertising a stale `healthy` — goes to stderr where the operator
# reading the preflight sees it.
#
# ONE reading, not two. Calling the script once for its verdict and again for
# its detail would let a service die between the two calls and print a detail
# block that disagrees with the summary beside it.
services_report="skipped"
if [ -x "$ROOT/scripts/check-enclave-service-health.sh" ]; then
    _svc_err="$(mktemp "${TMPDIR:-/tmp}/cycle-preflight-services.XXXXXX")"
    services_line="$(bash "$ROOT/scripts/check-enclave-service-health.sh" 2>"$_svc_err" | tail -1)"
    case "$services_line" in
        ok:enclave-service-health:*) services_report="ok" ;;
        degraded:enclave-service-health:*)
            _down="$(printf '%s' "$services_line" | sed -n 's/.*:down=\([0-9][0-9]*\).*/\1/p')"
            _absent="$(printf '%s' "$services_line" | sed -n 's/.*:absent=\([0-9][0-9]*\).*/\1/p')"
            services_report="down${_down:-unknown}"
            [ "${_absent:-0}" != "0" ] && services_report="${services_report}-absent${_absent}"
            cat "$_svc_err" >&2
            ;;
        blocked:enclave-service-health:*)
            services_report="$(printf '%s' "${services_line#blocked:enclave-service-health:}" | cut -c1-30)"
            ;;
        *) services_report="no-verdict" ;;
    esac
    rm -f "$_svc_err"
fi
plan_verdict="${plan_verdict}+services-${services_report}"

# Host-state security migration (order 791-swxt). Runs SILENTLY and never
# touches this script's verdict line, so the pinned arity is unaffected.
#
# It belongs here rather than in the tray because the exposure it repairs
# cannot be repaired by the tray: 755-qcxh made ensure_ca_bundle create the CA
# key 0600 and heal a pre-fix key down, but that heal lives in the BINARY, and
# every host runs the published release, which predates the fix. Two hosts
# were found with a world-readable CA private key days after the packet
# closed. A checkout-side step reaches every host on its next cycle without
# waiting for a release — which is the whole point.
#
# Best-effort by construction: a failure here must never block a cycle (the
# key being 0644 is bad, but refusing to work is worse), and the script is
# idempotent, so the common path is two stat calls.
if [ -x "$ROOT/scripts/clamp-ca-material.sh" ]; then
    bash "$ROOT/scripts/clamp-ca-material.sh" --fix >/dev/null 2>&1 || true
fi

# A guard/asset skew advisory used to run here (783-6rik,
# scripts/check-guard-asset-skew.sh). RETIRED 2026-08-17, deleted not disabled.
#
# It compared the checkout's images/ against the tree materialized from the
# installed binary and announced at cycle start that a checkout guard needed an
# asset this host had not installed. The message was true and useless: it named
# the same fact scripts/check-credential-channel.sh already names AT THE POINT
# OF FAILURE, where a reader is actually looking, and with more precision (that
# guard probes the running mirror image and distinguishes probe-absent from
# probe-present-but-silent). Announcing it earlier and vaguer bought nothing,
# and it knew about exactly one asset, so it could only ever repeat that one
# message.
#
# The lesson is worth more than the script: THREE layers were built here in one
# night — a message fix, then a detector for the message, then a blocker doc —
# and not one of them let a lane drain. Version skew between a checkout and an
# installed release is fixed by installing a release, not by detecting it more
# eloquently. A detector for staleness is not a substitute for freshness.

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
