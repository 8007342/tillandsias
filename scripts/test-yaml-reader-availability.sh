#!/usr/bin/env bash
# @trace order:746-htj9, order:1247-sv4d
# ORDER 746-htj9. Pins scripts/check-yaml-reader-availability.sh AND the
# 720-24u6 negative control it exists to protect.
#
# The packet's exit criteria are specific about the control, because collapsing
# these two verdicts is the original defect:
#
#   "NEGATIVE CONTROL: the load-failure verdict stays distinct from the
#    divergence verdict — a file that will not load must never be reported as
#    a vocabulary mismatch."
#
# A gate that says "your status vocabulary diverges" when the truth is "this
# file has a syntax error" sends the reader to edit a vocabulary that was
# never wrong. That happened, and it is why arms 4 and 5 below exist.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
W="$(mktemp -d "${TMPDIR:-/tmp}/yaml-reader-avail.XXXXXX")"; trap 'rm -rf "$W"' EXIT INT TERM
PASS=0; FAIL=0
run() {
    name="$1"; want="$2"; shift 2
    got="$("$@" 2>&1 | head -n 1)"
    case "$got" in
        $want) PASS=$((PASS+1)); printf 'ok   %-34s %s\n' "$name" "$got" ;;
        *)     FAIL=$((FAIL+1)); printf 'FAIL %-34s want=%s got=%s\n' "$name" "$want" "$got" ;;
    esac
}
. "$ROOT/scripts/plan-binary-probe.sh"
READER="$(resolve_plan_binary)"

# 1. Availability in THIS environment, whichever it is.
run availability-here 'ok:yaml-reader:*' scripts/check-yaml-reader-availability.sh

# 2/3. The real ledger loads — the 720-24u6 regression, against the REAL file
#      and not a fixture, exactly as the exit criteria demand. 231 bare
#      ISO-8601 timestamps are what broke ruby's safe_load without
#      permitted_classes; serde_yaml has nothing to remember.
run real-ledger-loads    'ok:yaml-loads:plan/index.yaml' "$READER" validate-yaml plan/index.yaml
run real-ledger-vocab    'pending ready *'               "$READER" yaml-get plan/index.yaml plan_index.default_status_values

# 4. NEGATIVE CONTROL: unparseable is its own verdict, never a divergence.
printf 'a: [1,\n' > "$W/bad.yaml"
run malformed-is-load-failed 'blocked:yaml-load-failed:*' "$READER" validate-yaml "$W/bad.yaml"
run malformed-via-get        'blocked:yaml-load-failed:*' "$READER" yaml-get "$W/bad.yaml" statuses

# 5. And the same control one layer up, through the gate that had the defect:
#    a malformed index must report index-load-failed, NOT status-vocab-diverges.
run gate-load-vs-divergence 'blocked:index-load-failed:*' \
    scripts/check-plan-schema-divergence.sh "$W/bad.yaml" plan/schema.yaml

# 6. A missing key is EMPTY, not an error — matches the `// []` in the yq
#    exprs this replaced, and keeps "loads but empty" distinct from "broken".
got="$("$READER" yaml-get plan/index.yaml no.such.key; echo "rc=$?")"
if [ "$got" = "
rc=0" ]; then PASS=$((PASS+1)); printf 'ok   %-34s empty, rc=0\n' missing-key-is-empty
else FAIL=$((FAIL+1)); printf 'FAIL %-34s got=%q\n' missing-key-is-empty "$got"; fi

# 7. Unreadable file is distinct from unparseable file.
run absent-file 'blocked:yaml-unreadable:*' "$READER" validate-yaml "$W/nope.yaml"

# 8. The gate names a MISSING READER instead of emitting a raw
#    command-not-found. The 2026-08-15 breakage surfaced as
#    `yq: commande introuvable` wrapped in an index-load-failed line, which
#    reads like a corrupt ledger and sends the first responder to the ledger.
mkdir -p "$W/empty"
run reader-absent-is-named 'blocked:index-load-failed:*sanctioned YAML reader*' \
    env TILLANDSIAS_PLAN_BIN="$W/no-such-binary" scripts/check-plan-schema-divergence.sh

# 9/10/11. yaml-type, in yq's own spelling — the pre-push lane compares
#          against '!!map' literally, so the vocabulary must match yq's.
# The input is SYNTHESIZED, not `ls plan/index.d/*.yaml`: a fully compacted
# ledger leaves index.d empty, and the first complete compaction (941-trcf)
# turned that ls into a gate failure. The property is yaml-type's vocabulary,
# so the fixture pins its own fragment-shaped input.
printf 'packets:\n  - packet_id: fixture\n' > "$W/frag.yaml"
run type-of-fragment-is-map '!!map' "$READER" yaml-type "$W/frag.yaml"
printf -- '- a\n- b\n' > "$W/seq.yaml"
run type-of-sequence '!!seq' "$READER" yaml-type "$W/seq.yaml"
run type-of-broken-is-load-failed 'blocked:yaml-load-failed:*' "$READER" yaml-type "$W/bad.yaml"

# 12-17. ORDER 1247-sv4d (1247-amcu slice): every check-plan-schema-divergence
#        refusal says why: and remedy: on stderr, its stdout verdict unchanged,
#        and each arm then EXECUTES the remedy and requires the check to answer
#        ok:status-vocab-in-sync (1247-amcu criterion 5). The reader is made
#        absolute so an arm run from a scratch directory resolves the same one.
GATE="$ROOT/scripts/check-plan-schema-divergence.sh"
case "$READER" in (/*) ABS_READER="$READER" ;; (*) ABS_READER="$ROOT/${READER#./}" ;; esac
good_index() { printf 'plan_index:\n  default_status_values: [pending, ready, done]\n' > "$1"; }
good_schema() { printf 'statuses: [pending, ready, done]\n' > "$1"; }
# afford <name> <want-verdict-glob> <want-stderr-glob> <cmd...>: stdout line 1
# matches the verdict, stderr carries why: AND remedy: and matches the glob.
afford() {
    name="$1"; wantv="$2"; wante="$3"; shift 3
    out="$("$@" 2>"$W/err")"; err="$(cat "$W/err")"
    case "$out" in
        $wantv) ;;
        *) FAIL=$((FAIL+1)); printf 'FAIL %-34s verdict=%s\n' "$name" "$out"; return ;;
    esac
    case "$err" in
        *"  why: "*"  remedy: "*) ;;
        *) FAIL=$((FAIL+1)); printf 'FAIL %-34s no why:/remedy: on stderr: %s\n' "$name" "$err"; return ;;
    esac
    case "$err" in
        $wante) PASS=$((PASS+1)); printf 'ok   %-34s %s\n' "$name" "$out" ;;
        *) FAIL=$((FAIL+1)); printf 'FAIL %-34s stderr=%s\n' "$name" "$err" ;;
    esac
}
# cleared <name> <cmd...>: the remedy has been applied; the check is green.
cleared() {
    name="$1"; shift
    got="$("$@" 2>&1)"
    if [ "$got" = "ok:status-vocab-in-sync" ]; then PASS=$((PASS+1)); printf 'ok   %-34s remedy clears it\n' "$name"
    else FAIL=$((FAIL+1)); printf 'FAIL %-34s after remedy: %s\n' "$name" "$got"; fi
}
mkdir -p "$W/v"
good_index "$W/v/index.yaml"; good_schema "$W/v/schema.yaml"

# 12. Inputs absent (run from a directory with no plan/): remedy names both
#     paths; passing them clears it.
afford missing-inputs-affordance 'blocked:status-vocab-diverges: could not read*' \
    '*plan/index.yaml and plan/schema.yaml is not a file*name both files*' \
    sh -c 'cd "$1" && exec bash "$2"' _ "$W/empty" "$GATE"
cleared missing-inputs-remedy bash "$GATE" "$W/v/index.yaml" "$W/v/schema.yaml"

# 13. No reader: remedy is to build one or point TILLANDSIAS_PLAN_BIN at one.
afford reader-absent-affordance 'blocked:index-load-failed:*sanctioned YAML reader*' \
    '*remedy: cargo build --release -p tillandsias-plan, or set TILLANDSIAS_PLAN_BIN*' \
    env TILLANDSIAS_PLAN_BIN="$W/no-such-binary" bash "$GATE" "$W/v/index.yaml" "$W/v/schema.yaml"
cleared reader-absent-remedy env TILLANDSIAS_PLAN_BIN="$ABS_READER" bash "$GATE" "$W/v/index.yaml" "$W/v/schema.yaml"

# 14. Unparseable index: the why says it is NOT a divergence; fixing the YAML
#     (and the validate-yaml it names) clears it.
printf 'plan_index:\n  default_status_values: [pending, ready, done\n' > "$W/v/broken.yaml"
afford malformed-affordance "blocked:index-load-failed: $W/v/broken.yaml: *" \
    '*not a vocabulary divergence*validate-yaml*' \
    env TILLANDSIAS_PLAN_BIN="$ABS_READER" bash "$GATE" "$W/v/broken.yaml" "$W/v/schema.yaml"
good_index "$W/v/broken.yaml"
run malformed-remedy-validates "ok:yaml-loads:$W/v/broken.yaml" "$ABS_READER" validate-yaml "$W/v/broken.yaml"
cleared malformed-remedy env TILLANDSIAS_PLAN_BIN="$ABS_READER" bash "$GATE" "$W/v/broken.yaml" "$W/v/schema.yaml"

# 15. A real divergence names the statuses on each side only.
printf 'plan_index:\n  default_status_values: [pending, ready, archived]\n' > "$W/v/drift.yaml"
afford divergence-names-the-difference 'blocked:status-vocab-diverges: *' \
    "*only in $W/v/drift.yaml: (archived); only in $W/v/schema.yaml: (done)*remedy: make*" \
    env TILLANDSIAS_PLAN_BIN="$ABS_READER" bash "$GATE" "$W/v/drift.yaml" "$W/v/schema.yaml"
good_index "$W/v/drift.yaml"
cleared divergence-remedy env TILLANDSIAS_PLAN_BIN="$ABS_READER" bash "$GATE" "$W/v/drift.yaml" "$W/v/schema.yaml"

# 16. Same statuses, different order, is still a divergence and says so.
printf 'plan_index:\n  default_status_values: [ready, pending, done]\n' > "$W/v/order.yaml"
afford order-only-divergence 'blocked:status-vocab-diverges: *' '*same statuses, in a different order*' \
    env TILLANDSIAS_PLAN_BIN="$ABS_READER" bash "$GATE" "$W/v/order.yaml" "$W/v/schema.yaml"

# 17. Both vocabularies ABSENT used to answer ok:status-vocab-in-sync
#     (yaml-get is empty, rc=0, for a missing key). Absent is refused.
printf 'plan_index:\n  other: 1\n' > "$W/v/novocab.yaml"; printf 'other: 1\n' > "$W/v/noschema.yaml"
afford absent-vocab-refused "blocked:status-vocab-absent: $W/v/novocab.yaml: plan_index.default_status_values" \
    '*no vocabulary to compare*remedy: add plan_index.default_status_values*' \
    env TILLANDSIAS_PLAN_BIN="$ABS_READER" bash "$GATE" "$W/v/novocab.yaml" "$W/v/noschema.yaml"
good_index "$W/v/novocab.yaml"
afford absent-schema-vocab-refused "blocked:status-vocab-absent: $W/v/noschema.yaml: statuses" '*remedy: add statuses*' \
    env TILLANDSIAS_PLAN_BIN="$ABS_READER" bash "$GATE" "$W/v/novocab.yaml" "$W/v/noschema.yaml"
good_schema "$W/v/noschema.yaml"
cleared absent-vocab-remedy env TILLANDSIAS_PLAN_BIN="$ABS_READER" bash "$GATE" "$W/v/novocab.yaml" "$W/v/noschema.yaml"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
