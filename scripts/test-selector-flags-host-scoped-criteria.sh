#!/usr/bin/env bash
# @trace order:1199-aw6m, spec:ci-release
#
# test-selector-flags-host-scoped-criteria.sh — an offer must carry the
# constraint the row already states.
#
# THE DEFECT. `pickup_role` says who can work the SUBJECT; a row's exit_criteria
# can name who must produce the EVIDENCE, and only the first is a field the
# selector reads. MEASURED on lenovinha 2026-09-15: 1132-r4mt was the p1 top
# pick with pickup_role `any`, and its criterion 3 reads "demonstrated on a host
# that has actually reproduced the refusal (yoga or macuahuitl), not on a host
# that has never seen it". This host never had — 5/5 standalone and 5/5 in three
# full gates the same night — so it was claimed, read, and released three minutes
# later. The NEXT cycle offered it again, unchanged, because nothing carried the
# constraint from the row to the offer.
#
# THE ARM THAT MATTERS MOST IS ARM 2, the control: with the host identity set to
# a host the criteria DO name, the mark must disappear. Without it this fixture
# would pass against a selector that marked every row unconditionally, which
# would be noise rather than signal and would train readers to ignore the line.
#
# ARM 3 IS THE OTHER HALF OF NOT-A-FILTER: the row must still be OFFERED. A host
# that cannot close a row can still reproduce, measure, instrument or split it,
# and withholding it would convert a three-minute release into invisible work
# nobody does.
#
# It drives the REAL selector against the REAL ledger, changing only the host
# identity through the seam the script documents (TILLANDSIAS_WORKSTATION). A
# scratch ledger was the alternative and was rejected: the thing under test is
# whether the selector reads criteria that real rows actually carry, and a
# fixture that writes its own rows would assert only that its own prose parses.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3
SEL="$ROOT/scripts/select-work-batch.sh"
[ -x "$SEL" ] || { echo "skip:host-scoped-criteria:$SEL absent"; exit 3; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

OUT="$(TILLANDSIAS_WORKSTATION=lenovinha "$SEL" linux 2>/dev/null)"
if [ -z "$OUT" ]; then
    echo "skip:host-scoped-criteria:the selector produced no batch (refused or no eligible work)"
    exit 3
fi

# Find a row the selector marked, and read the hosts it named. Discovered from
# the run rather than hardcoded, so this fixture does not rot when 1132-r4mt
# closes — if nothing in today's batch is host-scoped it SKIPS by name rather
# than passing vacuously.
MARKED="$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="host-scoped"{print $2; exit}')"
NAMED="$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="host-scoped"{print $3; exit}' \
         | sed -n 's/.*name \([a-z0-9,-]*\) and not.*/\1/p')"

echo "arm 1 — a row whose exit criteria name other hosts is MARKED, and the mark names them"
if [ -z "$MARKED" ]; then
    # NOTHING MARKED IS NOT AUTOMATICALLY A SKIP. Against the pre-fix selector
    # this fixture skipped, which is the toothless shape this repo keeps finding:
    # a fixture that cannot fail cannot protect anything, and removing the
    # marking entirely would have read as "inconclusive batch" forever.
    #
    # So decide it INDEPENDENTLY, by reading the same rows the selector offered
    # and asking whether any of them names another host. Deliberately a second
    # implementation rather than a call into the selector: if both agree the
    # batch is clean, the skip is real; if this one finds a host-scoped row the
    # selector did not mark, that is the defect and it fails.
    _roster="$(tillandsias-plan capability-matrix --hosts 2>/dev/null | awk -F'\t' '{print tolower($1)}' | grep -v '^$' | tr '\n' ' ')"
    _missed=""
    if [ -n "$_roster" ]; then
        for _p in $(printf '%s\n' "$OUT" | awk -F'\t' '$1=="packet"{print $3}'); do
            _txt="$(awk -v pid="$_p" '
                $0 ~ ("packet_id: " pid "$") { inp=1; inc=0; next }
                inp && /^[[:space:]]*-[[:space:]]*packet_id:/ { inp=0; inc=0 }
                inp && /^[[:space:]]*exit_criteria:/ { inc=1; next }
                inp && inc && /^[[:space:]]*[a-z_]+:/ && !/^[[:space:]]*-/ { inc=0 }
                inp && inc { print }
            ' plan/index.yaml plan/index.d/*.yaml 2>/dev/null | tr 'A-Z' 'a-z')"
            [ -n "$_txt" ] || continue
            case " $_txt " in *" lenovinha"*) continue ;; esac
            for _h in $_roster; do
                [ "$_h" = "lenovinha" ] && continue
                case "$_txt" in *"$_h"*) _missed="${_missed:+$_missed }$_p"; break ;; esac
            done
        done
    fi
    if [ -n "$_missed" ]; then
        bad "the selector marked NOTHING, but these offered rows name other hosts in their criteria: $_missed"
        echo
        echo "host-scoped criteria: $pass passed, $fail failed"
        echo "violation:host-scoped-criteria:$fail"
        exit 1
    fi
    echo "  skip: no row in today's batch carries host-scoped criteria, confirmed independently"
    echo
    echo "host-scoped criteria: $pass passed, $fail failed (inconclusive batch)"
    exit 3
fi
if [ -n "$NAMED" ]; then
    ok "$MARKED marked, naming: $NAMED"
else
    bad "$MARKED marked but the line does not name the hosts its criteria require"
fi

echo "arm 2 — CONTROL: as one of the hosts the criteria DO name, the mark disappears"
# The whole value of the mark is that it discriminates. A selector that marked
# every row would pass arm 1 and be worthless.
FIRST_NAMED="${NAMED%%,*}"
if [ -z "$FIRST_NAMED" ]; then
    bad "cannot run the control: no host name parsed out of the mark"
else
    OUT2="$(TILLANDSIAS_WORKSTATION="$FIRST_NAMED" "$SEL" linux 2>/dev/null)"
    if printf '%s\n' "$OUT2" | awk -F'\t' '$1=="host-scoped"{print $2}' | grep -qx "$MARKED"; then
        bad "still marked as $FIRST_NAMED, a host its own criteria name — the mark does not discriminate"
    else
        ok "not marked as $FIRST_NAMED — the mark reads the criteria, it does not fire blindly"
    fi
fi

echo "arm 3 — CONTROL: marking is ADVISORY, the row is still offered"
if printf '%s\n' "$OUT" | awk -F'\t' '$1=="packet"{print $2}' | grep -qx "$MARKED"; then
    ok "$MARKED is still in the batch — a host that cannot close it can still advance it"
else
    bad "the marked row was withheld from the batch; marking must never filter (1199-aw6m)"
fi

echo "arm 4 — CONTROL: rows with no host-scoped criteria print unmarked"
_pkts="$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="packet"{print $2}' | grep -c .)"
_marks="$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="host-scoped"{print $2}' | grep -c .)"
if [ "$_marks" -lt "$_pkts" ]; then
    ok "$_marks of $_pkts rows marked — not a blanket annotation"
else
    bad "every row in the batch was marked ($_marks/$_pkts); that is noise, not a signal"
fi

echo "arm 5 — the host vocabulary is DERIVED, not a hand-maintained list"
# A second list drifts. The mark must come from the roster the selector already
# resolves, so a host added to the fleet is understood without editing this code.
if grep -q 'CAP_HOSTS' "$SEL" && ! grep -qE '^[[:space:]]*_hs_roster="(yoga|macuahuitl|lenovinha)' "$SEL"; then
    ok "the roster feeds the matcher; no literal host list in the selector"
else
    bad "a hardcoded host list appeared in the selector — it will drift"
fi

echo
echo "host-scoped criteria: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "violation:host-scoped-criteria:$fail"
    exit 1
fi
echo "ok:host-scoped-criteria:$pass"
exit 0
