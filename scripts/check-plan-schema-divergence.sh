#!/usr/bin/env bash
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
# Rewritten from ruby to yq — and then off BOTH; see ORDER 746-htj9 below.
# (python3 is forbidden under tlatoani_hard_no_python.)
#
# ORDER 746-* (2026-08-15, same day): THAT REWRITE MOVED THE BREAKAGE, IT DID
# NOT REMOVE IT. Measured across the three environments this gate actually runs
# in:
#
#                     yq        ruby      jq
#   forge             present   ABSENT    present
#   host (Silverblue) ABSENT    ABSENT    present
#   builder toolbox   ABSENT    present   present
#
# Ruby broke the forge. yq then broke the host AND the builder toolbox, where
# `./build.sh --check` runs on every Linux cycle — the local gate started
# refusing with `blocked:index-load-failed: … yq: commande introuvable`, so a
# green tree could not be pushed at all. Neither interpreter is universal, and
# picking one and hoping is what produced two outages in one day.
#
# So: the real fix landed. This gate now reads YAML through ONE path that
# exists in all three environments — `tillandsias-plan yaml-get`, built from
# this repo and rebuilt by cycle-preflight. The try-each-in-turn chain that
# stood here is gone; see the read_seq comment below. jq is the only external
# tool present everywhere and cannot read YAML, so it was never a candidate.

set -eu

INDEX="${1:-plan/index.yaml}"
SCHEMA="${2:-plan/schema.yaml}"
# ORDER 746-htj9 + 721-nyev. Resolve through the ONE sanctioned probe rather
# than a hardcoded ./target path. This is not ceremony: every forge exports
# CARGO_TARGET_DIR (images/default/lib-common.sh points it at the cache
# volume), so ./target does not exist in the mounted checkout at all — a
# hardcoded path would be absent in precisely the environment this packet is
# about. Shebang is bash because the probe uses `local`.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -r "$ROOT/scripts/plan-binary-probe.sh" ]; then
  . "$ROOT/scripts/plan-binary-probe.sh"
else
  # Never a raw source-failure. The whole point of this packet is that a
  # missing reader must announce itself, not surface as file-not-found.
  resolve_plan_binary() { return 1; }
fi
READER="$(resolve_plan_binary 2>/dev/null || true)"

if [ ! -f "$INDEX" ] || [ ! -f "$SCHEMA" ]; then
  echo "blocked:status-vocab-diverges: could not read $INDEX or $SCHEMA"
  exit 1
fi

# ORDER 746-htj9. ONE READER, NAMED WHEN ABSENT.
#
# What stood here was a four-tier interpreter chain: yq, then host ruby, then
# ruby inside the builder toolbox, then a refusal. Each tier was added by a
# correct fix for a real outage, and the chain is the SHAPE of the defect, not
# a solution to it — there is no interpreter present in all three environments
# this repo's gates run in, so every tier is somebody's missing tool:
#
#                     yq        ruby      jq        python3
#   forge             present   ABSENT    present   FORBIDDEN
#   host (Silverblue) ABSENT    ABSENT    present   FORBIDDEN
#   builder toolbox   ABSENT    present   present   FORBIDDEN
#
# `tillandsias-plan yaml-get` is present in all three because it is BUILT from
# this repo and scripts/cycle-preflight.sh rebuilds it at the top of every
# cycle — availability is a property we own rather than one we hope the
# environment provides. It also settles 762-8yna and 720-24u6 by construction:
# no psych version to placate, no `permitted_classes: [Time, Date]` to
# remember, so the ledger's bare ISO-8601 timestamps just load.
#
# read_seq <file> <dotted.path> -> space-joined sequence on stdout.
# Non-zero with the reader's verdict on stdout when the file will not load, so
# the caller reports it verbatim and index-load-failed stays distinct from
# status-vocab-diverges (the 720-24u6 negative control).
read_seq() {
  _rs_file="$1"; _rs_path="$2"
  if [ -z "$READER" ] || [ ! -x "$READER" ]; then
    # A NAMED refusal, never a raw command-not-found. The 2026-08-15 breakage
    # surfaced as `yq: commande introuvable` inside an index-load-failed line,
    # which reads like a corrupt ledger and sent the first responder to the
    # wrong place entirely.
    echo "no sanctioned YAML reader built (resolve_plan_binary found none; run scripts/cycle-preflight.sh)"
    return 2
  fi
  "$READER" yaml-get "$_rs_file" "$_rs_path" 2>&1
}

# Load index
if ! idx_raw=$(read_seq "$INDEX" plan_index.default_status_values); then
  first_err=$(printf '%s\n' "$idx_raw" | head -n 1)
  echo "blocked:index-load-failed: $INDEX: $first_err"
  exit 1
fi

# Load schema
if ! sch_raw=$(read_seq "$SCHEMA" statuses); then
  first_err=$(printf '%s\n' "$sch_raw" | head -n 1)
  echo "blocked:index-load-failed: $SCHEMA: $first_err"
  exit 1
fi

if [ "$idx_raw" != "$sch_raw" ]; then
  echo "blocked:status-vocab-diverges: $INDEX=($idx_raw) vs $SCHEMA=($sch_raw)"
  exit 1
fi

echo "ok:status-vocab-in-sync"
