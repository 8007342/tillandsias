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

_run() { TILLANDSIAS_XBRANCH_CHECK="$W/stub.sh" bash scripts/select-work-batch.sh linux --budget 3 2>&1; }

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
    bad "the selector emitted no packets; every arm below would be vacuous"
fi

# ── 1. NOTHING HELD: the batch is untouched ───────────────────────────────
_stub clean
out="$(_run)"
n="$(printf '%s\n' "$out" | grep -c '^packet' || true)"
if [ "$n" = "$n_base" ] && ! printf '%s' "$out" | grep -q '^cross-branch:'; then
    ok "a clean sibling check leaves the batch unchanged and says nothing"
else
    bad "a clean check altered the batch ($n vs $n_base) or printed a note"
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
_stub blind
out="$(_run)"
n="$(printf '%s\n' "$out" | grep -c '^packet' || true)"
if [ "$n" = "$n_base" ]; then
    ok "a checker that cannot look leaves the batch alone"
else
    bad "an unanswerable check changed the batch ($n vs $n_base) — a blip would stop the host"
fi
if printf '%s' "$out" | grep -q 'says NOTHING about who holds'; then
    ok "and it says the check could not run, rather than implying nothing is held"
else
    bad "the could-not-fold path is silent; that reads as 'nobody holds these'"
fi

echo "selector-drops-cross-branch-claims: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
