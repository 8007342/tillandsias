#!/usr/bin/env bash
# @trace order:896-f8ti
#
# append-event must not write into the ARCHIVE, and must still write into a
# live packet that exists only in an unfolded fragment.
#
# WHAT THIS PINS. `Ledger::resolve()` ends with `resolve_archived()` — history
# last (lib.rs:763). That ordering is correct and deliberate for READS, and its
# own comment names the caveat: "Callers that must distinguish the two ask
# `Self::is_archived`; `status`, the answer rows and the citation path all do."
# Three read paths asked. `append-event`, the one WRITE path, did not.
#
# MEASURED 2026-08-26: `append-event 624-q4jj` resolved to the real, archived,
# COMPLETED packet `macos-unstable-channel-installer-validation`
# (plan/archive/packets-2026-08.yaml:6033), wrote an event for it, and — since
# an archived packet has no block in the live base — the 699-usxc arm filed a
# NEW FRAGMENT that no live reader folds. Every step behaved as designed. The
# composite blocked a release preflight an hour later, on a different host,
# minutes before a tag.
#
# CASE 3 IS THE LOAD-BEARING ONE. The naive fix — "refuse anything not in the
# base" — passes cases 1 and 2 and BREAKS 699-usxc, the case that exists so a
# packet filed this cycle can receive events. Any change here that reddens
# case 3 has traded a silent-accept for a silent-reject.
#
# Exit codes are captured WITHOUT a pipeline on purpose (901-jtvi): `cmd | tail`
# yields tail's status, which is how a refused push read as success earlier the
# same night.
#
# NO `--ts` ANYWHERE, and that is not a style choice. The first draft passed a
# fixed 2026-01-01 timestamp; `resolve_ts` refuses anything more than 900s from
# the host clock (801-w4pn), so EVERY arm was refused by the clock guard before
# resolution ran. Case 2 went GREEN on that refusal — a fixture arm passing
# because the thing it tests never executed, which is the exact class this
# fixture belongs to. Let the tool read the clock.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=1; }

# Resolve through the SHARED PROBE, never a hardcoded target/ path (721-nyev).
# The first draft hardcoded target/release then target/debug; the gate refused it
# with `violation:plan-binary-probe-usage` and the remedy verbatim. An executable
# bit is a claim; running the binary is evidence (704-zcgi, 721-nyev, 751-vega).
# shellcheck source=scripts/plan-binary-probe.sh
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
BIN="$(resolve_plan_binary)" || BIN=""
if [ -z "$BIN" ]; then
    echo "skip:append-event-archived-refusal:no-plan-binary"
    exit 0
fi

# An order that is archived-only. Derived from the archive rather than pinned as
# a literal, so the fixture survives the archive growing: a hardcoded token that
# later gets re-minted live would silently invert this test's meaning.
ARCHIVED_ORDER="$(grep -hoE '^      order: [0-9]+-[a-z0-9]+' "$ROOT"/plan/archive/*.yaml 2>/dev/null \
    | awk '{print $2}' | head -1)"
if [ -z "$ARCHIVED_ORDER" ]; then
    echo "skip:append-event-archived-refusal:no-archived-order-found"
    exit 0
fi

# A DERIVED agent id, used by EVERY arm. Never hand-written: 874-idnt refuses
# non-canonical ids, and every hand-written id in the 2026-08-24 retrospective
# violated the contract.
#
# WHY EVERY ARM AND NOT JUST THE LIVE ONE. Ref resolution happens BEFORE
# identity resolution (772-4se9), so with a bogus id the refusal arms pass
# whether or not the archived check exists — pre-fix they are stopped one guard
# later, by identity, and the arm still goes red for the wrong reason. With a
# real id the pre-fix binary ACCEPTS the archived ref and WRITES, so arm 1 fails
# on acceptance and arm 3 fails on the stray fragment. Two arms, crisp cause.
FIXTURE_AGENT="$("$ROOT/scripts/agent-identity.sh" id claude 2>/dev/null | tail -1)"
[ -n "$FIXTURE_AGENT" ] || FIXTURE_AGENT="linux-fixture-claude-20260101t000000z"

# Remove any fragment this fixture wrote, by its own marker text. Runs on every
# exit path so a pre-fix (accepting) binary cannot leave the ledger dirty.
FIXTURE_MARK="append-event-archived-refusal fixture probe"
cleanup_fixture_fragments() {
    local f
    for f in "$ROOT"/plan/index.d/*.yaml; do
        [ -e "$f" ] || continue
        if grep -q "$FIXTURE_MARK" "$f" 2>/dev/null; then rm -f "$f"; fi
    done
}
trap cleanup_fixture_fragments EXIT

# ORDER 923-28js — OBSERVE WHAT THIS TEST COULD HAVE CAUSED, NOT WHAT THE
# DIRECTORY DID.
#
# This was `before=$(ls plan/index.d/ | wc -l)` against the LIVE ledger
# directory, compared to an `after` count. A count over a shared directory
# makes any concurrent writer this test's failure: another agent session, a
# driver cycle, a `set-field`, or a plain `git` operation moving fragments in
# or out of the working tree. MEASURED 2026-08-29: a `git stash push -u` and
# `git stash pop` during a concurrent ./build.sh --check moved the count 62 ->
# 65 inside this window, and the test reported "a refusal still wrote a
# fragment" and "append-event's archive guard regressed". Nothing had
# regressed.
#
# A count is also the weakest observation available — it cannot say WHICH file
# appeared, which is why the message had to guess at a cause and guessed wrong.
# On a fleet that runs driver cycles beside agent cycles on one checkout
# (873-zcim), a red whose own text denies its reason is worse than no check.
#
# So: snapshot the SET, and judge only files this fixture could have written.
# Its identity is FIXTURE_MARK, which every summary it passes to append-event
# carries and which cleanup_fixture_fragments above already trusts for exactly
# this purpose. FIXTURE_AGENT is NOT usable as the identity — it resolves to
# this host's real agent id, so it matches the operator's own fragments too.
before_set="$(ls "$ROOT"/plan/index.d/ 2>/dev/null | LC_ALL=C sort)"

# ── 1. an ARCHIVED ref is refused, and says so as its own case ──────────────
out="$("$BIN" append-event "$ARCHIVED_ORDER" note "append-event-archived-refusal fixture probe: must refuse" \
        --agent "$FIXTURE_AGENT" --host fixture 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
    bad "an archived ref was ACCEPTED (rc=0): $out"
elif printf '%s' "$out" | grep -qi 'archived'; then
    ok "an archived ref is refused and the refusal names it as ARCHIVED"
else
    bad "archived ref refused but the message does not distinguish it from not-found: $out"
fi

# ── 2. a ref matching nothing is refused DIFFERENTLY ───────────────────────
# The two need different remedies. Reporting an archived target as "check your
# ref" sends the author hunting a typo that does not exist.
out2="$("$BIN" append-event "999999-zzzzzz" note "append-event-archived-refusal fixture probe: must refuse" \
        --agent "$FIXTURE_AGENT" --host fixture 2>&1)"
rc2=$?
if [ "$rc2" -eq 0 ]; then
    bad "a nonexistent ref was ACCEPTED (rc=0): $out2"
elif printf '%s' "$out2" | grep -qi 'archived'; then
    bad "a nonexistent ref was reported as ARCHIVED — the two cases must not collapse: $out2"
else
    ok "a ref matching nothing is refused with a DIFFERENT message than an archived one"
fi

# ── 3. NEGATIVE CONTROL: neither refusal wrote anything ────────────────────
# Judged over the set difference, and only over files carrying this fixture's
# mark. A fragment that appeared from somewhere else is somebody else's write
# and is reported as context, never as this test's verdict (923-28js).
after_set="$(ls "$ROOT"/plan/index.d/ 2>/dev/null | LC_ALL=C sort)"
new_fragments="$(comm -13 <(printf '%s\n' "$before_set") <(printf '%s\n' "$after_set") | grep . || true)"
leaked=""
foreign=""
while IFS= read -r _nf; do
    [ -n "$_nf" ] || continue
    if grep -q "$FIXTURE_MARK" "$ROOT/plan/index.d/$_nf" 2>/dev/null; then
        leaked="${leaked}${leaked:+ }plan/index.d/$_nf"
    else
        foreign="${foreign}${foreign:+ }$_nf"
    fi
done <<EOF
$new_fragments
EOF
if [ -n "$leaked" ]; then
    bad "a refusal still wrote a fragment: $leaked"
elif [ -n "$foreign" ]; then
    ok "both refusals wrote NOTHING (ignored $(printf '%s' "$foreign" | wc -w) concurrent write(s) by another writer: $foreign)"
else
    ok "both refusals wrote NOTHING (no new fragments at all)"
fi

# ── 4. NEGATIVE CONTROL: a LIVE packet still accepts events ────────────────
# Resolved from the live ledger so this does not pin a specific order. If this
# ever reddens, the fix has started refusing legitimate writes.
# MUST BE A FRAGMENT-ONLY LIVE PACKET, and that is a correctness requirement,
# not a convenience.
#
# The first draft took the first row of `ready`, which on this ledger is a
# BASE-HOSTED packet — so append-event took the base-append path and wrote 30
# lines into plan/index.yaml. The EXIT trap only reaps fragments, so the fixture
# silently mutated the committed base ledger on every run, and would have done
# so on every host's every `--check`. Caught by `git status` showing
# `M plan/index.yaml` after wiring it into the gate, not by any arm.
#
# A fragment-only packet is also the RIGHT target: 699-usxc exists precisely so
# a packet filed this cycle can receive events, and that is the path this
# negative control is supposed to protect. The base-hosted path was never the
# case at risk.
LIVE_ORDER=""
for _f in "$ROOT"/plan/index.d/*.yaml; do
    [ -e "$_f" ] || continue
    _o="$(grep -m1 -oE '^    order: [0-9]+-[a-z0-9]+' "$_f" 2>/dev/null | awk '{print $2}')"
    _s="$(grep -m1 -oE '^    status: [a-z_]+' "$_f" 2>/dev/null | awk '{print $2}')"
    [ -n "$_o" ] && [ "$_s" = "ready" ] || continue
    grep -qE "^      order: ${_o}$" "$ROOT/plan/index.yaml" 2>/dev/null && continue
    LIVE_ORDER="$_o"; break
done
if [ -z "$LIVE_ORDER" ]; then
    ok "no live ready packet to test against — live-accept arm skipped, not passed"
else
    out4="$("$BIN" append-event "$LIVE_ORDER" note \
            "append-event-archived-refusal fixture probe: live packets must still accept events (699-usxc preserved)" \
            --agent "$FIXTURE_AGENT" --host fixture 2>&1)"
    rc4=$?
    if [ "$rc4" -eq 0 ]; then
        # The fragment this wrote is removed by the EXIT trap, which matches on
        # FIXTURE_MARK rather than on "the newest file" — a newest-file heuristic
        # would delete a CONCURRENT host's fragment if one landed in between.
        ok "a LIVE packet still accepts events (699-usxc fragment-only path intact)"
    else
        bad "a LIVE packet was REFUSED — the fix has broken legitimate writes: $out4"
    fi
fi

echo "append-event-archived-refusal: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:append-event-archived-refusal-fixture:$pass"
