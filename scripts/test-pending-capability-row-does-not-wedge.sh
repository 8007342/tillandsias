#!/usr/bin/env bash
# ORDER 1128-4ffr. Obeying the capability-row guard must not break the host that
# obeys it.
#
# THE DEADLOCK. scripts/check-capability-row.sh tells a host whose row is absent
# or expired to publish one, and states in its own header that its verdicts
# "never block work". The fold then declines to CONSUME a `capabilities:` row
# whose host+locus the compacted base does not already carry — correctly, since
# consuming it there would lose it — and reports an entry it could not use.
# `--strict-fragments` calls that corpus partial, release-preflight refuses with
# blocked:plan-ledger-incomplete, and the pre-push hook wedges EVERY push from
# that host: not the row, not unrelated packets, nothing.
#
# It catches exactly the joining or returning hosts 850-bif2 exists to onboard —
# a host that has never published cannot publish. Measured on yolanda
# 2026-09-12 as a push refusal AFTER the gate had already passed.
#
# THE DISTINCTION THIS PINS. Two different drops wear the same `dropped-entry:`
# prefix and are not the same event:
#   "...carries no host.host_id"                  -> MALFORMED, refuse.
#   "...the compacted base carries no row for
#    that host and locus"                         -> PENDING, do not wedge.
# The pending row is NOT lost: the fold leaves it in plan/index.d for the
# compaction that will absorb it, which is why letting the push through is safe.
#
# REGIME. Every arm plants a real fragment in plan/index.d, runs the REAL
# release-preflight, and removes it. The arms therefore touch the live ledger
# directory — deliberately, because the subject IS how the real fold classifies a
# real fragment, and a scratch ledger would test a different corpus. Each arm
# cleans up on its own path and the trap removes anything left behind.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0; fail=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

PEND="plan/index.d/20990101t000000z-1128-probe-pending.yaml"
BAD="plan/index.d/20990101t000001z-1128-probe-malformed.yaml"
NOID="plan/index.d/20990101t000002z-1128-probe-noid.yaml"
cleanup() { rm -f "$ROOT/$PEND" "$ROOT/$BAD" "$ROOT/$NOID"; }
trap cleanup EXIT INT TERM
cleanup

# A WELL-FORMED row for a host+locus the base cannot carry. The host name is
# deliberately one no real host uses, so this can never collide with a genuine
# row and can never be mistaken for one during a concurrent land.
write_pending() {
    cat > "$ROOT/$PEND" <<'Y'
capabilities:
  - ts: "2099-01-01T00:00:00Z"
    host: probe_1128_newhost
    locus: bare-metal
    document:
      schema_version: 2
      legacy_tier: cpu
      devices: [{device_class: cpu, vendor: intel, name: Probe, usable: true, lanes: [container]}]
      measurements: []
      host: {host_id: probe-1128-newhost, host_id_source: node-name, host_kind: linux}
      timestamp: "2099-01-01T00:00:00.000000000+00:00"
Y
}
verdict() { ( cd "$ROOT" && bash scripts/release-preflight.sh 2>&1 | tail -1 ); }

# ── 0. PRECONDITION. If the tree does not start clean, every arm below is about
#      somebody else's fragment and proves nothing.
v="$(verdict)"
case "$v" in
    ok:release-preflight) ok "PRECONDITION: the tree starts at ok:release-preflight" ;;
    *) bad "PRECONDITION: the tree is already at '$v'; the arms below would be testing that, not this packet"
       echo "pending-capability-row-does-not-wedge: $pass passed, $fail failed"; exit 1 ;;
esac

# ── 1. THE CLOSURE: a pending capability row must NOT wedge the host. ─────
write_pending
v="$(verdict)"; cleanup
case "$v" in
    ok:release-preflight) ok "a pending capability row leaves preflight green (the host can still push)" ;;
    blocked:plan-ledger-incomplete) bad "the deadlock is back: publishing the row the guard ASKS FOR wedges every push from that host" ;;
    *) bad "a pending capability row produced '$v'" ;;
esac

# ── 2. NEGATIVE CONTROL, and the row names it load-bearing: an unreadable
#      fragment must STILL make the corpus partial. This packet is about a
#      well-formed row the fold declines, never about weakening
#      --strict-fragments.
printf 'this: is: not: valid: [\n' > "$ROOT/$BAD"
v="$(verdict)"; cleanup
case "$v" in
    blocked:plan-ledger-incomplete) ok "NEGATIVE CONTROL: an unreadable fragment still refuses" ;;
    *) bad "NEGATIVE CONTROL BREACHED: a malformed fragment produced '$v' — --strict-fragments has been weakened" ;;
esac

# ── 3. MIXED. One pending row must not launder a malformed one travelling with
#      it. This is the arm that fails if the allowance is written as "ignore
#      incompleteness when any pending row is present".
write_pending
printf 'this: is: not: valid: [\n' > "$ROOT/$BAD"
v="$(verdict)"; cleanup
case "$v" in
    blocked:plan-ledger-incomplete) ok "a pending row does NOT launder a malformed fragment beside it" ;;
    *) bad "pending + malformed produced '$v' — the allowance is too wide" ;;
esac

# ── 4. THE OTHER capabilities DROP still refuses. A row with no host.host_id
#      wears the same `dropped-entry:` prefix but is genuinely unusable by
#      anyone. An allowance keyed on the prefix rather than the REASON would
#      wave this through, and arms 1-3 would not notice.
cat > "$ROOT/$NOID" <<'Y'
capabilities:
  - ts: "2099-01-01T00:00:00Z"
    host: probe_1128_newhost
    locus: bare-metal
    document:
      schema_version: 2
      devices: []
Y
v="$(verdict)"; cleanup
case "$v" in
    blocked:plan-ledger-incomplete) ok "a capabilities row with no host.host_id still refuses (keyed on the REASON, not the prefix)" ;;
    *) bad "a malformed capabilities row produced '$v' — the allowance keys on the dropped-entry prefix, not the reason" ;;
esac

# ── 5. The tree is left as it was found.
v="$(verdict)"
case "$v" in
    ok:release-preflight) ok "the tree is restored to ok:release-preflight" ;;
    *) bad "this fixture left the tree at '$v'" ;;
esac

echo "pending-capability-row-does-not-wedge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
