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
# REGIME (order 1320-44rs). Every arm plants a real fragment and runs the REAL
# release-preflight, but in a SCAFFOLD: a scratch git repo holding a copy of this
# checkout's plan/, scripts/, .github/ and VERSION (hardlinked where `cp -Rl`
# works, copied where it does not), under the ignored target/plan-scratch/. The
# corpus is the same one, byte for byte, so the fold classifies the same real
# ledger plus the probe; only the directory the probe lands in is not the live
# one. It used to be the live plan/index.d, relying on an exit trap, and the
# preflight door's deadline SIGKILLs the group mid-arm: the probes survived and
# the v56.9.20.1 release gate refused `blocked:plan-ledger-incomplete`, twice.
# A fixture that can be killed at any instruction must never have written the
# live tree at that instruction.
#
# ARM 6 asserts the live plan/ is untouched (git status and the index.d listing,
# before and after). ARM 7 TERMs this fixture mid-run, after a probe is planted:
# rc 143, the scaffold gone, the live plan/ unchanged. ARM 8 SIGKILLs it: no
# trap runs, the live plan/ is STILL unchanged (the only residue is an ignored
# scaffold under target/, which the next run sweeps by its dead owner pid).
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0; fail=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

SCRATCH_BASE="$ROOT/target/plan-scratch"
mkdir -p "$SCRATCH_BASE"
# Sweep scaffolds a SIGKILLed run left behind: the owner pid is in the name.
sweep_dead_scaffolds() {
    local d pid
    for d in "$SCRATCH_BASE"/pending-cap.*; do
        [ -d "$d" ] || continue
        pid="${d##*/pending-cap.}"; pid="${pid%%.*}"
        kill -0 "$pid" 2>/dev/null || rm -rf "$d"
    done
}
sweep_dead_scaffolds
S="$(mktemp -d "$SCRATCH_BASE/pending-cap.$$.XXXXXX")" || { echo "FAIL: no scaffold"; exit 2; }
for _p in plan scripts .github VERSION; do
    [ -e "$ROOT/$_p" ] || continue
    cp -Rl "$ROOT/$_p" "$S/" 2>/dev/null || cp -R "$ROOT/$_p" "$S/"
done
git -C "$S" init -q . || { echo "FAIL: scaffold git init"; exit 2; }
live_state() { git -C "$ROOT" status --porcelain --untracked-files=all -- plan/; ls "$ROOT/plan/index.d"; }
LIVE_BEFORE="$(live_state)"

PEND="plan/index.d/20990101t000000z-1128-probe-pending.yaml"
BAD="plan/index.d/20990101t000001z-1128-probe-malformed.yaml"
NOID="plan/index.d/20990101t000002z-1128-probe-noid.yaml"
cleanup() { rm -f "$S/$PEND" "$S/$BAD" "$S/$NOID"; }
trap 'rm -rf "$S"' EXIT
trap 'rm -rf "$S"; exit 143' TERM
trap 'rm -rf "$S"; exit 130' INT
cleanup

# A WELL-FORMED row for a host+locus the base cannot carry. The host name is
# deliberately one no real host uses, so this can never collide with a genuine
# row and can never be mistaken for one during a concurrent land.
write_pending() {
    cat > "$S/$PEND" <<'Y'
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
verdict() { ( cd "$S" && bash scripts/release-preflight.sh 2>&1 | tail -1 ); }

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
# ARMS 7-8 kill a child run HERE, with a probe planted: announce, then wait in
# the background so a TERM runs its trap at once (a foreground sleep defers it).
if [ -n "${TILLANDSIAS_1320_HOLD_FILE:-}" ]; then
    : > "$TILLANDSIAS_1320_HOLD_FILE"
    sleep 60 &
    wait $!
fi
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
printf 'this: is: not: valid: [\n' > "$S/$BAD"
v="$(verdict)"; cleanup
case "$v" in
    blocked:plan-ledger-incomplete) ok "NEGATIVE CONTROL: an unreadable fragment still refuses" ;;
    *) bad "NEGATIVE CONTROL BREACHED: a malformed fragment produced '$v' — --strict-fragments has been weakened" ;;
esac

# ── 3. MIXED. One pending row must not launder a malformed one travelling with
#      it. This is the arm that fails if the allowance is written as "ignore
#      incompleteness when any pending row is present".
write_pending
printf 'this: is: not: valid: [\n' > "$S/$BAD"
v="$(verdict)"; cleanup
case "$v" in
    blocked:plan-ledger-incomplete) ok "a pending row does NOT launder a malformed fragment beside it" ;;
    *) bad "pending + malformed produced '$v' — the allowance is too wide" ;;
esac

# ── 4. THE OTHER capabilities DROP still refuses. A row with no host.host_id
#      wears the same `dropped-entry:` prefix but is genuinely unusable by
#      anyone. An allowance keyed on the prefix rather than the REASON would
#      wave this through, and arms 1-3 would not notice.
cat > "$S/$NOID" <<'Y'
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

# ── 6. THE LIVE LEDGER WAS NEVER WRITTEN (1320-44rs). ───────────────────────
if [ "$(live_state)" = "$LIVE_BEFORE" ]; then
    ok "the live plan/ is untouched: every probe lived in the scaffold"
else
    bad "this fixture changed the live plan/: $(diff <(printf '%s\n' "$LIVE_BEFORE") <(live_state) | head -5 | tr '\n' ' ')"
fi

# ── 7-8. KILLED MID-RUN, with a probe planted. A child run holds in arm 1. ──
if [ -z "${TILLANDSIAS_1320_CHILD:-}" ]; then
    killed_run() { # killed_run <signal> -> "rc scaffolds-before scaffolds-after held|never-held"
        local hold="$S/hold.$1" child rc i=0 n_before n_after
        n_before="$(find "$SCRATCH_BASE" -maxdepth 1 -name 'pending-cap.*' | grep -c .)"
        TILLANDSIAS_1320_CHILD=1 TILLANDSIAS_1320_HOLD_FILE="$hold" \
            bash "$ROOT/scripts/test-pending-capability-row-does-not-wedge.sh" >/dev/null 2>&1 &
        child=$!
        while [ ! -e "$hold" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
        kill "-$1" "$child" 2>/dev/null
        wait "$child"; rc=$?
        n_after="$(find "$SCRATCH_BASE" -maxdepth 1 -name 'pending-cap.*' | grep -c .)"
        printf '%s %s %s %s\n' "$rc" "$n_before" "$n_after" "$([ -e "$hold" ] && echo held || echo never-held)"
    }
    set -- $(killed_run TERM)
    if [ "$1" = 143 ] && [ "$4" = held ] && [ "$3" = "$2" ] && [ "$(live_state)" = "$LIVE_BEFORE" ]; then
        ok "TERM mid-run with a probe planted: rc 143, its scaffold removed, the live plan/ unchanged"
    else
        bad "TERM mid-run: rc=$1 scaffolds before=$2 after=$3 ($4); live changed=$([ "$(live_state)" = "$LIVE_BEFORE" ] && echo no || echo yes)"
    fi
    set -- $(killed_run KILL)
    if [ "$1" = 137 ] && [ "$4" = held ] && [ "$(live_state)" = "$LIVE_BEFORE" ]; then
        ok "SIGKILL mid-run (no trap runs): rc 137 and the live plan/ STILL unchanged; the only residue is an ignored scaffold ($2 -> $3), swept below"
    else
        bad "SIGKILL mid-run: rc=$1 ($4); live changed=$([ "$(live_state)" = "$LIVE_BEFORE" ] && echo no || echo yes)"
    fi
    sweep_dead_scaffolds
fi

echo "pending-capability-row-does-not-wedge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
