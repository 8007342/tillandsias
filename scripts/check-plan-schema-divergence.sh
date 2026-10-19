#!/usr/bin/env bash
# @trace order:744-agyy (order 440, order 720-24u6), order:1247-sv4d
# Plan/schema status vocabulary divergence check (order 440, 744-agyy).
# Exits 0 if plan/index.yaml default_status_values and plan/schema.yaml statuses
# are identical. Emits a one-line verdict:
#   ok:status-vocab-in-sync
#   blocked:status-vocab-diverges: <details>
#   blocked:index-load-failed: <file>: <parser message>
#   blocked:status-vocab-absent: <file>: <dotted.path>   (1247-sv4d)
# and exits 0 or 1 accordingly. Each blocked verdict is followed on stderr by
# `  why:` and `  remedy:` lines (1247-amcu).
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

# ORDER 1247-sv4d (1247-amcu slice). Every refusal below says WHY on stderr and
# what CLEARS it, beside its unchanged stdout verdict. The verdict prints FIRST,
# so a caller reading line 1 of a merged stream still reads the verdict.
_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }
SELF="scripts/check-plan-schema-divergence.sh"

if [ ! -f "$INDEX" ] || [ ! -f "$SCHEMA" ]; then
  _missing=""
  [ -f "$INDEX" ] || _missing="$INDEX"
  [ -f "$SCHEMA" ] || _missing="${_missing:+$_missing and }$SCHEMA"
  echo "blocked:status-vocab-diverges: could not read $INDEX or $SCHEMA"
  _afford "$_missing is not a file from $(pwd), so there is nothing to compare; the default paths are relative to the repository root" \
    "run it from the repository root, or name both files: $SELF <index.yaml> <schema.yaml>"
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
# status-vocab-diverges (the 720-24u6 negative control). 2 = no reader at all,
# 1 = the reader ran and the file would not load; each has its own remedy.
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

# load_seq <file> <dotted.path> <varname>: a refusal with its affordance when
# the file will not load or the vocabulary is absent; the sequence otherwise.
load_seq() {
  _ls_out="" _ls_rc=0
  _ls_out=$(read_seq "$1" "$2") || _ls_rc=$?
  if [ "$_ls_rc" -ne 0 ]; then
    first_err=$(printf '%s\n' "$_ls_out" | head -n 1)
    echo "blocked:index-load-failed: $1: $first_err"
    if [ "$_ls_rc" -eq 2 ]; then
      _afford "no tillandsias-plan binary resolves (TILLANDSIAS_PLAN_BIN, CARGO_TARGET_DIR, ./target), and it is the only YAML reader this gate trusts; the ledger itself was not read, so nothing says it is corrupt" \
        "cargo build --release -p tillandsias-plan, or set TILLANDSIAS_PLAN_BIN to a built tillandsias-plan"
    else
      _afford "$1 does not parse as YAML, so its vocabulary was never read; this is a syntax error, not a vocabulary divergence" \
        "fix the YAML at the position above, then confirm with: ${READER:-tillandsias-plan} validate-yaml $1"
    fi
    exit 1
  fi
  if [ -z "$_ls_out" ]; then
    # MEASURED (1247-sv4d): yaml-get answers rc=0 and nothing for an absent
    # key, so two absent vocabularies used to compare equal and print
    # ok:status-vocab-in-sync. An empty vocabulary is not agreement.
    echo "blocked:status-vocab-absent: $1: $2"
    _afford "$1 loads but has no $2, so there is no vocabulary to compare; two absent vocabularies are not in sync" \
      "add $2 to $1, listing the same statuses as the other file, in the same order"
    exit 1
  fi
  printf -v "$3" '%s' "$_ls_out"
}

# _only_in "<a words>" "<b words>" -> the words of a that b lacks, space-joined.
_only_in() {
  _oi=""
  for _w in $1; do
    case " $2 " in (*" $_w "*) ;; (*) _oi="${_oi:+$_oi }$_w" ;; esac
  done
  printf '%s' "$_oi"
}

idx_raw="" sch_raw=""
load_seq "$INDEX" plan_index.default_status_values idx_raw
load_seq "$SCHEMA" statuses sch_raw

if [ "$idx_raw" != "$sch_raw" ]; then
  echo "blocked:status-vocab-diverges: $INDEX=($idx_raw) vs $SCHEMA=($sch_raw)"
  _a="$(_only_in "$idx_raw" "$sch_raw")" _b="$(_only_in "$sch_raw" "$idx_raw")"
  if [ -z "$_a" ] && [ -z "$_b" ]; then
    _diff="both list the same statuses, in a different order"
  else
    _diff="only in $INDEX: (${_a:-none}); only in $SCHEMA: (${_b:-none})"
  fi
  _afford "the plan tools validate a row's status against one vocabulary and the ledger defaults against the other, so a status valid in one is refused by the other; $_diff" \
    "make $INDEX plan_index.default_status_values and $SCHEMA statuses list the same statuses in the same order, in one commit"
  exit 1
fi

echo "ok:status-vocab-in-sync"
