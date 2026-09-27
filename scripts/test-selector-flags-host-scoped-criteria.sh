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
# HERMETIC SINCE 1420-9jdf. It used to drive the real selector against the LIVE
# ledger and exit 3 "inconclusive batch" whenever today's batch held no
# host-scoped row, which made every host's preflight read refused on a clean
# tree. It now drives the REAL selector over a SCRATCH ledger: the scratch tree
# symlinks the real scripts/ (so the selector's ROOT, derived from BASH_SOURCE,
# is the scratch tree and its awk reads the scratch plan/), and the plan binary
# is wrapped with --index. The earlier objection — "a scratch ledger asserts
# only that its own prose parses" — is met by using 1132-r4mt's criterion
# VERBATIM as the host-scoped row: the subject is whether the selector reads
# criteria real rows carry, and that sentence is one. Writing it also found a
# defect the live batch hid: "(yoga or macuahuitl)" marked the row for yoga,
# because the self-exclusion wanted a space before the host name. Arm 2 now
# runs the control as EVERY named host, not only the first.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3
SEL="$ROOT/scripts/select-work-batch.sh"
[ -x "$SEL" ] || { echo "skip:host-scoped-criteria:$SEL absent"; exit 3; }
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
_abs_plan() {
    local p
    p="$(resolve_plan_binary 2>/dev/null)" || return 1
    case "$p" in
        (/*) printf '%s' "$p" ;;
        (*) printf '%s/%s' "$PWD" "${p#./}" ;;
    esac
}
REAL_PLAN="$(_abs_plan)" || { echo "skip:host-scoped-criteria:no-plan-binary"; exit 3; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/host-scoped.XXXXXX")" || { echo "skip:host-scoped-criteria:mktemp"; exit 3; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/plan/index.d"
ln -s "$ROOT/scripts" "$WORK/scripts"
cat > "$WORK/plan/index.yaml" <<'EOF'
plan_index:
  default_status_values: [ready, completed]
packets:
  - packet_id: fixture-host-scoped-row
    order: 990-hs01
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p1
    release_target: fixture-epic
    capability_tags: [plan]
    exit_criteria:
      - 'a test asserts the refusal is gone'
      - 'demonstrated on a host that has actually reproduced the refusal (yoga or macuahuitl), not on a host that has never seen it'
  - packet_id: fixture-plain-row-one
    order: 990-pl01
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    release_target: fixture-epic
    capability_tags: [plan]
    exit_criteria:
      - 'a test asserts the new behaviour on any host'
  - packet_id: fixture-plain-row-two
    order: 990-pl02
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    release_target: fixture-epic
    capability_tags: [plan]
EOF
printf '#!/usr/bin/env bash\nexec "%s" --index "%s" "$@"\n' "$REAL_PLAN" "$WORK/plan/index.yaml" > "$WORK/plan-bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/xbranch"
chmod +x "$WORK/plan-bin" "$WORK/xbranch"
# The roster in the `capability-matrix --hosts` shape: <host>\t<tier>\t<accels>.
ROSTER="$(printf '%s\n' "lenovinha	cpu	none" "macuahuitl	gpu-cuda	none" "yoga	cpu	none" | sort)"

# Every seam pinned, so nothing live leaks in: ledger, roster, tier, caps,
# accels and the cross-branch fold (which would otherwise read git refs).
select_as() {
    (cd / && TILLANDSIAS_PLAN_BIN="$WORK/plan-bin" TILLANDSIAS_CAP_HOSTS="$ROSTER" \
        TILLANDSIAS_WORKSTATION="$1" TILLANDSIAS_HOST_TIER=general \
        TILLANDSIAS_HOST_CAPS=nix TILLANDSIAS_HOST_ACCELS= \
        TILLANDSIAS_XBRANCH_CHECK="$WORK/xbranch" \
        bash "$WORK/scripts/select-work-batch.sh" linux --release v0.5 --budget 3 --seed host-scoped-fixture 2>/dev/null)
}
marked_rows() { printf '%s\n' "$1" | awk -F'\t' '$1=="host-scoped"{print $2}'; }

OUT="$(select_as lenovinha)"
_offered="$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="packet"' | grep -c .)"
if [ "${_offered:-0}" -eq 0 ]; then
    echo "  FAIL  the selector offered nothing from the fixture ledger: $(printf '%s' "$OUT" | head -3)"
    echo "violation:host-scoped-criteria:1"
    exit 1
fi
MARKED="990-hs01"
MARK_LINE="$(printf '%s\n' "$OUT" | awk -F'\t' -v o="$MARKED" '$1=="host-scoped" && $2==o {print $3; exit}')"

echo "arm 1 — a row whose exit criteria name other hosts is MARKED, and the mark names them"
case "$MARK_LINE" in
    *"name macuahuitl,yoga and not lenovinha"*) ok "$MARKED marked for lenovinha, naming macuahuitl,yoga" ;;
    "") bad "$MARKED was not marked for lenovinha although its criteria name yoga and macuahuitl" ;;
    *) bad "$MARKED marked but the hosts are wrong: $MARK_LINE" ;;
esac

echo "arm 2 — CONTROL: as EACH host the criteria DO name, the mark disappears"
# The whole value of the mark is that it discriminates. A selector that marked
# every row would pass arm 1 and be worthless. Every named host, not the first:
# "(yoga" is the case a space-bounded match missed.
for _named in macuahuitl yoga; do
    if marked_rows "$(select_as "$_named")" | grep -qx "$MARKED"; then
        bad "still marked as $_named, a host its own criteria name — the mark does not discriminate"
    else
        ok "not marked as $_named — the mark reads the criteria, it does not fire blindly"
    fi
done

echo "arm 3 — CONTROL: marking is ADVISORY, the row is still offered"
if printf '%s\n' "$OUT" | awk -F'\t' '$1=="packet"{print $2}' | grep -qx "$MARKED"; then
    ok "$MARKED is still in the batch — a host that cannot close it can still advance it"
else
    bad "the marked row was withheld from the batch; marking must never filter (1199-aw6m)"
fi

echo "arm 4 — CONTROL: rows with no host-scoped criteria print unmarked"
_extra="$(marked_rows "$OUT" | grep -vx "$MARKED" | tr '\n' ' ')"
if [ -z "$_extra" ]; then
    ok "only $MARKED is marked; the rows naming no host are not"
else
    bad "rows whose criteria name no host were marked: $_extra — that is noise, not a signal"
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
