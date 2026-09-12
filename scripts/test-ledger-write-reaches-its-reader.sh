#!/usr/bin/env bash
# freshness: auditor=forge-forge-tillandsias-opencode-20260912t022452z date=2026-09-12 verdict=updated scope=order 1080-4deb ARM 2 (blocker-in-prose) + ARM 4 (1071-adhj cross-reference presence) landed after a worktree reset clobbered the first implementation; re-applied and re-verified in the same cycle
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
  - packet_id: claimed-but-ready
    order: 900-clm
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
YAML

# ARM 1 (claim without status) needs a FRAGMENTS dir whose claim event is not a
# status field — the write that lands where the status reader never looks.
mkdir -p "$_fx/fragments.d"
cat > "$_fx/fragments.d/claim-frag.yaml" <<'YAML'
events:
  - packet_id: claimed-but-ready
    event:
      type: claim
      ts: "2026-09-10T06:00:00Z"
      host: fixture-host
      summary: claimed for cycle but appended the event only
  - packet_id: released-back-to-ready
    event:
      type: claim
      ts: "2026-09-10T06:00:00Z"
      host: fixture-host
      summary: claimed, then...
  - packet_id: released-back-to-ready
    event:
      type: release
      ts: "2026-09-10T06:05:00Z"
      host: fixture-host
      summary: released deliberately, status is ready again and events match
YAML
cat >> "$_fx/ledger.yaml" <<'YAML'
  - packet_id: released-back-to-ready
    order: 900-rel
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
  - packet_id: blocked-in-prose-pkt
    order: 900-blk
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    events:
      - type: note
        ts: "2026-09-10T00:00:00Z"
        host: fixture-host
        summary: "release cannot proceed until the integrator re-baselines; waiting on a maintainer"
  - packet_id: blocked-in-criterion-pkt
    order: 900-crt
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    exit_criteria:
      - the operator-authorised override expired and no host may land this
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

# ---------------------------------------------------------------- ARM 1 ------
# A CLAIM EVENT DOES NOT MOVE THE STATUS (1079-qb8k family, ARM 1 of 1080-4deb).
#
# `append-event --type claim` writes an event keyed by packet_id; `set-field
# status in_progress` is a SEPARATE call and is the only thing the fold reads.
# So a packet can carry a claim event and read `ready` — held by a host,
# invisible to the sweep, still offered by the selector.
#
# The reader that is blind here is the FOLD. The claim lives in plan/index.d/
# fragments as `events: []`, keyed by packet_id; the status the selector reads
# comes from the folded packet row. Report every `ready` packet whose packet_id
# appears as the subject of a `type: claim` event AND has no `type: release`
# resolving it — a released claim returning the packet to `ready` is the
# healthy case, not the blind one (measured: guest-pulls 1004-4xie and
# windows-lane both carry claim+release pairs and must NOT be reported).
claimed_packet_ids_from() {   # <fragments-dir>
    local frags="$1" f
    [ -d "${frags}" ] || return 0
    for f in "$frags"/*.yaml; do
        [ -e "$f" ] || continue
        awk '/^  - packet_id:/{pid=$3} /^      type: claim$/{print pid}' "$f"
    done | sort -u
}

released_packet_ids_from() {   # <fragments-dir>
    local frags="$1" f
    [ -d "${frags}" ] || return 0
    for f in "$frags"/*.yaml; do
        [ -e "$f" ] || continue
        awk '/^  - packet_id:/{pid=$3} /^      type: release$/{print pid}' "$f"
    done | sort -u
}

report_ready_but_claimed() {   # <index-path> <fragments-dir>
    local idx="$1" frags="$2" claimed released
    claimed="$(claimed_packet_ids_from "$frags")"
    [ -n "$claimed" ] || return 0
    # Subtract packets that carry a release event: someone returned them to
    # `ready` deliberately, so status-matches-events and nothing is blind.
    released="$(released_packet_ids_from "$frags")"
    if [ -n "$released" ]; then
        claimed="$(printf '%s\n' "$claimed" | grep -vxF -f <(printf '%s\n' "$released") || true)"
    fi
    [ -n "$claimed" ] || return 0
    # Match the claimed set against ready packets by packet_id (field 4).
    # One fold pass, then a set membership test per hit — a git/grep pass per
    # packet is the shape ARM 3 already avoided.
    "$PLAN" --index "$idx" select-rows --status ready --limit 2000 2>/dev/null | \
        awk -v c="$claimed" 'BEGIN{n=split(c,cs,"\n"); for(i=1;i<=n;i++) have[cs[i]]=1} $4 in have {print $3}'
}

# ------------------------------------------------------------ ARM 2 REPORTER --
# A BLOCKER MARKER IN PROSE is a write that lands where the order reader does
# not look: a note summary or an exit criterion saying the packet CANNOT
# PROCEED while the status row still reads `ready`. This is 1080-4deb's family
# again — the status the sweep reads and the prose the packet actually says
# pointing opposite ways, with no error anywhere.
#
# The marker list is deliberately CLOSED and mechanical, and the scan REPORTS,
# never withholds: a hit names the order and the fleet judges prominence, which
# is the packet's non-negotiable (a checker that requires consensus on severity
# empties the ready set). Only `ready` packets are scanned, so a blocker noted
# on a completed or in-progress row is out of scope by construction.
blocked_in_prose_orders() {   # <index-path>
    awk -v m='blocked|blocker|cannot proceed|cannot start|no host can|no host may|requires the operator|operator-authorised|waiting on' '
        /^  - packet_id:/    { order=""; status=""; next }
        /^    order:/        { order=$2 }
        /^    status:/       { status=$2 }
        status == "ready" && order != "" && /summary:/ && $0 ~ m { print order }
        status == "ready" && order != "" && /^ +- /  && $0 ~ m { print order }
    ' "$1" | sort -u
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

# ------------------------------------------------------- DENOMINATOR MUST BE KNOWN --
# A count with an unstated denominator is not falsifiable, and a silently
# truncated one reports zero while looking clean. The fixture ledger has
# exactly six ready packets; if the reader cannot see them all, every arm
# below is measuring a sample and saying nothing about it.
_seen="$(ready_orders "$_fx/ledger.yaml" | wc -l | tr -d ' ')"
if [ "$_seen" != 6 ]; then
    bad "denominator: expected 6 ready fixture packets, the reader saw $_seen — arms would measure a sample"
    exit 1
fi
ok "denominator: the reader sees all 6 fixture ready packets"

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

# The negative control must hold for ARM 1 too: a healthy packet (no claim
# event anywhere) must produce NO report even though the fixture HAS a claimed
# packet. Run it first, exactly as the packet's plan dictates.
_claimed="$(report_ready_but_claimed "$_fx/ledger.yaml" "$_fx/fragments.d")"
if printf '%s\n' "$_claimed" | grep -qxF '900-heal'; then
    bad "arm1: the healthy packet was reported by the claim-without-status check"
else
    ok "arm1: the healthy packet produces no report from the claim check"
fi

# Then the miss itself: 900-clm carries a claim event in the fragments and
# still reads `ready` — exactly the write that lands where the fold does not
# look. The check that cannot see this is satisfied at zero and looks like a
# remedy; it must name the order.
if printf '%s\n' "$_claimed" | grep -qxF '900-clm'; then
    ok "arm1: a ready packet with a claim event and no release is reported"
else
    bad "arm1: claim-without-status was NOT reported"
fi
if printf '%s\n' "$_claimed" | grep -qxF '900-land'; then
    bad "arm1: a ready packet WITHOUT a claim event was reported (over-reporting)"
else
    ok "arm1: the claim check does not report on claim-free packets"
fi
# And the exclusion: a claim that WAS resolved by a release returns the packet
# to `ready` deliberately — status matches events, nothing is blind. A checker
# that reports it has a false-positive on the healthy case, which is the failure
# this packet's negative control exists to catch.
if printf '%s\n' "$_claimed" | grep -qxF '900-rel'; then
    bad "arm1: a claim resolved by a typed release was reported (over-reporting)"
else
    ok "arm1: a released claim is not reported (status matches its events)"
fi

# --------------------------------------------------------------- ARM 2 ------
# A blocker marker in a `ready` packet's prose must be REPORTED, exactly as the
# negative control guarantees the healthy packet stays silent. RED pre-fix:
# with the report disabled this arm printed
#   FAIL: arm2: blocker-in-note-summary (900-blk) was NOT reported
#   FAIL: arm2: blocker-in-exit-criterion (900-crt) was NOT reported
# (exit 1) — the checker agreeing at zero while the fixture plainly carries
# both markers.
_prose="$(blocked_in_prose_orders "$_fx/ledger.yaml")"
if printf '%s\n' "$_prose" | grep -qxF '900-blk'; then
    ok "arm2: blocker-in-note-summary (900-blk) is reported"
else
    bad "arm2: blocker-in-note-summary (900-blk) was NOT reported"
fi
if printf '%s\n' "$_prose" | grep -qxF '900-crt'; then
    ok "arm2: blocker-in-exit-criterion (900-crt) is reported"
else
    bad "arm2: blocker-in-exit-criterion (900-crt) was NOT reported"
fi
if printf '%s\n' "$_prose" | grep -qxF '900-heal'; then
    bad "arm2: a healthy packet was reported by the prose scan (over-reporting)"
else
    ok "arm2: the prose scan does not report healthy packets"
fi
if printf '%s\n' "$_prose" | grep -qxF '900-land'; then
    bad "arm2: a marker-free ready packet was reported by the prose scan (over-reporting)"
else
    ok "arm2: the prose scan does not report marker-free ready packets"
fi
if printf '%s\n' "$_prose" | grep -qxF '900-clm'; then
    bad "arm2: a claim-carrying packet was reported by the prose scan (over-reporting)"
else
    ok "arm2: the prose scan is independent of the claim check (900-clm silent)"
fi

# --------------------------------------------------------------- ARM 4 ------
# The CROSS-REFERENCE arm (closure item (b)): 1071-adhj discharges the ARM-4
# property on the scorable-obligation sled WITH a check label this exact text.
# A refactor that drops it must fail HERE, not only on the sled that owned it,
# so this script keeps a presence arm on the label rather than a whole-file
# grep (that guard's header discusses correction fragments at length).
if grep -qF 'obligation in a correction fragment satisfies the FOLDED packet' "$ROOT/scripts/test-scorable-obligation-gate.sh"; then
    ok "arm4: the 1071-adhj discharge label is present in test-scorable-obligation-gate.sh"
else
    bad "arm4: the 1071-adhj discharge label is missing from test-scorable-obligation-gate.sh"
fi

echo "ok:ledger-write-reaches-its-reader:$_n arm assertion(s)"
[ "$_fail" = 0 ] || exit 1
