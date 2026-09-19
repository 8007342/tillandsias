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

[ "$fail" -eq 0 ] || { echo "violation:append-vs-origin-fixture"; exit 1; }
echo "ok:append-vs-origin:refused-drop:${refused_drop}:admitted-current:${admitted_current}"
