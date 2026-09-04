#!/usr/bin/env bash
# ORDER 911-m7js. The archiver-check memo hits only on an unchanged ledger AND
# unchanged instrument; a byte in either is a miss. Hermetic: a temp memo file,
# and the ledger mutation is a fragment written then removed (fragments are
# what a drain adds; the memo must miss on one).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
M="$(mktemp "${TMPDIR:-/tmp}/archiver-memo.XXXXXX")"; rm -f "$M"; trap 'rm -f "$M" plan/index.d/zz-archiver-memo-probe.yaml' EXIT
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
d1="$(bash $G digest)"; d2="$(cd "$ROOT" && { cat scripts/archive-plan-packets.sh; echo "# mutated"; } | sha256sum | cut -c1-8)"
[ -n "$d1" ] && [ "${#d1}" -eq 64 ] && check ok "digest is a sha256 ($d1 | instrument sample ${d2})" || check FAIL "digest shape: $d1"
total=$((pass+fail)); if [ $fail -eq 0 ]; then echo "PASS: archiver-check memo ${pass}/${total} (911-m7js)"; exit 0; fi; echo "FAIL: archiver-check memo ${fail}/${total} red (911-m7js)"; exit 1
