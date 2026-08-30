#!/usr/bin/env bash
# ORDER 917-zkge, exit criterion 4 — the instrumentation half.
#
# "A cache nobody measures is indistinguishable from a cache nobody uses."
# That sentence is in the packet as a warning; today it is a DESCRIPTION. The
# per-host metrics files exist, are readable, are wired up, and assert nothing.
# A reader glancing at .cache/metrics/ sees measurement.
#
# This records ONE row per build into .cache/metrics/nix-cache.jsonl. Schema
# fixed fleet-wide so rows from different hosts compose without reconciliation:
#
#   ts                  ISO8601 UTC
#   host                fleet host id
#   lane                enclave | toolbox | guest-binaries | e2e
#   run_id              free string, caller's own correlator
#   with_substituter    bool — was a substituter in the flag list
#   substituter_url     string or null
#   paths_substituted   int
#   paths_built         int
#   hit_rate            substituted/(substituted+built), null when denominator 0
#   wall_ms             int
#   treatment_verified  STRING, never a bool: HOW the caller proved the
#                       substituter was actually consulted
#
# WHY treatment_verified IS A STRING. A with/without comparison whose "with"
# run never reached the cache produces a clean hit_rate of 0.0 and reads as a
# real measurement — a true number under a label that was never applied. That
# failure shape cost the fleet two mislabelled measurement runs on 2026-08-29
# (a budget column set client-side that the server never saw; a model env var
# inherited from a previous experiment). A bool would let a caller assert the
# treatment; a string makes them state the evidence, and a reader can judge it.
#
# So: with_substituter=true REQUIRES treatment_verified, and this script refuses
# the row otherwise. A refused row is a hole in the series, which is honest. A
# fabricated row is worse than no row, because nothing downstream can tell it
# from a real one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/metrics-log-path.sh
. "$SCRIPT_DIR/metrics-log-path.sh"

_fail() { echo "record-nix-cache-metrics: $*" >&2; exit 2; }

usage() {
    cat >&2 <<'USAGE'
usage: record-nix-cache-metrics.sh --lane <enclave|toolbox|guest-binaries|e2e>
         --run-id <s> --wall-ms <n>
         --substituted <n> --built <n>
         [--with-substituter] [--substituter-url <url>]
         [--treatment-verified <how you proved the substituter was consulted>]
         [--host <id>] [--ts <ISO8601>]

--treatment-verified is REQUIRED with --with-substituter, and must say HOW
(e.g. "nix log shows querying https://... for 563 paths"). It is not a bool.
USAGE
    exit 2
}

lane=""; run_id=""; wall_ms=""; substituted=""; built=""
with_sub=false; sub_url=""; verified=""; host=""; ts=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lane) lane="${2:-}"; shift 2 ;;
        --run-id) run_id="${2:-}"; shift 2 ;;
        --wall-ms) wall_ms="${2:-}"; shift 2 ;;
        --substituted) substituted="${2:-}"; shift 2 ;;
        --built) built="${2:-}"; shift 2 ;;
        --with-substituter) with_sub=true; shift ;;
        --substituter-url) sub_url="${2:-}"; shift 2 ;;
        --treatment-verified) verified="${2:-}"; shift 2 ;;
        --host) host="${2:-}"; shift 2 ;;
        --ts) ts="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) _fail "unknown option '$1'" ;;
    esac
done

case "$lane" in
    enclave|toolbox|guest-binaries|e2e) ;;
    "") _fail "--lane is required" ;;
    *) _fail "unknown lane '$lane' — the vocabulary is closed (enclave|toolbox|guest-binaries|e2e); a lane nobody recognises makes the series unqueryable" ;;
esac
[[ -n "$run_id" ]] || _fail "--run-id is required"
for n in wall_ms substituted built; do
    v="${!n}"
    [[ -n "$v" ]] || _fail "--${n//_/-} is required"
    [[ "$v" =~ ^[0-9]+$ ]] || _fail "--${n//_/-} must be a non-negative integer, got '$v'"
done

# THE GUARD THIS FILE EXISTS FOR.
if [[ "$with_sub" == true && -z "${verified//[[:space:]]/}" ]]; then
    _fail "--with-substituter requires --treatment-verified naming HOW the substituter was proved consulted.
  A 'with' run that never reached the cache yields hit_rate 0.0 and reads as a real measurement.
  Refusing the row: a hole in the series is honest, a fabricated row is not (917-zkge)."
fi
if [[ "$with_sub" != true && -n "${verified//[[:space:]]/}" ]]; then
    _fail "--treatment-verified was given without --with-substituter — it attests to a treatment this row says was not applied"
fi

[[ -n "$host" ]] || host="$("$SCRIPT_DIR/agent-identity.sh" host 2>/dev/null || hostname -s)"
[[ -n "$ts" ]] || ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

denom=$(( substituted + built ))
LOG="${TILLANDSIAS_NIX_CACHE_METRICS_LOG:-$(metrics_default_log nix-cache.jsonl)}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# jq builds the row so a URL or an evidence string containing quotes cannot
# corrupt the series.
if command -v jq >/dev/null 2>&1; then
    jq -nc \
        --arg ts "$ts" --arg host "$host" --arg lane "$lane" --arg run_id "$run_id" \
        --argjson with_sub "$with_sub" \
        --arg sub_url "$sub_url" --arg verified "$verified" \
        --argjson substituted "$substituted" --argjson built "$built" \
        --argjson denom "$denom" --argjson wall_ms "$wall_ms" \
        '{ts:$ts, host:$host, lane:$lane, run_id:$run_id,
          with_substituter:$with_sub,
          substituter_url:(if $sub_url == "" then null else $sub_url end),
          paths_substituted:$substituted, paths_built:$built,
          hit_rate:(if $denom == 0 then null else (($substituted / $denom) * 10000 | floor) / 10000 end),
          wall_ms:$wall_ms,
          treatment_verified:(if $verified == "" then null else $verified end)}' >> "$LOG" \
        || _fail "could not append to $LOG"
else
    _fail "jq is required to write a well-formed row"
fi

echo "ok:nix-cache-metric-recorded:$LOG"
