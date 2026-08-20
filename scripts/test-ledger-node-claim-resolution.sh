#!/usr/bin/env bash
# @trace spec:meta-orchestration, plan 790-u8x6
#
# test-ledger-node-claim-resolution.sh — hermetic fixtures for the claim
# probe's ID RESOLUTION half (order 790-u8x6). The lease MECHANICS (single
# winner, reclaim, release, grammar) are pinned by
# litmus:ledger-node-claim-shape; this file pins only the question that guard
# could not answer: does the id name a real packet at all?
#
# WHY IT MATTERS. `claim` answered `claimed:<id>` for any string. A cycle that
# guessed two ids off their titles held two phantom leases while the real
# packets stayed claimable by every sibling host, and the output was
# byte-identical to success (observed live 2026-08-17).
#
# Every scenario runs the REAL script against a committed-shape FIXTURE ledger
# (TILLANDSIAS_LEDGER_CLAIM_INDEX), never the live one, so these cases cannot
# rot when the real ledger changes — the 680-zphp mutable-pin trap.
#
# Run: scripts/test-ledger-node-claim-resolution.sh   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAIM="$ROOT/scripts/claim-ledger-node.sh"
TDIR="$(mktemp -d)"
trap 'rm -rf "$TDIR"' EXIT

fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

# A minimal ledger in the real shape: two packets, one with a slashed
# packet_id (real ids do contain slashes, e.g. the 394-family children).
FIX="$TDIR/fixture/plan"
mkdir -p "$FIX"
cat >"$FIX/index.yaml" <<'YAML'
plan_index:
  packets:
    - packet_id: fixture-real-node
      order: 900-aaaa
      status: ready
      title: A real fixture packet
    - packet_id: fixture-parent/fixture-child
      order: 900-bbbb
      status: ready
      title: A real fixture packet with a slashed id
YAML

INDEX="$FIX/index.yaml"

run_claim() { # <lease-root> <args...>
  local root="$1"; shift
  TILLANDSIAS_LEDGER_LEASE_ROOT="$root" \
    TILLANDSIAS_LEDGER_CLAIM_INDEX="$INDEX" \
    bash "$CLAIM" "$@" 2>/dev/null
}

# --- 1. NEGATIVE CONTROL: a real packet_id still claims -------------------
# Without this, "refuse everything" would satisfy every case below.
r1="$TDIR/l1"
out="$(run_claim "$r1" claim fixture-real-node)"; rc=$?
if [ "$out" = "claimed:fixture-real-node" ] && [ "$rc" -eq 0 ]; then
  ok "NEGATIVE CONTROL a real packet_id still claims (rc=0)"
else
  bad "real packet_id did not claim: out=$out rc=$rc"
fi

# --- 2. a real ORDER TOKEN claims (the usability trap that caused 790) ----
r2="$TDIR/l2"
out="$(run_claim "$r2" claim 900-aaaa)"; rc=$?
if [ "$out" = "claimed:900-aaaa" ] && [ "$rc" -eq 0 ]; then
  ok "a real order token claims (rc=0)"
else
  bad "order token did not claim: out=$out rc=$rc"
fi

# --- 3. a slashed real packet_id claims -----------------------------------
r3="$TDIR/l3"
out="$(run_claim "$r3" claim fixture-parent/fixture-child)"; rc=$?
if [ "$out" = "claimed:fixture-parent/fixture-child" ] && [ "$rc" -eq 0 ]; then
  ok "a slashed real packet_id claims (rc=0)"
else
  bad "slashed id did not claim: out=$out rc=$rc"
fi

# --- 4. THE OBSERVED BUG: a near-miss id is refused, and leases NOTHING ---
r4="$TDIR/l4"
out="$(run_claim "$r4" claim fixture-reel-node)"; rc=$?
if [ "$out" = "unknown:fixture-reel-node" ] && [ "$rc" -eq 2 ]; then
  ok "MUTATION a near-miss id is refused as unknown (rc=2)"
else
  bad "near-miss id was not refused: out=$out rc=$rc"
fi
# ...and the refusal must not have created a lease directory.
if [ -z "$(ls -A "$r4" 2>/dev/null)" ]; then
  ok "a refused claim leaves no lease behind"
else
  bad "a refused claim created a lease: $(ls -A "$r4" 2>/dev/null)"
fi

# --- 5. release stays PERMISSIVE for an id that resolves to nothing -------
# A packet obsoleted or renamed after its lease was taken must still be
# releasable; a stale lease you cannot drop is worse than a phantom one.
r5="$TDIR/l5"
mkdir -p "$r5"
out="$(run_claim "$r5" release fixture-obsoleted-node)"; rc=$?
if [ "$out" = "released:fixture-obsoleted-node" ] && [ "$rc" -eq 0 ]; then
  ok "release stays permissive for an unresolvable id (rc=0)"
else
  bad "release refused an unresolvable id: out=$out rc=$rc"
fi

# --- 6. status stays PERMISSIVE too ---------------------------------------
r6="$TDIR/l6"
out="$(run_claim "$r6" status fixture-obsoleted-node)"; rc=$?
if [ "$out" = "free:fixture-obsoleted-node" ] && [ "$rc" -eq 1 ]; then
  ok "status stays permissive for an unresolvable id"
else
  bad "status refused an unresolvable id: out=$out rc=$rc"
fi

# --- 7. UNVERIFIABLE degrades loudly and still leases ---------------------
# A fresh checkout with no ledger must not lose the ability to claim; the
# 702-68zj precedent is skip-by-name, never silently and never as a violation.
r7="$TDIR/l7"
err="$TDIR/l7.err"
out="$(TILLANDSIAS_LEDGER_LEASE_ROOT="$r7" \
  TILLANDSIAS_LEDGER_CLAIM_INDEX="$TDIR/nonexistent/plan/index.yaml" \
  bash "$CLAIM" claim some-node 2>"$err")"; rc=$?
if [ "$out" = "claimed:some-node" ] && [ "$rc" -eq 0 ] && grep -q 'could not verify' "$err"; then
  ok "an unverifiable ledger degrades LOUDLY and still leases (rc=0)"
else
  bad "unverifiable case wrong: out=$out rc=$rc err=$(cat "$err")"
fi

# --- 8. the verdict line stays inside the (extended) grammar --------------
allout="$TDIR/all.txt"
: >"$allout"
r8="$TDIR/l8"
run_claim "$r8" claim fixture-real-node >>"$allout"
run_claim "$r8" claim fixture-real-node >>"$allout"
run_claim "$r8" claim fixture-nope >>"$allout"
run_claim "$r8" status fixture-real-node >>"$allout"
run_claim "$r8" release fixture-real-node >>"$allout"
tot="$(grep -c . "$allout")"
good="$(grep -cE '^(claimed|reclaimed|in-flight|released|free|unknown):[a-z0-9._/-]+$' "$allout")"
if [ "$tot" = 5 ] && [ "$good" = 5 ]; then
  ok "every verdict line matches the grammar ($good/$tot)"
else
  bad "grammar: $good/$tot well-formed"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok:ledger-node-claim-resolution-fixture:8"
  exit 0
fi
echo "fail: ledger-node-claim-resolution scenarios failed" >&2
exit 1
