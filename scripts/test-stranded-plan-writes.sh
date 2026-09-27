#!/usr/bin/env bash
# @trace order:1232-av4p
#
# Fixture for scripts/check-stranded-plan-writes.sh. A scratch repository whose
# origin/linux-next ledger holds three packets, and a salvage ref carrying three
# status writes the audit calls relay candidates:
#   alpha  ready on trunk; the ref says implemented, NEWER   -> would-change
#   beta   completed on trunk 09-20; the ref's claim is 09-01 -> superseded
#   gamma  ready on trunk; the ref also says ready           -> not reported
# The fold of trunk + fragment decides, not a string comparison, so arm 2 is
# the one a naive "ref value differs from trunk" check would get wrong.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/plan-binary-probe.sh"
PB="$(cd "$ROOT" && resolve_plan_binary 2>/dev/null)" || PB=""
case "$PB" in ./*) PB="$ROOT/${PB#./}" ;; esac
[ -n "$PB" ] || { echo "could-not-run:stranded-plan-writes-fixture:no-plan-binary"; exit 3; }
work="$(mktemp -d "${TMPDIR:-/tmp}/stranded-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

R="$work/repo"; mkdir -p "$R/scripts" "$R/plan/index.d"
cp "$ROOT/scripts/check-stranded-plan-writes.sh" "$ROOT/scripts/plan-binary-probe.sh" "$R/scripts/"
cat > "$R/plan/index.yaml" <<'Y'
plan_index:
  packets:
    - packet_id: alpha
      order: 101-aaaa
      status: ready
      title: alpha
    - packet_id: beta
      order: 102-bbbb
      status: ready
      title: beta
    - packet_id: gamma
      order: 103-cccc
      status: ready
      title: gamma
Y
cat > "$R/plan/index.d/20260920t000000z-close-beta.yaml" <<'Y'
status:
  - packet_id: beta
    field: status
    value: completed
    ts: "2026-09-20T00:00:00Z"
    host: trunkhost
Y
g() { git -C "$R" -c user.name=f -c user.email=f@f -c commit.gpgsign=false "$@"; }
g init -q -b linux-next; g add -A; g commit -q -m trunk
g update-ref refs/remotes/origin/linux-next HEAD
g switch -q -c ref
cat > "$R/plan/index.d/20260925t000000z-forge.yaml" <<'Y'
status:
  - packet_id: alpha
    field: status
    value: implemented
    ts: "2026-09-25T00:00:00Z"
    host: forge
  - packet_id: gamma
    field: status
    value: ready
    ts: "2026-09-25T00:00:00Z"
    host: forge
Y
cat > "$R/plan/index.d/20260901t000000z-forge-claim.yaml" <<'Y'
status:
  - packet_id: beta
    field: status
    value: in_progress
    ts: "2026-09-01T00:00:00Z"
    host: forge
Y
g add -A; g commit -q -m ref
g update-ref refs/remotes/origin/salvage/forge/x HEAD
g switch -q linux-next
cat > "$work/audit" <<'A'
salvage-audit: branch=origin/linux-next patterns=refs/heads/salvage/*
  salvage/forge/x
    plan/index.d/20260925t000000z-forge.yaml  ref-may-be-AHEAD (predates no branch edit)
    plan/index.d/20260901t000000z-forge-claim.yaml  ref-may-be-AHEAD (predates no branch edit)
ok:salvage-audit:1r:1w:2f:branch=origin/linux-next
A
out="$(TILLANDSIAS_PLAN_BIN="$PB" bash "$R/scripts/check-stranded-plan-writes.sh" --from "$work/audit" 2>&1)"

case "$out" in
    *"stranded:would-change:101-aaaa:alpha:ref=implemented:trunk=ready:folded=implemented:"*) ok "a newer ref write trunk lacks is would-change, named by order and id" ;;
    *) bad "alpha not reported as would-change: $out" ;;
esac
case "$out" in
    *"stranded:superseded:102-bbbb:beta:ref=in_progress:trunk=completed:"*) ok "an older ref claim trunk has moved past is superseded, not would-change" ;;
    *) bad "beta not reported as superseded: $out" ;;
esac
case "$out" in
    *":gamma:"*) bad "gamma (same value on both) must not be reported: $out" ;;
    *) ok "a write equal to trunk is not reported" ;;
esac
case "$(tail -n 1 <<<"$out")" in
    "ok:stranded-plan-writes:1 would-change, 1 superseded, on 1 ref(s)") ok "the verdict counts both kinds" ;;
    *) bad "verdict: $(tail -n 1 <<<"$out")" ;;
esac
# NEGATIVE CONTROL: an audit that marks the fragments as a STALE snapshot
# (branch ahead) yields no candidates, so nothing is reported.
sed 's/ref-may-be-AHEAD (predates no branch edit)/linux-next-is-AHEAD (stale snapshot)/' "$work/audit" > "$work/audit-stale"
out2="$(TILLANDSIAS_PLAN_BIN="$PB" bash "$R/scripts/check-stranded-plan-writes.sh" --from "$work/audit-stale" 2>&1)"
[ "$(tail -n 1 <<<"$out2")" = "ok:stranded-plan-writes:0 would-change, 0 superseded, on 0 ref(s)" ] \
    && ok "a stale snapshot is not a candidate" || bad "stale snapshot reported: $out2"

if [ "$fail" = 0 ]; then echo "ok:stranded-plan-writes-fixture:$pass arms"; exit 0; fi
echo "FAIL:stranded-plan-writes-fixture:$fail failed"; exit 1
