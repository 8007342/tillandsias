#!/usr/bin/env bash
# @trace order:1553-q7f4
#
# Two defects that together let a second agent take and then destroy a lease
# another agent holds, both measured on darwin 2026-10-08 against linux-next:
#
#  1. drain-queue captured the claim with stderr MERGED (2>&1) and skipped only
#     when the result STARTED with in-flight:. When the id cannot be verified,
#     claim-ledger-node writes a "note:" to stderr BEFORE "in-flight:<id>", the
#     prefix match failed, and drain-queue went on to work a node it did not hold.
#  2. claim-ledger-node release rm -rf'd the lease without asking whose it was,
#     so that drain-queue's closing release freed the HOLDER's lease.
#
# Every arm runs the REAL scripts from this checkout. The drain-queue arms run
# scripts/drain-queue.sh end to end inside a scratch git repo, with a stub
# tillandsias-plan (query/status) and a stub ./repeat that leaves a marker if
# drain-queue decides to work the node. No live lease root and no live ledger.
#
# Run: scripts/test-claim-release-holder-safety.sh   (exit 0 = pass)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/claim-holder-safety.XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok:   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }

# --- scratch repo: the real scripts, a stub plan binary, a stub ./repeat ----
S="$T/repo"
mkdir -p "$S/scripts" "$S/plan"
cp -p "$ROOT/scripts/drain-queue.sh" "$ROOT/scripts/claim-ledger-node.sh" \
      "$ROOT/scripts/plan-binary-probe.sh" "$S/scripts/"
printf 'plan_index:\n  packets:\n    - packet_id: held-node\n      order: 900-zzzz\n      status: ready\n' > "$S/plan/index.yaml"
cat > "$T/plan-stub" <<'STUB'
#!/usr/bin/env bash
# query -> one ready packet; status <id> -> resolves held-node only.
for a in "$@"; do
  case "$a" in
    query) printf '900-zzzz\theld-node\tv0.6\tmacos\n'; exit 0 ;;
    status) shift_next=1 ;;
    *) if [ "${shift_next:-0}" = 1 ]; then [ "$a" = held-node ] && exit 0; exit 1; fi ;;
  esac
done
exit 1
STUB
chmod +x "$T/plan-stub"
cat > "$S/repeat" <<'STUB'
#!/usr/bin/env bash
echo "worked" >> "$CLAIM_SAFETY_MARK"
exit 0
STUB
chmod +x "$S/repeat"
( cd "$S" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )

CLAIM="$S/scripts/claim-ledger-node.sh"
claim_as() { # <lease-id> <args...>  (lease root and index from the environment)
  local lid="$1"; shift
  TILLANDSIAS_LEDGER_LEASE_ID="$lid" bash "$CLAIM" "$@" 2>/dev/null
}
holder_lid() { sed -n 's/^lease_id=//p' "$TILLANDSIAS_LEDGER_LEASE_ROOT/held-node.lease/holder" 2>/dev/null; }

# --- ARM 1: a non-holder's release is REFUSED and removes nothing ----------
export TILLANDSIAS_LEDGER_LEASE_ROOT="$T/l1" TILLANDSIAS_LEDGER_CLAIM_INDEX="$S/plan/index.yaml" TILLANDSIAS_PLAN_BIN="$T/plan-stub"
h="$(claim_as agent-A claim held-node)"
out="$(claim_as agent-B release held-node)"; rc=$?
st="$(claim_as agent-B status held-node)"
if [ "$h" = "claimed:held-node" ] && [ "$out" = "refused:release:not-holder:held-node:held-by=agent-A" ] \
   && [ "$rc" -ne 0 ] && [ "$st" = "in-flight:held-node" ] && [ "$(holder_lid)" = agent-A ]; then
  ok "ARM 1: a non-holder's release is refused by name; the lease stays in-flight under agent-A"
else
  bad "ARM 1: non-holder release: holder='$h' out='$out' rc=$rc status='$st' holder_lid='$(holder_lid)'"
fi

# --- ARM 2 (control): the holder releases its own lease --------------------
out="$(claim_as agent-A release held-node)"; rc=$?
st="$(claim_as agent-A status held-node)"
if [ "$out" = "released:held-node" ] && [ "$rc" -eq 0 ] && [ "$st" = "free:held-node" ]; then
  ok "ARM 2: the holder's own release frees the node"
else
  bad "ARM 2: holder release: out='$out' rc=$rc status='$st'"
fi

# --- ARM 3: without an explicit lease id, another HOST's lease is refused ---
# Same-host releases without an id stay allowed (the skill and fixtures claim
# and release in separate processes); a holder on another host is not ours.
export TILLANDSIAS_LEDGER_LEASE_ROOT="$T/l3"
h="$(bash "$CLAIM" claim held-node 2>/dev/null)"
hf="$T/l3/held-node.lease/holder"
sed 's/^host=.*/host=some-other-host/' "$hf" > "$hf.new" && mv "$hf.new" "$hf"
if ! grep -qx 'host=some-other-host' "$hf"; then
  bad "ARM 3 setup: the holder's host was not rewritten"
else
  out="$(bash "$CLAIM" release held-node 2>/dev/null)"; rc=$?
  st="$(bash "$CLAIM" status held-node 2>/dev/null)"
  case "$out" in
    refused:release:not-holder:held-node:held-by=*) r=1 ;; *) r=0 ;;
  esac
  if [ "$r" = 1 ] && [ "$rc" -ne 0 ] && [ "$st" = "in-flight:held-node" ]; then
    ok "ARM 3: with no lease id, a lease held from another host is refused"
  else
    bad "ARM 3: cross-host release: out='$out' rc=$rc status='$st'"
  fi
fi

# --- ARM 4 (control): no id, same host: release still works ----------------
export TILLANDSIAS_LEDGER_LEASE_ROOT="$T/l4"
h="$(bash "$CLAIM" claim held-node 2>/dev/null)"
out="$(bash "$CLAIM" release held-node 2>/dev/null)"; rc=$?
if [ "$h" = "claimed:held-node" ] && [ "$out" = "released:held-node" ] && [ "$rc" -eq 0 ]; then
  ok "ARM 4: a same-host release with no lease id still works (skill/fixture flow)"
else
  bad "ARM 4: same-host release: claim='$h' out='$out' rc=$rc"
fi

# drain-queue, end to end, against a node agent-A already holds.
drain_held() { # <label> <claim-index>
  local root="$T/d-$1"
  export TILLANDSIAS_LEDGER_LEASE_ROOT="$root" TILLANDSIAS_LEDGER_CLAIM_INDEX="$2"
  export CLAIM_SAFETY_MARK="$T/mark-$1"
  rm -f "$CLAIM_SAFETY_MARK"
  claim_as agent-A claim held-node >/dev/null
  ( cd "$S" && unset TILLANDSIAS_LEDGER_LEASE_ID && bash scripts/drain-queue.sh --drain --limit 1 > "$T/drain-$1.out" 2>&1 )
}

# --- ARM 5: UNVERIFIABLE id: drain-queue must SKIP the held node ------------
drain_held unverifiable "$T/nonexistent/plan/index.yaml"
st="$(claim_as agent-A status held-node)"
if [ ! -e "$CLAIM_SAFETY_MARK" ] && [ "$st" = "in-flight:held-node" ] && [ "$(holder_lid)" = agent-A ]; then
  ok "ARM 5: with an unverifiable id, drain-queue skips the held node and agent-A's lease survives"
else
  bad "ARM 5: unverifiable: worked=$([ -e "$CLAIM_SAFETY_MARK" ] && echo yes || echo no) status='$st' holder_lid='$(holder_lid)' (drain log: $(grep -E 'Claim|SKIP|COMPLETE' "$T/drain-unverifiable.out" | tr '\n' ' '))"
fi

# --- ARM 6 (control): VERIFIABLE id: drain-queue skips the held node --------
drain_held verifiable "$S/plan/index.yaml"
st="$(claim_as agent-A status held-node)"
if [ ! -e "$CLAIM_SAFETY_MARK" ] && [ "$st" = "in-flight:held-node" ]; then
  ok "ARM 6: with a verifiable id, drain-queue skips the held node"
else
  bad "ARM 6: verifiable: worked=$([ -e "$CLAIM_SAFETY_MARK" ] && echo yes || echo no) status='$st'"
fi

# --- ARM 7 (control): a FREE node is worked, then released -----------------
export TILLANDSIAS_LEDGER_LEASE_ROOT="$T/d-free" TILLANDSIAS_LEDGER_CLAIM_INDEX="$S/plan/index.yaml"
export CLAIM_SAFETY_MARK="$T/mark-free"
( cd "$S" && unset TILLANDSIAS_LEDGER_LEASE_ID && bash scripts/drain-queue.sh --drain --limit 1 > "$T/drain-free.out" 2>&1 )
st="$(claim_as agent-A status held-node)"
if [ -e "$CLAIM_SAFETY_MARK" ] && [ "$st" = "free:held-node" ]; then
  ok "ARM 7: a free node is claimed, worked once, and released by drain-queue"
else
  bad "ARM 7: free node: worked=$([ -e "$CLAIM_SAFETY_MARK" ] && echo yes || echo no) status='$st' (drain log: $(grep -E 'Claim|SKIP|COMPLETE|refused' "$T/drain-free.out" | tr '\n' ' '))"
fi

echo "claim-release-holder-safety: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "ok:claim-release-holder-safety:$pass"
[ "$fail" -eq 0 ]
