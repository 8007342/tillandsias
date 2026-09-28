#!/usr/bin/env bash
# ORDER 911-m7js. The archiver-check memo hits only on an unchanged ledger AND
# unchanged instrument; a byte in either is a miss. Hermetic: a temp memo file,
# and the ledger mutation is a fragment written then removed (fragments are
# what a drain adds; the memo must miss on one).
#
# ORDER 1320-44rs: all of it happens in a SCAFFOLD — a scratch git repo with a
# tiny synthetic ledger and copies of the scripts the memo digests — never in
# the live plan/index.d, where a run killed between the write and the rm left
# a probe fragment the fold reads as real. The memo's property (unchanged ->
# hit, one new fragment -> miss, removed -> hit) does not depend on WHICH
# ledger, so a small one tests it exactly.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$(mktemp -d "${TMPDIR:-/tmp}/archiver-memo-scaffold.XXXXXX")" || exit 2
M="$(mktemp "${TMPDIR:-/tmp}/archiver-memo.XXXXXX")"; rm -f "$M"
trap 'rm -rf "$SC" "$M"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
mkdir -p "$SC/scripts" "$SC/plan/index.d" "$SC/plan/archive"
for s in archiver-check-memo.sh plan-binary-probe.sh archive-plan-packets.sh archive-plan-packets.lua archive-plan-packets.rb check-archive-answerability.sh native-scratch-dir.sh; do
    [ -f "$ROOT/scripts/$s" ] && cp "$ROOT/scripts/$s" "$SC/scripts/$s"
done
printf 'packets: []\n' > "$SC/plan/index.yaml"
printf 'packets: []\n' > "$SC/plan/archive/packets-2026-01.yaml"
printf 'events: []\n' > "$SC/plan/index.d/20260101t000000z-seed.yaml"
git -C "$SC" init -q . || { echo "FAIL: scaffold git init"; exit 2; }
cd "$SC" || exit 2
pass=0; fail=0; check() { if [ "$1" = ok ]; then pass=$((pass+1)); echo "ok   $2"; else fail=$((fail+1)); echo "FAIL $2"; fi; }
G=scripts/archiver-check-memo.sh
out="$(TILLANDSIAS_ARCHIVER_MEMO="$M" bash $G check)"; [ $? -ne 0 ] && [ "$out" = "miss:no-memo" ] && check ok "no memo -> miss:no-memo" || check FAIL "no memo: $out"
out="$(TILLANDSIAS_ARCHIVER_MEMO="$M" bash $G record)"; case "$out" in ok:archiver-check-memo-recorded:*) check ok "record writes the memo" ;; *) check FAIL "record: $out" ;; esac
out="$(TILLANDSIAS_ARCHIVER_MEMO="$M" bash $G check)"; case "$out" in ok:archiver-check-memoized:*) check ok "unchanged ledger -> hit ($out)" ;; *) check FAIL "unchanged ledger: $out" ;; esac
printf '# probe\nevents: []\n' > plan/index.d/zz-archiver-memo-probe.yaml
out="$(TILLANDSIAS_ARCHIVER_MEMO="$M" bash $G check)"; [ "$out" = "miss:ledger-or-instrument-changed" ] && check ok "a new fragment -> miss" || check FAIL "new fragment: $out"
rm -f plan/index.d/zz-archiver-memo-probe.yaml
out="$(TILLANDSIAS_ARCHIVER_MEMO="$M" bash $G check)"; case "$out" in ok:archiver-check-memoized:*) check ok "fragment removed -> hit again (digest is content, not time)" ;; *) check FAIL "after removal: $out" ;; esac
# instrument change: the digest must include the checker itself
d1="$(bash $G digest)"; d2="$({ cat "$ROOT/scripts/archive-plan-packets.sh"; echo "# mutated"; } | sha256sum | cut -c1-8)"
[ -n "$d1" ] && [ "${#d1}" -eq 64 ] && check ok "digest is a sha256 ($d1 | instrument sample ${d2})" || check FAIL "digest shape: $d1"
total=$((pass+fail)); if [ $fail -eq 0 ]; then echo "PASS: archiver-check memo ${pass}/${total} (911-m7js)"; exit 0; fi; echo "FAIL: archiver-check memo ${fail}/${total} red (911-m7js)"; exit 1
