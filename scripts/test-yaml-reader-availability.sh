#!/usr/bin/env bash
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
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT INT TERM
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
