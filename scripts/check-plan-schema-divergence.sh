#!/bin/sh
# @trace order:744-agyy (order 440, order 720-24u6)
# Plan/schema status vocabulary divergence check (order 440, 744-agyy).
# Exits 0 if plan/index.yaml default_status_values and plan/schema.yaml statuses
# are identical. Emits a one-line verdict:
#   ok:status-vocab-in-sync
#   blocked:status-vocab-diverges: <details>
#   blocked:index-load-failed: <file>: <parser message>
# and exits 0 or 1 accordingly.
#
# WHY THE THIRD VERDICT EXISTS (order 720-24u6, 2026-08-13)
# --------------------------------------------------------
# `tillandsias-plan compact` is byte-preserving by design, so it folds fragment
# text into the base verbatim. On 2026-08-13 a fold carried 231 bare-scalar
# timestamps (`ts: 2026-08-12T15:31:54Z`) into plan/index.yaml. Ruby's
# safe_load resolves a bare ISO-8601 scalar to Time, a disallowed class, so
# YAML.load_file raised before either vocabulary was ever read — and this script
# reported `blocked:status-vocab-diverges`, naming a divergence that did not
# exist. The vocabularies were identical; the file would not load.
#
# A failing gate that names the wrong cause is worse than a silent one: it sends
# the reader to diff two lists that already match. Load failure and divergence
# are different facts and now get different verdicts.
#
# ORDER 744-agyy (2026-08-15):
# ----------------------------
# Rewritten from ruby to yq (the forge container has no ruby, but documents yq
# present; python3 is forbidden under tlatoani_hard_no_python).

set -eu

INDEX="${1:-plan/index.yaml}"
SCHEMA="${2:-plan/schema.yaml}"

if [ ! -f "$INDEX" ] || [ ! -f "$SCHEMA" ]; then
  echo "blocked:status-vocab-diverges: could not read $INDEX or $SCHEMA"
  exit 1
fi

# Load index
if ! idx_raw=$(yq eval '.plan_index.default_status_values // [] | join(" ")' "$INDEX" 2>&1); then
  first_err=$(printf '%s\n' "$idx_raw" | head -n 1)
  echo "blocked:index-load-failed: $INDEX: $first_err"
  exit 1
fi

# Load schema
if ! sch_raw=$(yq eval '.statuses // [] | join(" ")' "$SCHEMA" 2>&1); then
  first_err=$(printf '%s\n' "$sch_raw" | head -n 1)
  echo "blocked:index-load-failed: $SCHEMA: $first_err"
  exit 1
fi

if [ "$idx_raw" != "$sch_raw" ]; then
  echo "blocked:status-vocab-diverges: $INDEX=($idx_raw) vs $SCHEMA=($sch_raw)"
  exit 1
fi

echo "ok:status-vocab-in-sync"
