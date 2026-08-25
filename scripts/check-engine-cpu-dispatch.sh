#!/usr/bin/env bash
# @trace order:861-n7f5, order:392, spec:inference-container
#
# check-engine-cpu-dispatch.sh — does this engine BUILD dispatch the vector
# features this host actually has?
#
# WHY THIS EXISTS. Measured on esmeraldinha 2026-08-23: Fedora 44's packaged
# `llama-cpp` (b6153-3.fc44) is 12.8x slower on prefill and 4.0x slower on
# decode than ollama, running the IDENTICAL GGUF blob on the same four cores.
# Both are llama.cpp. The engine is not the variable — the BUILD is. Fedora's
# reports `CPU : LLAMAFILE = 1 | REPACK = 1` and no AVX, AVX2, FMA or AVX_VNNI
# on a host whose published capability row lists all four.
#
# The wrong conclusion is cheap to reach and expensive to hold: "ollama is a
# wrapper, so the bare engine must be leaner" would have cost a 12.8x prefill
# regression, and the benchmark that revealed it would have read as "this host
# is slow" — which, on the fleet's designated FLOOR host, is exactly the reading
# nobody would question. Order 392 already ruled on the accelerator sibling of
# this shape (a GPU tier in name only is worse than no GPU tier). This is the
# CPU lane's version of that rule, and until now it had no check.
#
# WHAT IT DOES NOT DO. It does not benchmark, does not load a model, and does
# not judge speed. It answers one question — which vector features the build
# will use — and refuses a candidate whose build ignores features the host
# advertises. A refused candidate may still be benchmarked deliberately; what
# it may not do is enter the ledger as an engine-lane measurement (criterion 2).
#
# THE HOST'S HALF COMES FROM THE CAPABILITY ROW, NEVER A SECOND PROBE
# (criterion 3). accel_probe already publishes `cpu_flags` into the capabilities
# channel; `tillandsias-plan capability-matrix --cpu-flags <host>` is its
# machine-readable face. 859-b2zc is the standing reminder of what re-deriving
# one probe in a second place costs. Override with ENGINE_DISPATCH_HOST_FLAGS
# only for fixtures and for a host whose row is not published yet — and the
# verdict says so, so a fixture reading is never mistaken for a matrix reading.
#
# Grammar (exactly one line):
#   ^(ok:engine-cpu-dispatch:[a-z0-9_,-]+|refused:engine-cpu-dispatch-baseline:[a-z0-9_,-]+|unavailable:[a-z0-9-]+)$
#
# Exit codes: 0 = the build dispatches every advertised feature it is checked
# for; 1 = refused (the build is a baseline build on a vector host); 2 = could
# not determine (report, never guess — an unreadable build is not a passing one).
#
# Usage:
#   scripts/check-engine-cpu-dispatch.sh /usr/bin/llama-server
#   ENGINE_DISPATCH_HOST_FLAGS=avx,avx2,fma scripts/check-engine-cpu-dispatch.sh ./llama-cli
#
# Fixture seam: ENGINE_DISPATCH_SYSINFO_CMD replaces the engine invocation, so
# the hermetic test never needs a real engine binary.
#
# Dependencies: coreutils, grep, sed, tr. No python (forbidden for committed
# automation); no jq on the required path.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The features that MATTER for ggml's CPU path, in the order a reader expects.
# Deliberately NOT "every flag /proc/cpuinfo lists": a build that skips `sse2`
# on an x86-64 host is not a thing that happens, and a check that compares
# hundreds of flags produces noise rather than a verdict. These four are the
# ones the measured 12.8x turned on.
CHECKED_FEATURES="${ENGINE_DISPATCH_CHECKED_FEATURES:-avx avx2 fma avx_vnni}"

emit() { echo "$1"; exit "$2"; }

engine="${1:-}"
if [ -z "$engine" ]; then
    echo "[check-engine-cpu-dispatch] usage: $0 <engine-binary>" >&2
    emit "unavailable:no-engine-given" 2
fi

# ---------------------------------------------------------------- host flags
host_flags=""
host_source="capability-row"
if [ -n "${ENGINE_DISPATCH_HOST_FLAGS:-}" ]; then
    host_flags="$(echo "$ENGINE_DISPATCH_HOST_FLAGS" | tr 'A-Z, ' 'a-z\n\n')"
    host_source="override"
else
    # shellcheck source=scripts/plan-binary-probe.sh
    . "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
    # shellcheck source=scripts/agent-identity.sh
    . "$ROOT/scripts/agent-identity.sh" 2>/dev/null || true
    if ! command -v resolve_plan_binary >/dev/null 2>&1; then
        emit "unavailable:no-plan-binary-probe" 2
    fi
    PLAN="$(resolve_plan_binary 2>/dev/null)" || emit "unavailable:no-runnable-plan-binary" 2
    host="$(tillandsias_lower "$(tillandsias_agent_workstation)" 2>/dev/null)"
    [ -n "$host" ] || emit "unavailable:host-unresolvable" 2
    row="$("$PLAN" capability-matrix --cpu-flags "$host" 2>/dev/null)" \
        || emit "unavailable:capability-matrix-failed" 2
    # Absent from the matrix prints nothing — that is a DIFFERENT fact from a
    # row that reports no flags, and the caller must be able to tell them apart.
    [ -n "$row" ] || emit "unavailable:no-capability-row" 2
    csv="$(printf '%s\n' "$row" | head -1 | cut -f2)"
    [ "$csv" = "none" ] && emit "unavailable:capability-row-has-no-cpu-flags" 2
    host_flags="$(echo "$csv" | tr 'A-Z,' 'a-z\n')"
fi

# ------------------------------------------------------------- engine sysinfo
# llama.cpp prints its dispatch table on stderr at startup, e.g.
#   system_info: n_threads = 4 | AVX = 1 | AVX2 = 1 | FMA = 1 | AVX_VNNI = 0 | ...
# and `--version` is enough to provoke it on every build since b3xxx. We take
# stdout+stderr and do not care which stream carried it.
if [ -n "${ENGINE_DISPATCH_SYSINFO_CMD:-}" ]; then
    sysinfo="$(eval "$ENGINE_DISPATCH_SYSINFO_CMD" 2>&1)"
else
    [ -x "$engine" ] || emit "unavailable:engine-not-executable" 2
    sysinfo="$(timeout 30 "$engine" --version 2>&1)"
    # Some builds say nothing useful for --version; --help carries the same
    # table on others. One retry, then give up rather than guess.
    case "$sysinfo" in
        *[Aa][Vv][Xx]*|*LLAMAFILE*|*REPACK*) : ;;
        *) sysinfo="$(timeout 30 "$engine" --help 2>&1)" ;;
    esac
fi
[ -n "$sysinfo" ] || emit "unavailable:engine-emitted-nothing" 2

# The dispatch table must actually be present. A build that printed a version
# banner and no table tells us NOTHING about dispatch, and reporting that as a
# pass is precisely the order-531 shape this project keeps re-learning.
case "$sysinfo" in
    *[Aa][Vv][Xx]\ =\ *|*LLAMAFILE\ =\ *|*REPACK\ =\ *) : ;;
    *) emit "unavailable:no-dispatch-table" 2 ;;
esac

# ------------------------------------------------------------------- compare
# `FEATURE = 1` means dispatched; `FEATURE = 0` or absent means it is not.
dispatched=""
missing=""
for f in $CHECKED_FEATURES; do
    upper="$(echo "$f" | tr 'a-z' 'A-Z')"
    host_has=0
    printf '%s\n' "$host_flags" | grep -qx -- "$f" && host_has=1
    build_has=0
    printf '%s\n' "$sysinfo" | grep -qE "(^|[^A-Z_])${upper} = 1([^0-9]|$)" && build_has=1
    if [ "$build_has" = 1 ]; then
        dispatched="${dispatched:+$dispatched,}$f"
    fi
    if [ "$host_has" = 1 ] && [ "$build_has" = 0 ]; then
        missing="${missing:+$missing,}$f"
    fi
done

if [ -n "$missing" ]; then
    {
        echo "[check-engine-cpu-dispatch] REFUSED: this build ignores vector features this host has."
        echo "  host advertises ($host_source): $(printf '%s\n' "$host_flags" | tr '\n' ',' | sed 's/,$//')"
        echo "  build dispatches:               ${dispatched:-none}"
        echo "  ignored by the build:           $missing"
        echo "  A baseline build on a vector host is a MISCONFIGURATION, not a candidate."
        echo "  It benchmarks as a regression nobody can explain (861-n7f5: 12.8x prefill)."
    } >&2
    emit "refused:engine-cpu-dispatch-baseline:$missing" 1
fi

emit "ok:engine-cpu-dispatch:${dispatched:-none}" 0
