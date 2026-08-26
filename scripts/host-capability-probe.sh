#!/usr/bin/env bash
# @trace order:850-bif2, spec:accel-capability-probe
#
# host-capability-probe.sh — emit this host's capability row (Linux/macOS
# bare-metal and forge loci), the sibling of
# scripts/windows-host-capability-probe.sh, which remains the generator for
# the windows-host locus.
#
# WHY (order 850-bif2). The capability matrix was silent for 5 of 7 hosts —
# not because probes failed, but because nothing generated a row outside
# Windows: Linux rows were hand-assembled around probe output, and one was
# filed through an unquoted heredoc that executed its own backticks into an
# immutable fragment. This wraps the REAL probe (`tillandsias --capabilities`,
# accel_probe.rs) into a ready-to-file fragment, deterministically.
#
# Reads nothing in the repo, writes nothing anywhere: stdout only. The caller
# redirects into plan/index.d/<utc>-capability-row-<host>-<writer>.yaml and
# commits it like any fragment.
#
# Flags:
#   --fragment      emit a ledger fragment (default: the bare document JSON)
#   --locus L       override the locus (default: in-guest when
#                   TILLANDSIAS_HOST_KIND=forge, else bare-metal)
#   --writer W      override the writer host-kind label (default detected:
#                   forge | linux_immutable | linux_mutable | macos)
#   --ts T          override the row timestamp (default: now UTC)
#
# Seams: TILLANDSIAS_HEADLESS_BIN names the probe binary explicitly (fixture
# use); otherwise ./target/release/tillandsias is preferred over the installed
# `tillandsias`, each verified by RUNNING it — an executable bit is a claim,
# running is evidence (the plan-binary-probe rule).
set -uo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/tool-dispatch.sh" 2>/dev/null || true
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

MODE="document"
LOCUS=""
WRITER=""
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while [ $# -gt 0 ]; do
    case "$1" in
        --fragment) MODE="fragment" ;;
        --locus) shift; LOCUS="${1:?--locus needs a value}" ;;
        --writer) shift; WRITER="${1:?--writer needs a value}" ;;
        --ts) shift; TS="${1:?--ts needs a value}" ;;
        *) echo "usage: host-capability-probe.sh [--fragment] [--locus L] [--writer W] [--ts T]" >&2; exit 2 ;;
    esac
    shift
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

# ── resolve a probe binary by RUNNING it ─────────────────────────────────────
resolve_probe() {
    local candidate
    for candidate in "${TILLANDSIAS_HEADLESS_BIN:-}" ./target/release/tillandsias tillandsias; do
        [ -n "$candidate" ] || continue
        if "$candidate" --inference-tier >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}
PROBE="$(resolve_probe)" || { echo "error: no runnable tillandsias binary (build or install one)" >&2; exit 2; }

# --capabilities prints the one-line envelope, then the pretty JSON document.
# --fresh (order 852-dk9z) makes the probe bypass its own cache, so a published
# row is a fresh probe BY CONSTRUCTION. Without it a rebuilt binary served its
# predecessor's document and this generator wrapped it into a row that looked
# like the new code's output — measured on yoga (850-bif2) and again on pirria
# (856-fwyh). Harmless against an older binary, which ignores unknown flags.
raw="$("$PROBE" --capabilities --fresh 2>/dev/null)" || { echo "error: $PROBE --capabilities failed" >&2; exit 1; }
# The `;` before `}` is required by BSD sed (macOS) and harmless on GNU —
# without it the probe failed on the exact host kind 850-bif2 exists to make
# visible (851-28b5 defect class, found on the first macOS run). BOTH fixes are
# kept: --fresh and the BSD-safe sed address DIFFERENT faults and arrived from
# different hosts in the same merge (concurrent_correct_fixes).
doc="$(printf '%s\n' "$raw" | sed '1{/^accel_class=/d;}')"
printf '%s' "$doc" | "$JQ" -e '.schema_version == 2 and (.host.host_id | length > 0)' >/dev/null \
    || { echo "error: probe document is not a valid schema-2 capability document with a host_id" >&2; exit 1; }

if [ "$MODE" = "document" ]; then
    printf '%s\n' "$doc"
    exit 0
fi

# ── fragment assembly ────────────────────────────────────────────────────────
host_id="$(printf '%s' "$doc" | "$JQ" -r '.host.host_id')"
if [ -z "$LOCUS" ]; then
    if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then LOCUS="in-guest"; else LOCUS="bare-metal"; fi
fi
if [ -z "$WRITER" ]; then
    if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
        WRITER="forge"
    elif [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        WRITER="macos"
    elif [ -e /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1; then
        WRITER="linux_immutable"
    else
        WRITER="linux_mutable"
    fi
fi

cat <<EOF
# Ledger fragment — append-only, IMMUTABLE once written.
# Capability row for host_id '$host_id' (locus $LOCUS), generated by
# scripts/host-capability-probe.sh --fragment (order 850-bif2) around the
# accel_probe.rs document — never hand-assembled (the unquoted-heredoc
# incident on this packet is why this generator exists).
# NOTE: compaction deliberately refuses to fold 'capabilities:' fragments
# (order 843-624y) — the channel has no base representation yet (846-idhn).
capabilities:
  - ts: "$TS"
    host: $WRITER
    locus: $LOCUS
    document:
EOF
printf '%s\n' "$doc" | sed 's/^/      /'
