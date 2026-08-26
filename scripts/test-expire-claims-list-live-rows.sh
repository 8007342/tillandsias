#!/usr/bin/env bash
# @trace order:905-wjfj
#
# `expire-claims --list-live` must NAME every in_progress packet it counts.
#
# THE DEFECT. The summary count and the rows had different sources. `summary:
# in_progress=N` counts every in_progress packet; the rows came from
# `live_claims`, which yields a row only for a packet carrying a `claimed for
# cycle` event. Nothing made them agree, and on 2026-08-26 they did not —
# `in_progress=1` with zero rows, observed on yoga and again on macuahuitl an
# hour later against the same ledger. The step that emits this (Start Of Cycle
# sibling overlap) exists to answer "whose claim, and does it touch my surface",
# and the tool it names could not answer it.
#
# THE BUCKET THAT WAS MISSING, which is why "just print the rows" is not the
# fix. `expire_claim_candidates` ends in `match last_ts { ... Some(_) => {} }` —
# a packet whose newest activity is INSIDE the TTL is not expired, not
# unknown-age, not held, and emits nothing. If it also carries no claim event it
# gets no live-claim row either. Fresh-and-unclaimed was a silent fifth bucket.
# The real ledger had one sitting in it: 831-ezea, in_progress with a gate step
# wired into ./build.sh --check, last activity 18h old — inside the 24h TTL, so
# no reaper would ever surface it either.
#
# WHY A SEPARATE ROW TYPE RATHER THAN WIDENING live_claims. Its fail-closed
# silence is CORRECT for its own caller (833-fpe7's resumable-dirt detector:
# never resume work whose owner you cannot name). For sibling overlap the same
# silence is inverted — an in_progress packet with no claimant is precisely the
# one you cannot send a heads-up to. Two callers, opposite defaults; the row
# type tells the reader which situation they are in.
#
# ARM 3 IS THE REGRESSION ARM: it fails against the pre-fix binary. Arms 1 and 5
# are the negative controls the packet demands — "printed nothing because there
# is nothing" must stay distinguishable from "printed nothing because it does
# not print", and the summary grammar must not move under existing parsers.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/plan-binary-probe.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

# shellcheck source=/dev/null
. "$PROBE"
PLAN="${TILLANDSIAS_PLAN_BINARY:-$(resolve_plan_binary)}" || PLAN=""
if [ -z "$PLAN" ]; then
    echo "SKIP: tillandsias-plan not built; cannot exercise the fold"
    exit 0
fi

# A base ledger with N packets. Packets live under plan_index.steps[], the shape
# the real base uses.
write_ledger() {
    mkdir -p "$WORK/plan/index.d"
    {
        printf 'plan_index:\n  version: v1\n  root: plan/\n  steps:\n'
        cat
    } > "$WORK/plan/index.yaml"
}

# A packet whose claim event follows the machine-recognizable convention.
claimed_packet() {
    printf '    - packet_id: %s\n      order: %s\n      title: "t"\n      status: in_progress\n      kind: fix\n      depends_on: []\n' "$1" "$2"
    printf '      events:\n        - type: note\n          ts: "%s"\n          host: %s\n          summary: |\n            claimed for cycle %s\n' "$3" "$4" "$3"
}

# in_progress, recent activity, and NO claim event. The silent fifth bucket.
unclaimed_packet() {
    printf '    - packet_id: %s\n      order: %s\n      title: "t"\n      status: in_progress\n      kind: fix\n      depends_on: []\n' "$1" "$2"
    printf '      events:\n        - type: progress\n          ts: "%s"\n          host: somebody\n          summary: |\n            work happened, nobody claimed the row\n' "$3"
}

done_packet() {
    printf '    - packet_id: %s\n      order: %s\n      title: "t"\n      status: completed\n      kind: fix\n      depends_on: []\n' "$1" "$2"
}

run() { "$PLAN" --index "$WORK/plan/index.yaml" expire-claims --dry-run --list-live --now-epoch "$NOW" 2>&1; }

# Fixed clock so the TTL window is deterministic. 1787745600 == 2026-08-26T12:00:00Z
# (`date -u -d @1787745600`). Hand-computing this is how the first draft of this
# fixture put NOW two days late, which pushed every "fresh" fixture timestamp
# outside the 24h TTL and turned arms 2-4 into expire-candidates. The arms
# caught it — but only because they assert on the row TYPE and not merely on
# "some row was printed".
NOW=1787745600
FRESH="2026-08-26T11:00:00Z"   # inside the 24h TTL
STALE="2026-08-20T00:00:00Z"   # outside it

count_rows() { printf '%s\n' "$1" | grep -cE "^$2	" || true; }
summary_field() { printf '%s\n' "$1" | sed -n 's/^summary: .*in_progress=\([0-9]*\).*/\1/p'; }
rows_total()    { printf '%s\n' "$1" | sed -n 's/^rows: .*total=\([0-9]*\).*/\1/p'; }

# ── arm 1: NEGATIVE CONTROL — nothing in progress ───────────────────────────
# The packet's own criterion: with zero live claims it must print the summary
# and no rows, so silence stays readable as "there is nothing" rather than "it
# does not print". The `rows:` line carrying total=0 is what makes that
# distinction observable instead of inferred.
write_ledger <<EOF
$(done_packet only-finished 1)
EOF
out="$(run)"
n_live="$(count_rows "$out" live-claim)"
n_unc="$(count_rows "$out" unclaimed-in-progress)"
tot="$(rows_total "$out")"
if [ "$n_live" = "0" ] && [ "$n_unc" = "0" ] && [ "$tot" = "0" ]; then
    ok "zero in_progress: no rows, and rows total=0 says so explicitly"
else
    bad "zero in_progress produced live=$n_live unclaimed=$n_unc total='$tot' (want 0/0/0)"
fi

# ── arm 2: a claimed packet is named ────────────────────────────────────────
write_ledger <<EOF
$(claimed_packet held-by-a-host 2 "$FRESH" hosta)
EOF
out="$(run)"
if [ "$(count_rows "$out" live-claim)" = "1" ] && printf '%s' "$out" | grep -q 'hosta'; then
    ok "a claimed in_progress packet yields one live-claim row naming its host"
else
    bad "claimed packet did not produce a named live-claim row: $out"
fi

# ── arm 3: THE REGRESSION ARM — fresh, in_progress, unclaimed ───────────────
# Fails against the pre-fix binary, which prints in_progress=1 and no rows.
write_ledger <<EOF
$(unclaimed_packet nobody-claimed-me 3 "$FRESH")
EOF
out="$(run)"
n_unc="$(count_rows "$out" unclaimed-in-progress)"
ip="$(summary_field "$out")"
tot="$(rows_total "$out")"
if [ "$n_unc" = "1" ] && [ "$tot" = "1" ] && [ "$ip" = "1" ]; then
    ok "a fresh unclaimed in_progress packet is NAMED, not merely counted (the 905-wjfj defect)"
else
    bad "fresh unclaimed packet: unclaimed rows=$n_unc rows total='$tot' summary in_progress='$ip' — the count and the rows still disagree"
fi
if printf '%s\n' "$out" | grep -q '^unclaimed-in-progress	3	nobody-claimed-me	-	-	'; then
    ok "the unclaimed row carries '-' where a host and claim time would be, in live-claim field positions"
else
    bad "unclaimed row shape wrong; one parser must read both row types: $out"
fi

# ── arm 4: the partition holds over a mixed ledger ──────────────────────────
# rows == in_progress across every bucket at once. This is the criterion the
# packet states ("the summary count equals the number of rows printed") and it
# is only meaningful when more than one bucket is populated.
write_ledger <<EOF
$(claimed_packet mixed-claimed 10 "$FRESH" hostb)
$(unclaimed_packet mixed-unclaimed 11 "$FRESH")
$(claimed_packet mixed-expired 12 "$STALE" hostc)
$(done_packet mixed-done 13)
EOF
out="$(run)"
ip="$(summary_field "$out")"
tot="$(rows_total "$out")"
if [ -n "$ip" ] && [ "$tot" = "$ip" ]; then
    ok "mixed ledger: rows total=$tot equals summary in_progress=$ip across all buckets"
else
    bad "partition leaked: rows total='$tot' vs summary in_progress='$ip'"
fi
# The two halves are asserted together on purpose. "No mismatch line" alone
# passes trivially against a binary that never emits one — measured: this arm
# was green against the pre-fix build while three others failed, which is the
# vacuous-control shape 905-wjfj is itself about. Requiring the `rows:` line to
# be PRESENT makes the absence of the mismatch line mean something.
if ! grep -q '^rows: ' <<<"$out"; then
    bad "no 'rows:' accounting line at all — 'no mismatch reported' is unfalsifiable without it"
elif printf '%s\n' "$out" | grep -q '^attention:list-live-partition-mismatch'; then
    bad "the partition self-check fired on a ledger that should balance: $out"
else
    ok "the rows: line is present AND reports no partition mismatch on a balanced ledger"
fi
# The stale one must still reach the reaper, not get swallowed by the new row.
if printf '%s\n' "$out" | grep -qE '^expire-candidate	12	mixed-expired'; then
    ok "NEGATIVE CONTROL: the stale claim is still an expire-candidate, not reclassified as unclaimed"
else
    bad "the stale claim stopped being an expire-candidate — the new row type is swallowing reaper work: $out"
fi

# ── arm 5: NEGATIVE CONTROL — the summary grammar did not move ──────────────
# Criterion 3: existing callers parsing the summary keep working.
if printf '%s\n' "$out" | grep -qE '^summary: in_progress=[0-9]+ expired=[0-9]+ held=[0-9]+ unknown_age=[0-9]+ ttl_hours=[0-9]+ mode=(dry-run|write)$'; then
    ok "the existing summary grammar is byte-compatible for callers that parse it"
else
    bad "summary grammar changed; existing parsers break: $(printf '%s\n' "$out" | grep '^summary:')"
fi

# ── arm 6: --list-live stays read-only ──────────────────────────────────────
# Listing must never write, --dry-run or not (the 833-fpe7 rule).
if [ -z "$(ls -A "$WORK/plan/index.d" 2>/dev/null)" ]; then
    ok "--list-live wrote no fragment"
else
    bad "--list-live wrote into plan/index.d/: $(ls "$WORK/plan/index.d")"
fi

printf 'expire-claims-list-live-rows: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ok:expire-claims-list-live-rows:%d\n' "$pass"
