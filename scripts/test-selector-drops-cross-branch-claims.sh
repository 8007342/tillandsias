#!/usr/bin/env bash
# @trace order:1034-whsp
#
# Pin: the selector must not OFFER a packet a sibling branch already holds, and
# must not pretend to know when it cannot look.
#
# WHY. A claim lands on the claimant's PLATFORM branch and reaches a trunk host
# only when the coordinator relays that branch. macbookair measured the relay
# gaps at 19 minutes to 2h02m with 6h28m since the last, so a selector reading
# only its own branch hands out work another host is actively doing — 814-iyu7's
# duplication, arriving through propagation rather than through timing.
#
# NOT HYPOTHETICAL: when this landed, --batch reported order 147 held on BOTH
# windows-next and osx-next while this host had just worked it, and 317 held on
# osx-next while this selector was offering it.
#
# THE THIRD ARM IS THE ONE THAT KEEPS THE FLEET RUNNING. A checker that cannot
# fold the siblings (no plan binary, no fetch, no branches) must leave the batch
# ALONE and say so. Refusing to emit would stop every host on a network blip;
# silently dropping candidates would be worse. Neither is a claim that nothing
# is held, and that distinction is 1024-c3h3's could-not-run shape.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/xbranch-selector.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

_stub() { # $1=mode
    cat > "$W/stub.sh" <<STUB
#!/usr/bin/env bash
shift    # drop --batch
case "$1" in
  held)  for id in "\$@"; do echo "claimed-elsewhere:\$id:osx-next"; done; echo "ok:cross-branch-claims:2 sibling branch(es) checked"; exit 1 ;;
  clean) echo "ok:cross-branch-claims:2 sibling branch(es) checked"; exit 0 ;;
  blind) echo "blocked:fetch-failed"; exit 2 ;;
esac
STUB
    chmod +x "$W/stub.sh"
}

# TILLANDSIAS_HOST_TIER IS PINNED, and that is this fixture's second live-state
# dependency, not its first. The comment below records removing the CROSS-BRANCH
# checker's dependency with a clean stub. The TIER GATE (847-wgy4) sits UPSTREAM
# of that stub and was never covered: on a low-end host the selector's pool is
# exactly the [low-end]-tagged work, so when none is claimable it correctly emits
#   refused:no-tier-work: ... the mandate forbids the general queue
# and this fixture's baseline read that legitimate refusal as an empty batch.
#
# It therefore failed on ESMERALDINHA and passed everywhere else, which is why it
# reached trunk: the arms are sound, only the precondition was host-dependent.
# Verified both ways on that host — 3/6 unpinned, 6/6 pinned.
#
# The tier is not this fixture's subject. Its subject is what the selector does
# with a batch once it HAS one, so pinning the tier removes a variable that
# decides whether the test can run at all on the host that runs it.
_run() {
    TILLANDSIAS_HOST_TIER=general \
    TILLANDSIAS_XBRANCH_CHECK="$W/stub.sh" \
    TILLANDSIAS_PLAN_BIN="$W/plan-shim.sh" \
    bash scripts/select-work-batch.sh linux --budget 3 2>&1
}

# ── THE LEDGER IS A FIXTURE, NOT THE FLEET'S (order 1083-gzqj, ARM 2) ──────
#
# The stub above removed this fixture's dependency on the cross-branch CHECKER.
# It did NOT remove its dependency on the LEDGER: select-work-batch.sh reads the
# live plan, so the batch it returns is a function of what every host has
# claimed, closed or landed in the last few minutes. The baseline below then
# required that live pool to be non-empty, which is ARM 2 of 1083-gzqj: the arm
# reds when the linux ready pool empties, and siblings holding rows or a release
# bump can cause that with no code change at all.
#
# THIS IS THE SECOND HALF OF A REPAIR THAT WAS MADE ONCE BEFORE. The header
# above records the first: the fixture "passed when I wrote it and refused a
# real land hours later, having tested nothing but the fleet's claim state". The
# repair stubbed the checker and left the baseline. 1140-5bre then removed the
# cross-read COMPARISONS in arms 1 and 3 and ALSO left the baseline. Two authors,
# same file, same half-application. The baseline is the part that was never
# fixed, so it is fixed here rather than explained again.
#
# HOW: the selector reaches the ledger only through "$PLAN", and
# TILLANDSIAS_PLAN_BIN overrides which binary that is. A shim that appends
# `--index <fixture>` to every call points the whole selector at a ledger THIS
# FILE owns — three ready packets, written here, unaffected by any host. The
# batch then has a subject because the fixture guarantees one, not because the
# fleet happened to be busy.
_FIXTURE_INDEX="$W/fixture-index.yaml"
cat > "$_FIXTURE_INDEX" <<'FIXTURE_LEDGER'
plan_index:
  - packet_id: xbranch-fixture-alpha
    order: 9990-aaaa
    status: ready
    kind: bug
    priority: p2
    desired_release: v0.5
    pickup_role: any
    title: fixture row alpha for the cross-branch selector arms
    unscoreable: fixture row, never landed — exists only to give the arms a subject
  - packet_id: xbranch-fixture-beta
    order: 9991-bbbb
    status: ready
    kind: bug
    priority: p2
    desired_release: v0.5
    pickup_role: any
    title: fixture row beta for the cross-branch selector arms
    unscoreable: fixture row, never landed — exists only to give the arms a subject
  - packet_id: xbranch-fixture-gamma
    order: 9992-cccc
    status: ready
    kind: bug
    priority: p2
    desired_release: v0.5
    pickup_role: any
    title: fixture row gamma for the cross-branch selector arms
    unscoreable: fixture row, never landed — exists only to give the arms a subject
FIXTURE_LEDGER

_REAL_PLAN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null || printf '')"
if [ -z "$_REAL_PLAN" ]; then
    bad "no runnable tillandsias-plan — this fixture cannot drive the selector at all"
    echo "selector-drops-cross-branch-claims: $pass passed, $fail failed"
    exit 1
fi
cat > "$W/plan-shim.sh" <<SHIM
#!/usr/bin/env bash
exec "$_REAL_PLAN" --index "$_FIXTURE_INDEX" "\$@"
SHIM
chmod +x "$W/plan-shim.sh"

# ── 0. BASELINE: the UNFILTERED batch, taken with the clean stub ───────────
# NOT with the live checker. The baseline is the batch before any cross-branch
# drop, and the live checker DROPS — so on a day when a sibling holds one of the
# picked packets, the baseline came back short and arms 1 and 3 compared 3
# against 2 and failed. That is a control depending on live external state, and
# it went red the first time a sibling actually held something: this fixture
# passed when I wrote it and refused a real land hours later, having tested
# nothing but the fleet's claim state.
_stub clean
base="$(_run)"
n_base="$(printf '%s\n' "$base" | grep -c '^packet' || true)"
if [ "${n_base:-0}" -ge 1 ]; then
    ok "the selector emits a batch ($n_base packet(s)) — the arms below have a subject"
else
    # NAME WHAT THE SELECTOR ACTUALLY SAID. This arm went red on a low-end host
    # and the message — "emitted no packets" — described the symptom while the
    # selector had printed its exact reason on the line above. Diagnosing it
    # cost an hour that the refusal string would have closed in a second. Still
    # a FAIL and not a skip (a step that cannot run must refuse, not pass), but
    # a refusal has to carry the reason it was handed.
    bad "the selector emitted no packets; every arm below would be vacuous — it said: $(printf '%s\n' "$base" | grep -m1 -E '^(refused|blocked):' || printf '(no typed refusal; first line: %s)' "$(printf '%s\n' "$base" | head -1)")"
fi

# ── 1. NOTHING HELD: the batch is untouched ───────────────────────────────
#
# ASSERTED FROM THIS RUN'S OWN OUTPUT, never by comparing two live reads
# (1140-5bre). This arm used to require `n = n_base`, and n_base comes from a
# SEPARATE invocation of the selector. The stub removes the cross-branch
# checker's live dependency but not the LEDGER's: every claim, closure and land
# by any host changes the ready set, so with four hosts draining, the two reads
# straddle other people's writes and the counts differ for reasons that have
# nothing to do with the subject. Measured: "a clean check altered the batch
# (2 vs 3)" refused a real land while a sibling host was mid-land, and the same
# fixture went 6/6 three times in a row minutes later with the fleet quiet.
#
# That is 1083-gzqj's shape — a number nobody chose, asserted as a threshold —
# and the header above already predicted it for the cross-branch checker. The
# subject here is WHAT THE SELECTOR DOES WITH THE STUB'S ANSWER, and that is
# fully observable in one run: a clean answer must drop nothing and say nothing.
#
# "DROPS NOTHING" IS READ OFF THE ABSENCE OF A DROP NOTE, and that is sound only
# because ARM 2 PINS THAT EVERY DROP IS NAMED. The three arms compose: weaken
# arm 2 and arms 1 and 3 quietly stop meaning what they say. Anyone editing arm
# 2 is editing the evidence these two rest on.
#
# THE PATTERN IS THE DROP SENTENCE, NOT THE `cross-branch:` PREFIX. That prefix
# also carries the could-not-fold NOTICE ("says NOTHING about who holds these
# packets"), which arm 3 requires to be present — so keying on the bare prefix
# makes arms 1 and 3 contradict each other, and arm 3 fails on a correct
# selector. Measured while writing this. $_DROP is the drop sentence arm 2 pins,
# defined once so the two readings cannot drift apart.
_DROP='^cross-branch: .* is claimed on a sibling branch'

_stub clean
out="$(_run)"
n="$(printf '%s\n' "$out" | grep -c '^packet' || true)"
if [ "${n:-0}" -ge 1 ] && ! printf '%s' "$out" | grep -qE "$_DROP"; then
    ok "a clean sibling check leaves the batch alone and says nothing"
elif [ "${n:-0}" -lt 1 ]; then
    bad "a clean check emptied the batch — it said: $(printf '%s\n' "$out" | grep -m1 -E '^(refused|blocked|cross-branch):' || printf '(nothing typed)')"
else
    bad "a clean check dropped a packet: $(printf '%s\n' "$out" | grep -m1 -E "$_DROP")"
fi

# ── 1b. NEGATIVE CONTROL for arm 1, and the reason it is not vacuous. The
#       predicate above is "a batch survives AND no drop note". Run it against
#       the HELD stub, where a drop genuinely happened: it must NOT hold. Without
#       this, arm 1 would pass on a selector that had stopped checking anything
#       at all, which is precisely the failure the count comparison was there to
#       catch before it was removed for being unstable.
_stub held
ctl="$(_run)"
ctl_n="$(printf '%s\n' "$ctl" | grep -c '^packet' || true)"
if [ "${ctl_n:-0}" -ge 1 ] && ! printf '%s' "$ctl" | grep -qE "$_DROP"; then
    bad "arm 1's predicate ALSO holds when packets were really dropped — it discriminates nothing"
else
    ok "CONTROL: arm 1's predicate fails when a drop really happened — it has teeth"
fi

# ── 2. HELD: every offered packet is dropped, and NAMED ───────────────────
_stub held
out="$(_run)"
n="$(printf '%s\n' "$out" | grep -c '^packet' || true)"
if [ "${n:-0}" -eq 0 ]; then
    ok "packets held on a sibling are dropped from the batch"
else
    bad "$n held packet(s) were still offered"
fi
if printf '%s' "$out" | grep -q '^cross-branch: .* is claimed on a sibling branch'; then
    ok "the drop is NAMED, not silent"
else
    bad "packets were dropped without saying why — a host cannot tell that from an empty queue"
fi

# ── 3. COULD-NOT-FOLD: fail open, loudly ──────────────────────────────────
#
# SAME CHANGE AS ARM 1 (1140-5bre): fail-open is asserted from this run — a
# batch survives and nothing was dropped — not by matching a count taken from a
# second live read. The property that keeps the fleet running is "a blip does
# not stop the host", and an emptied batch is what stopping looks like; that is
# directly observable here.
_stub blind
out="$(_run)"
n="$(printf '%s\n' "$out" | grep -c '^packet' || true)"
if [ "${n:-0}" -ge 1 ] && ! printf '%s' "$out" | grep -qE "$_DROP"; then
    ok "a checker that cannot look leaves the batch alone"
else
    bad "an unanswerable check emptied the batch or dropped from it — a blip would stop the host (packets=$n)"
fi
if printf '%s' "$out" | grep -q 'says NOTHING about who holds'; then
    ok "and it says the check could not run, rather than implying nothing is held"
else
    bad "the could-not-fold path is silent; that reads as 'nobody holds these'"
fi

echo "selector-drops-cross-branch-claims: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
