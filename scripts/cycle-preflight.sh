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
    # ORDER 876-irn7. A rustup toolchain that is not on the NON-INTERACTIVE
    # PATH is not an absent toolchain, and this is the one verdict that stops
    # the cycle outright — the skill's own words: "selecting work with an
    # unverified instrument is the one failure the loop cannot reason its way
    # out of, because the tool it would reason WITH is the stale thing."
    #
    # Measured on pirria 2026-08-25, the first tool call of its first cycle:
    # `blocked:preflight:plan:cargo-absent` on a host carrying cargo 1.98.0 and
    # rustc 1.98.0. rustup writes its PATH edit into ~/.bashrc, which a
    # non-login non-interactive bash never sources — and EVERY agent tool call
    # is exactly that kind of shell. Exporting $HOME/.cargo/bin by hand and
    # changing nothing else produced `ok:cycle-preflight:...` immediately.
    #
    # Left alone, an unattended host answers `blocked:` on every fire forever
    # while a human reading the transcript goes looking for a toolchain that is
    # already installed. So resolve through the standard install locations
    # before declaring absence — CARGO_HOME first, since a host that set it
    # meant it — and put the resolved directory on PATH for the rest of the
    # script, so the `cargo build` below and every later caller see it too.
    #
    # THE GENUINELY-ABSENT CASE KEEPS ITS VERDICT AND ITS TERMINAL FORCE. This
    # narrows a false positive; it must not weaken the true one.
    if ! command -v cargo >/dev/null 2>&1; then
        for _cargo_dir in "${CARGO_HOME:-}/bin" "$HOME/.cargo/bin"; do
            case "$_cargo_dir" in /bin) continue ;; esac
            if [ -x "$_cargo_dir/cargo" ]; then
                PATH="$_cargo_dir:$PATH"
                export PATH
                break
            fi
        done
    fi
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

    # ── ORDER 1058-fenk: THE TWO LOCI MUST AGREE ─────────────────────────────
    #
    # Everything above proves the binary runs HERE. The gate runs SOMEWHERE
    # ELSE: build.sh sources scripts/with-tillandsias-builder.sh (build.sh:44)
    # and re-execs inside the tillandsias-builder toolbox, while this script
    # has no builder line at all and builds on the host. So "the plan binary"
    # names two different runtime environments and nothing compared them.
    #
    # MEASURED by pirria 2026-09-05 on CachyOS (glibc 2.44) against
    # fedora-toolbox:42. Same file, two answers:
    #   host:    folds a minimal ledger
    #   toolbox: /lib64/libm.so.6: version `GLIBC_2.44' not found
    # Every gate red from 19:07Z at a head that had been GREEN while
    # target/release was empty — the variable was a host-built artefact, not
    # trunk. Latent on every rolling-release host that adopts the toolbox gate.
    #
    # WHAT THIS DOES AND DOES NOT DO. It NAMES the skew; it does not repair it.
    # The stronger fix is to build in the locus that consumes — this script
    # sourcing the builder the way build.sh does — but that changes where every
    # host's preflight compiles and I could not test it beyond this one, so it
    # is recommended rather than done. Naming satisfies the criterion and
    # cannot break a host that has no skew.
    #
    # Silent on hosts where the question does not arise: no builder wrapper, or
    # a gate that does not re-exec, means one locus and nothing to compare.
    # Never blocks — a cycle that can still build should not be stopped by a
    # cross-locus report, and the gate is where the consequence lands.
    _builder="$ROOT/scripts/with-tillandsias-builder.sh"
    if [ -r "$_builder" ] && grep -q 'with-tillandsias-builder.sh' "$ROOT/build.sh" 2>/dev/null; then
        # A SENTINEL FROM THE INNER COMMAND, not the contents of the streams.
        # The wrapper announces itself on stderr ("Re-execing inside
        # 'tillandsias-builder' toolbox..."), and a first cut here treated any
        # stderr as failure — reporting skew on this host, where both loci had
        # already been measured to run the binary. The verdict must come from
        # the thing under test, not from whatever else wrote to the terminal.
        _locus_out="$(timeout 180 bash "$_builder" sh -c \
            "if '$plan_bin' capabilities >/dev/null 2>&1; then echo LOCUS_OK; \
             else echo \"LOCUS_FAIL:\$('$plan_bin' capabilities 2>&1 >/dev/null | head -1)\"; fi" 2>&1)"
        _locus_rc=$?
        case "$_locus_out" in
            *LOCUS_OK*) : ;;  # both loci run it; nothing to report
            *)
            _why="$(printf '%s' "$_locus_out" | grep -o 'LOCUS_FAIL:.*' | cut -c12-160)"
            [ -n "$_why" ] || _why="the builder could not be entered (exit $_locus_rc)"
            echo "warn:preflight:plan:locus-skew: the binary runs here and NOT inside the builder toolbox the gate uses"
            echo "warn:preflight:plan:locus-skew-reason:${_why:-no output, exit $_locus_rc}"
            echo "  This host builds tillandsias-plan on the host and gates inside the"
            echo "  toolbox (build.sh sources with-tillandsias-builder.sh). Those are"
            echo "  different runtimes, and this binary links in only one of them, so"
            echo "  the gate will report ledger faults that are really instrument"
            echo "  faults (1058-fenk, pirria on CachyOS 2.44 vs fedora-toolbox:42)."
            echo "  Remedy: build the binary where it is consumed —"
            echo "    bash scripts/with-tillandsias-builder.sh cargo build --release -p tillandsias-plan"
            ;;
        esac
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
    # ORDER 1060-wxdh: the decision lives in the probe, which runs the binary
    # before installing it. See refresh_plan_binary_copy for what this cost.
    expert_report="$(refresh_plan_binary_copy "$plan_bin" "$expert_bin")"
    if [ "$expert_report" = "refresh-refused-not-runnable" ]; then
        echo "warn:preflight:plan:expert-refresh-refused: $plan_bin does not run here, so it was NOT installed over $expert_bin (1060-wxdh)"
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
    # ORDER 994-8r3w. TELL THE CHECK WHAT TO EXPECT, or its absent= counter is a
    # structural constant. The absent-detection loop has always been correct and
    # has never been given an expectation: EXPECTED defaults to empty and no
    # production caller set it, so a service that had ceased to exist reported as
    # healthy. MEASURED here 2026-09-03 with the proxy removed:
    # `ok:enclave-service-health:services=3:up=3:down=0:dead=0:absent=0`.
    #
    # The list is DECLARED (images/default/enclave-services.txt) because a health
    # check cannot derive what should exist from what does — that is circular.
    # A Rust test keeps it in step with the dependency graph that launches them.
    # ORDER 1004-inkc — THE SET AND ITS ANCHOR RULE NOW LIVE IN THE CHECK.
    #
    # This block used to read images/default/enclave-services.txt, apply the
    # vault-anchor rule, and export TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES before
    # invoking the check. That made the verdict depend on WHO INVOKED IT: the
    # same script run by hand — as an operator does, and as lenovinha did on
    # 2026-09-04 — got no declaration at all and reported
    # `ok:...:services=5:absent=0` on a host whose declared proxy had been
    # DELETED. 994-8r3w named this as its own unmet criterion 3: "nothing yet
    # fails if a future edit stops preflight exporting the variable."
    #
    # A guard whose answer depends on its caller is not a guard, so the default
    # and the anchor moved into check-enclave-service-health.sh, where every
    # invocation gets them. Preflight now just CONSUMES the verdict.
    #
    # Nothing is passed deliberately: an explicit --expect here would restore
    # exactly the caller-supplied behaviour this order removed, one layer up.
    _svc_err="$(mktemp "${TMPDIR:-/tmp}/cycle-preflight-services.XXXXXX")"
    # --act (878-79b5): the unattended cycle is exactly the caller that must
    # FIX what it can prove needs fixing — four yoga cycles re-noted one
    # stopped proxy for nine hours. The acting ladder never fights an
    # operator (hold marker, grace window, whole-stack-down all refuse).
    services_line="$(bash "$ROOT/scripts/check-enclave-service-health.sh" --act 2>"$_svc_err" | tail -1)"
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

# ORDER 975-rsgm. The service check answers "are the containers running?" and
# cannot see a proxy that will START and then DIE because its certificate and
# its private key no longer match. That is a real state this host sat in: five
# cycles of `fail:enclave-service-start-failed:...:action=operator`, where the
# cause was a CA regenerated without rotating the `tillandsias-ca-key` secret,
# and squid's own last words named neither file.
#
# ADVISORY, never a gate — a desynced CA degrades egress, it does not make the
# cycle unsafe, and a preflight that refuses on it would strand a host that can
# still do most of its work.
ca_report="skip"
if [ -x "$ROOT/scripts/check-enclave-ca-consistency.sh" ]; then
    _ca_err="$(mktemp)"
    ca_line="$(bash "$ROOT/scripts/check-enclave-ca-consistency.sh" 2>"$_ca_err" | tail -1)"
    case "$ca_line" in
        ok:enclave-ca-consistent) ca_report="ok" ;;
        desync:*|absent:*)
            ca_report="${ca_line%%:*}"
            cat "$_ca_err" >&2
            ;;
        skip:*) ca_report="skip" ;;
        *) ca_report="no-verdict" ;;
    esac
    rm -f "$_ca_err"
fi
[ "$ca_report" = "ok" ] || [ "$ca_report" = "skip" ] && : || plan_verdict="${plan_verdict}+ca-${ca_report}"

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
