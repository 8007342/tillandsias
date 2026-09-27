#!/usr/bin/env bash
# @trace order:1261-bn7v, spec:ci-release
#
# test-append-vs-origin-fold.sh — 1261-bn7v's verifiable closure.
#
# ARM 1  packet P's long-form field carries L1 on ORIGIN; a host whose fold does
#        NOT carry L1 appends L2. The push is REFUSED, the refusal matches
#        ^refused:append-drops-lines-vs-origin:P: and names L1.
#        PRE-FIX RESULT: FAILS — the push is admitted and the fold carries L2
#        only. Reproduced for real 2026-09-18 with two clones three seconds
#        apart; this is that reproduction made hermetic.
# ARM 2  NEGATIVE CONTROL: the same append from a host whose fold DOES carry L1
#        is ADMITTED. Without it, a checker that refused everything would pass
#        arm 1 and the lane would be unusable.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-append-vs-origin-fold.sh"
[ -f "$CHECK" ] || { echo "skip:append-vs-origin-fixture:checker-absent"; exit 0; }
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
PLAN="$(resolve_plan_binary 2>/dev/null)" || { echo "skip:append-vs-origin-fixture:no-plan-binary"; exit 0; }
PLAN_ABS="$ROOT/${PLAN#./}"
_probe="$("$PLAN_ABS" field-get 9999-nosuch next_action 2>&1)"
case "$_probe" in
    *unset:field-get*|*error:*) ;;
    *) echo "skip:append-vs-origin-fixture:plan-binary-lacks-field-get"; exit 0 ;;
esac

WORK="$(mktemp -d)" || exit 0
trap 'rm -rf "$WORK"' EXIT
refused_drop=0; admitted_current=0; fail=0

_build_repo() { # $1 = dir, $2 = "with-l1" | "without-l1" for the WORKTREE fold
    local r="$1" mode="$2"
    mkdir -p "$r/plan/index.d" "$r/scripts"
    cp "$CHECK" "$r/scripts/"
    cp "$ROOT/scripts/plan-binary-probe.sh" "$r/scripts/"
    cat > "$r/plan/index.yaml" <<'YAML'
packets:
  - packet_id: fixture-packet
    order: 950-fix
    status: ready
    next_action: |
      BASE LINE.
YAML
    # ORIGIN's fragment: carries L1.
    cat > "$r/plan/index.d/20260101t000001z-origin-hosta.yaml" <<'YAML'
status:
  - packet_id: fixture-packet
    field: next_action
    value: |-
      BASE LINE.

      [2026-01-01T00:00:01Z host-a] L1-PEER-WARNING-DO-NOT-DROP
    ts: "2026-01-01T00:00:01Z"
    host: host-a
YAML
    git -C "$r" init -q
    git -C "$r" config user.email f@x.invalid
    git -C "$r" config user.name f
    git -C "$r" add -A >/dev/null 2>&1
    git -C "$r" commit -qm origin-state
    # This commit IS origin: point the ref the checker reads at it.
    git -C "$r" update-ref refs/remotes/origin/linux-next HEAD

    # Now the WORKTREE diverges. The stale host's later append does not carry L1.
    cat > "$r/plan/index.d/20260101t000002z-push-hostb.yaml" <<'YAML'
status:
  - packet_id: fixture-packet
    field: next_action
    value: |-
      BASE LINE.

      [2026-01-01T00:00:02Z host-b] L2-FROM-A-STALE-BASE
    ts: "2026-01-01T00:00:02Z"
    host: host-b
YAML
    if [ "$mode" = "with-l1" ]; then
        # The SAME append written by a host that HAD fetched: L1 survives.
        cat > "$r/plan/index.d/20260101t000002z-push-hostb.yaml" <<'YAML'
status:
  - packet_id: fixture-packet
    field: next_action
    value: |-
      BASE LINE.

      [2026-01-01T00:00:01Z host-a] L1-PEER-WARNING-DO-NOT-DROP

      [2026-01-01T00:00:02Z host-b] L2-FROM-A-CURRENT-BASE
    ts: "2026-01-01T00:00:02Z"
    host: host-b
YAML
    fi
}

# --- ARM 1: the stale-base append is REFUSED and names L1 -------------------
R1="$WORK/stale"; _build_repo "$R1" "without-l1"
out1="$(cd "$R1" && TILLANDSIAS_PLAN_BIN="$PLAN_ABS" bash scripts/check-append-vs-origin-fold.sh 2>&1)"; rc1=$?
case "$out1" in
    *"refused:append-drops-lines-vs-origin:fixture-packet:next_action"*)
        case "$out1" in
            *L1-PEER-WARNING-DO-NOT-DROP*)
                [ "$rc1" -ne 0 ] && { refused_drop=1; echo "ok:   ARM 1 the stale-base append is refused and names the dropped line"; } \
                                 || { echo "FAIL: ARM 1 refusal printed but exit was 0"; fail=1; } ;;
            *) echo "FAIL: ARM 1 refused but did not name L1"; fail=1 ;;
        esac ;;
    *) echo "FAIL: ARM 1 expected a refusal, got: $(printf '%s' "$out1" | head -2)"; fail=1 ;;
esac

# --- ARM 2: NEGATIVE CONTROL — the current-base append is ADMITTED ----------
R2="$WORK/current"; _build_repo "$R2" "with-l1"
out2="$(cd "$R2" && TILLANDSIAS_PLAN_BIN="$PLAN_ABS" bash scripts/check-append-vs-origin-fold.sh 2>&1)"; rc2=$?
case "$out2" in
    ok:append-vs-origin:checked:*)
        [ "$rc2" -eq 0 ] && { admitted_current=1; echo "ok:   ARM 2 the current-base append is admitted"; } \
                         || { echo "FAIL: ARM 2 ok: printed but exit was $rc2"; fail=1; } ;;
    *) echo "FAIL: ARM 2 expected admission, got: $(printf '%s' "$out2" | head -2)"; fail=1 ;;
esac

# --- ORDER 1310-7apk: the pair list follows the PUSH, not the corpus --------
# An unrelated long-form pair ALREADY ON ORIGIN (a different field of the same
# packet, committed into origin's history), so the checker really folds it.
# The whole-corpus mode counts it; the push-scoped mode must not. The pair
# has to exist on origin, or both modes skip it as unset and read the same.
_add_unrelated() {
    cat > "$1/plan/index.d/20260101t000000z-unrelated-hostc.yaml" <<'YAML'
status:
  - packet_id: fixture-packet
    field: context
    value: |-
      UNRELATED CONTEXT LINE.
    ts: "2026-01-01T00:00:00Z"
    host: host-c
YAML
    git -C "$1" add plan/index.d/20260101t000000z-unrelated-hostc.yaml >/dev/null 2>&1
    git -C "$1" commit -qm unrelated-on-origin
    git -C "$1" update-ref refs/remotes/origin/linux-next HEAD
}
PUSHED="plan/index.d/20260101t000002z-push-hostb.yaml"

# ARM 3  SCOPED NEGATIVE CONTROL, the point of the row: with the pair list
#        narrowed to the pushed fragment, the dropped line is STILL caught.
#        Narrowing what is checked must not narrow what is caught.
R3="$WORK/scoped-stale"; _build_repo "$R3" "without-l1"; _add_unrelated "$R3"
out3="$(cd "$R3" && TILLANDSIAS_PLAN_BIN="$PLAN_ABS" bash scripts/check-append-vs-origin-fold.sh "$PUSHED" 2>&1)"; rc3=$?
case "$out3" in
    *"refused:append-drops-lines-vs-origin:fixture-packet:next_action"*L1-PEER-WARNING-DO-NOT-DROP*)
        [ "$rc3" -ne 0 ] && echo "ok:   ARM 3 scoped to the push, the dropped line is still refused" \
                         || { echo "FAIL: ARM 3 refusal printed but exit was 0"; fail=1; } ;;
    *) echo "FAIL: ARM 3 expected the scoped refusal naming L1, got: $(printf '%s' "$out3" | head -2)"; fail=1 ;;
esac

# ARM 4  COST FOLLOWS THE PUSH: scoped to one pushed fragment the check folds
#        exactly that fragment's pair (checked:1), although the corpus holds
#        two long-form pairs; unscoped it folds both (checked:2).
#        PRE-FIX: FAILS — the argument is ignored and the scoped run reads 2.
R4="$WORK/scope-count"; _build_repo "$R4" "with-l1"; _add_unrelated "$R4"
out4s="$(cd "$R4" && TILLANDSIAS_PLAN_BIN="$PLAN_ABS" bash scripts/check-append-vs-origin-fold.sh "$PUSHED" 2>&1)"
out4a="$(cd "$R4" && TILLANDSIAS_PLAN_BIN="$PLAN_ABS" bash scripts/check-append-vs-origin-fold.sh 2>&1)"
if [ "$out4s" = "ok:append-vs-origin:checked:1" ] && [ "$out4a" = "ok:append-vs-origin:checked:2" ]; then
    echo "ok:   ARM 4 scoped checks 1 pair, the whole corpus 2"
else
    echo "FAIL: ARM 4 expected scoped checked:1 and unscoped checked:2, got '$out4s' / '$out4a'"; fail=1
fi

# ARM 5  BOUNDED: past its deadline the check refuses by NAME with exit 3,
#        instead of hanging the push (it hung for tens of minutes on
#        yolanda-windows, 2026-09-26, and left orphaned hooks).
#        PRE-FIX: FAILS — no deadline exists and the run answers ok.
R5="$WORK/deadline"; _build_repo "$R5" "with-l1"
out5="$(cd "$R5" && TILLANDSIAS_APPEND_FOLD_DEADLINE=0 TILLANDSIAS_PLAN_BIN="$PLAN_ABS" bash scripts/check-append-vs-origin-fold.sh "$PUSHED" 2>&1)"; rc5=$?
case "$out5" in
    could-not-run:append-vs-origin:deadline:*)
        [ "$rc5" -eq 3 ] && echo "ok:   ARM 5 a spent deadline is a named could-not-run, exit 3" \
                         || { echo "FAIL: ARM 5 named but exit was $rc5"; fail=1; } ;;
    *) echo "FAIL: ARM 5 expected could-not-run:append-vs-origin:deadline, got: $(printf '%s' "$out5" | head -2)"; fail=1 ;;
esac

[ "$fail" -eq 0 ] || { echo "violation:append-vs-origin-fixture"; exit 1; }
echo "ok:append-vs-origin:refused-drop:${refused_drop}:admitted-current:${admitted_current}:scoped:3"
