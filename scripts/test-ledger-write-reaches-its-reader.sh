#!/usr/bin/env bash
# freshness: added 2026-09-06 macneo-macos (order 1080-4deb)
# @trace order:1080-4deb
#
# 1080-4deb. A WRITE THAT LANDED SOMEWHERE NO READER CONSULTS.
#
# Five writes in one day each succeeded, landed in a real place, and were then
# invisible to the reader asking the question they answered. No error anywhere:
# append-event prints ok, a selector offering a held packet looks exactly like
# one offering a free packet, and a note summary is a perfectly good place for
# prose. Absence poses as a verdict at every step.
#
# ARMS ARE ADDED ONE AT A TIME AND THE NEGATIVE CONTROL RUNS FIRST, because the
# packet says so and the reason is not procedural: a checker that flags healthy
# packets empties the ready set, a host with nothing offered stops, and a
# coordinator reading an empty queue concludes the fleet is done. That failure
# is worse than all five instances combined. Every arm below compares against
# the negative control and is VACUOUS if it does not hold.
set -uo pipefail

_fail=0
_n=0
ok()   { _n=$((_n+1)); echo "ok: $1"; }
bad()  { echo "FAIL: $1"; _fail=1; }

# RESOLVE THROUGH THE SHARED PROBE (721-nyev), never a hardcoded target/ path.
# The first version of this file did `[ -x ./target/debug/tillandsias-plan ]`
# and the gate refused it — correctly, and for THIS PACKET'S OWN REASON. The
# probe's header states it: "an executable BIT is a claim; RUNNING the binary
# is evidence." On a shared Windows/WSL checkout a WSL build leaves a Linux ELF
# beside the runnable .exe and `[ -x ]` is true for both, so the bit answers a
# question nobody asked and the caller reads it as the answer to the one they
# did. A write that lands where no reader looks, one layer down.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -r "$ROOT/scripts/plan-binary-probe.sh" ]; then
    . "$ROOT/scripts/plan-binary-probe.sh"
else
    # A missing reader must ANNOUNCE itself rather than surface as
    # file-not-found — the same rule the probe's own callers follow.
    resolve_plan_binary() { return 1; }
fi
PLAN="$(resolve_plan_binary 2>/dev/null || true)"
[ -n "$PLAN" ] || { echo "refused:no-plan-binary — the probe resolved nothing runnable"; exit 2; }

# ---------------------------------------------------------------- fixtures --
# One ledger, flipped in place, so the two directions cannot drift apart.
_fx="$(mktemp -d)"
trap 'rm -rf "$_fx"' EXIT

cat > "$_fx/ledger.yaml" <<'YAML'
plan_index:
  default_status_values: [ready, completed, in_progress]
packets:
  - packet_id: healthy-pkt
    order: 900-heal
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
  - packet_id: landed-but-ready
    order: 900-land
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
YAML

# The reachability oracle, isolated so both the fixture and the real run use
# the SAME code path. Given a list of order tokens that appear in landed commit
# subjects, report every `ready` packet whose order is among them.
#
# ONE git pass, not one per packet: 458 ready packets against a `git log` each
# is a different program with the same output on a good day and a timeout on a
# bad one.
ready_orders() {   # <index-path>
    # Field 3 is the ORDER. Field 1 is a rank number and field 2 the epic —
    # `awk '{print $1}'` here returned "2" for every row, so the checker could
    # never match a real order and reported nothing on a ledger that plainly
    # had a hit. Caught by the negative control's own vacuity arm, which exists
    # for exactly this: a checker that cannot fire looks identical to a clean
    # tree. Row shape: <rank> <epic> <order> <packet_id> <priority> <release>
    #
    # `--limit` IS MANDATORY AND ITS DEFAULT IS SMALL. Measured on the real
    # ledger 2026-09-06: bare `select-rows --status ready` returned 8 rows;
    # with `--limit 2000`, 363; `query --status ready --limit 2000`, 473. A
    # scan of 8 of 473 reported as a scan is a 1.7% SAMPLE, and it reports
    # ZERO HITS while looking exactly like a clean result — the same fault
    # this packet's own measurement note records catching three times by
    # positive control. Never call this without a limit.
    "$PLAN" --index "$1" select-rows --status ready --limit 2000 2>/dev/null | awk '{print $3}'
}

landed_orders_from() {   # <file of "sha subject" lines>
    # An order token is <digits>-<4 alnum>. Extracted from the SUBJECT only:
    # a body mentioning a packet is a reference, not a claim that it landed.
    grep -oE '[0-9]{2,5}-[a-z0-9]{4}' "$1" 2>/dev/null | sort -u
}

report_ready_but_landed() {   # <index-path> <landed-orders-file>
    local idx="$1" landed="$2" o
    for o in $(ready_orders "$idx"); do
        grep -qxF "$o" "$landed" && echo "$o"
    done
    return 0
}

# ------------------------------------------------- NEGATIVE CONTROL (FIRST) --
# A healthy packet — status matching its events, no landed fix — must produce
# NO report. This runs before every arm and its failure makes them all vacuous.
: > "$_fx/landed-none.txt"
out="$(report_ready_but_landed "$_fx/ledger.yaml" "$_fx/landed-none.txt")"
if [ -n "$out" ]; then
    bad "NEGATIVE CONTROL: a healthy ledger produced a report: $out"
    echo "  Every arm below compares against this. Stopping rather than"
    echo "  reporting arm results that cannot mean anything." >&2
    exit 1
fi
ok "negative-control: healthy packets produce no report"

# The control must also be capable of firing, or it is satisfied by a checker
# that reports nothing at all — the arm that agrees at zero and looks like a
# remedy.
printf '900-land\n' > "$_fx/landed-one.txt"
out="$(report_ready_but_landed "$_fx/ledger.yaml" "$_fx/landed-one.txt")"
if [ -z "$out" ]; then
    bad "negative-control is VACUOUS: the checker reported nothing even when a ready packet had landed"
else
    ok "negative-control is not vacuous: the checker can fire"
fi

# ----------------------------------------------- DENOMINATOR MUST BE KNOWN --
# A count with an unstated denominator is not falsifiable, and a silently
# truncated one reports zero while looking clean. The fixture ledger has
# exactly two ready packets; if the reader cannot see both, every arm below is
# measuring a sample and saying nothing about it.
_seen="$(ready_orders "$_fx/ledger.yaml" | wc -l | tr -d ' ')"
if [ "$_seen" != 2 ]; then
    bad "denominator: expected 2 ready fixture packets, the reader saw $_seen — arms would measure a sample"
    exit 1
fi
ok "denominator: the reader sees all 2 fixture ready packets"

# --------------------------------------------------------------- ARM 3 ------
# A packet whose status is `ready` while a commit whose SUBJECT names its order
# is an ancestor of trunk must be REPORTED.
#
# PRE-FIX, measured on the real ledger: 1055-e8ie read `ready` for fourteen
# hours after 459df06fe landed criteria 1 and 3, and was routed to a host on
# the strength of that. macuahuitl measured the self-DECLARING population at 1
# in 458 and stated plainly that the silent population — done in the tree,
# next_action silent — is unmeasured and unreachable by text scan. This arm is
# that measurement: it asks git, not prose.
if printf '%s\n' "$out" | grep -qxF '900-land'; then
    ok "arm3: a ready packet with a landed commit naming its order is reported"
else
    bad "arm3: ready-but-landed was NOT reported"
fi
if printf '%s\n' "$out" | grep -qxF '900-heal'; then
    bad "arm3: a healthy packet was reported (the negative control's failure, one arm later)"
else
    ok "arm3: the healthy packet is still not reported when another packet fires"
fi

echo "ok:ledger-write-reaches-its-reader:$_n arm assertion(s)"
[ "$_fail" = 0 ] || exit 1
