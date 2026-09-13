#!/usr/bin/env bash
# @trace order:850-bif2, spec:accel-capability-probe, order:1125-wi4d
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
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
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
# ORDER 1172-dyvd. RUNNING IS NOT CURRENT, and this resolver's admission test
# could not tell the difference.
#
# It accepted any candidate whose `--inference-tier` exited 0. That proves the
# binary RUNS. It says nothing about whether the binary knows the vocabulary the
# ledger is written in — and this script WRITES THE LEDGER, so a candidate that
# runs and is stale publishes a confident wrong capability row.
#
# MEASURED on yolanda 2026-09-13, both binaries present, same command:
#
#   ./target/release/tillandsias   PE32+, 2026-08-29, --inference-tier rc 0
#     -> accel_gpu=none accel_npu=none accel_ram_gb=-   (no accel_side key at all)
#   ./target/debug/tillandsias.exe PE32+, 2026-09-13
#     -> accel_gpu=present-unusable accel_gpu_name=AMD_Radeon_TM_860M_Graphics
#        accel_npu=present-unusable accel_npu_name=NPU_Compute_Accelerator_Device
#
# The stale one won, because it is the extensionless `./target/release/tillandsias`
# this loop tries second. The row it published on 2026-09-12 is on the matrix
# saying this host has no GPU and no NPU; it has both. The matrix is what
# scheduling reads.
#
# THE CHECK IS A VOCABULARY PROBE, NOT A TIMESTAMP, and that ordering is
# deliberate. `accel_side` is emitted unconditionally in the envelope by every
# current build on every platform (accel_probe.rs's envelope format string; the
# function answers "unknown-side" for a pre-schema-3 document rather than being
# absent), so its ABSENCE is a property of the BINARY. An mtime comparison is a
# property of the FILESYSTEM: a fresh clone stamps every source file with the
# checkout time, which is newer than any pre-built binary, and would refuse
# every candidate on a host that had done nothing wrong. So mtime is an
# ADVISORY here and never the refusal.
#
# A REFUSED CANDIDATE IS NAMED AND THE LOOP CONTINUES. Silence was the defect;
# a stale candidate that loses to a current one later in the list should say so,
# because the operator's next question is "why is it not using the one I built".
resolve_probe() {
    local candidate
    for candidate in "${TILLANDSIAS_HEADLESS_BIN:-}" ./target/release/tillandsias tillandsias; do
        [ -n "$candidate" ] || continue
        "$candidate" --inference-tier >/dev/null 2>&1 || continue
        if "$candidate" --capabilities 2>/dev/null | grep -q 'accel_side='; then
            printf '%s\n' "$candidate"
            return 0
        fi
        printf 'refused:probe:stale-candidate:%s\n' "$candidate" >&2
        printf '  it RUNS but its --capabilities omits accel_side, so it predates the\n' >&2
        printf '  current envelope contract and would publish a row in an older\n' >&2
        printf '  vocabulary. Rebuild it, or set TILLANDSIAS_HEADLESS_BIN to a current\n' >&2
        printf '  binary. Refusing rather than publishing what it reports (1172-dyvd).\n' >&2
    done
    return 1
}
PROBE="$(resolve_probe)" || { echo "error: no CURRENT tillandsias binary (build or install one; a stale candidate that was refused is named above, 1172-dyvd)" >&2; exit 2; }

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
# A FLOOR, NOT AN EQUALITY (order 793-qr4t). This read `== 2`, and the schema
# bump to 3 turned every host's publisher into a hard refusal — the row could
# not be republished by the very change that made the row worth republishing.
# An equality test says "I understand exactly this version", which is the
# opposite of what a consumer that only reads `.host.host_id` needs; the two
# fields checked here have existed since 2 and the document is additive by
# construction (every field added since is `Option` + `serde(default)`). A
# floor refuses a document too OLD to describe itself, which is the fault this
# check was written for, and stops refusing documents that are merely newer.
printf '%s' "$doc" | "$JQ" -e '.schema_version >= 2 and (.host.host_id | length > 0)' >/dev/null \
    || { echo "error: probe document is not a schema-2-or-later capability document with a host_id" >&2; exit 1; }

if [ "$MODE" = "document" ]; then
    printf '%s\n' "$doc"
    exit 0
fi

# ── fragment assembly ────────────────────────────────────────────────────────
host_id="$(printf '%s' "$doc" | "$JQ" -r '.host.host_id')"
# ORDER 1125-wi4d. ASK THE DOCUMENT, DO NOT GUESS AGAIN. The probe already
# answered what kind of host this is — `.host.host_kind` — and host_id is read
# from that same document one line above. Both derivations below used to fall
# through a uname/ostree chain with no windows branch, so a Windows host was
# labelled `linux_mutable` at a locus of `bare-metal`, while its own embedded
# document said host_kind "windows" and every Windows row already in the
# compacted base said windows-host.
#
# The two halves failed DIFFERENTLY and that is worth keeping straight:
#   * the locus wedged the host. The fold keys on host_id+locus, so
#     yolanda/bare-metal was a first-ever key, the fold dropped the fragment,
#     the corpus read PARTIAL and release-preflight refused the PUSH
#     (blocked:plan-ledger-incomplete). See 1128-4ffr.
#   * the label misrouted work. capability-aware routing (847-wgy4) reads the
#     row to decide what kind of host it is talking to; a row that says
#     linux_mutable on a Windows box routes confidently and wrongly.
# Measured 2026-09-12 by folding one fragment at a time against a baselined
# copy of the real ledger: (linux_mutable, bare-metal) -> dropped-entry,
# corpus partial; (linux_mutable, windows-host) -> 0 dropped; (windows,
# windows-host) -> 0 dropped. So the locus alone unwedges, and the label alone
# was never the blocker — both are fixed here because both are wrong.
host_kind="$(printf '%s' "$doc" | "$JQ" -r '.host.host_kind // empty')"
if [ -z "$LOCUS" ]; then
    if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
        LOCUS="in-guest"
    elif [ "$host_kind" = "windows" ]; then
        LOCUS="windows-host"
    else
        LOCUS="bare-metal"
    fi
fi
if [ -z "$WRITER" ]; then
    if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
        WRITER="forge"
    elif [ "$host_kind" = "windows" ]; then
        WRITER="windows"
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
