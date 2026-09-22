#!/usr/bin/env bash
# @trace spec:ci-release, plan 1354-uv4e
#
# test-census-sigpipe-verdict-pipelines.sh — does the empty-tree mode actually
# discriminate?
#
# THE CENSUS REPORTS A COUNT OVER THE WHOLE CORPUS, driven by running the
# diff-scoped decider against the empty tree. That trick is the whole design and
# it is the whole risk: if the mode silently degrades — every line flagged, or
# none — the census still prints a confident number, and a number is the least
# self-announcing result there is.
#
# So four hand-written cases, one of each kind, and EXACTLY ONE must be flagged.
# The three that must NOT be flagged are the point: a mode that flags everything
# would pass a test that only checked the real violation.
#
# Hermetic throwaway repo, because the decider needs a real git base ref and a
# fixture without commits would exercise nothing.
#
# Usage: scripts/test-census-sigpipe-verdict-pipelines.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DECIDER="$REPO_ROOT/scripts/check-sigpipe-verdict-pipelines-added.sh"
CENSUS="$REPO_ROOT/scripts/census-sigpipe-verdict-pipelines.sh"
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }

[ -f "$DECIDER" ] || { echo "FAIL: decider absent"; exit 2; }
[ -x "$CENSUS" ]  || { echo "FAIL: census absent or not executable"; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/census-sigpipe.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

R="$W/repo"; mkdir -p "$R/scripts"
git init -q "$R"
git -C "$R" config user.email "fixture@example.com"
git -C "$R" config user.name "Fixture"

cat > "$R/scripts/cases.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# CASE 1 — a real verdict pipeline. MUST be flagged.
if printf '%s' "$OUT" | grep -q '^ok:thing$'; then echo yes; fi
# CASE 2 — here-string. Cannot SIGPIPE. MUST NOT be flagged.
if grep -q '^ok:thing$' <<<"$OUT"; then echo yes; fi
# CASE 3 — the same pipeline with NO verdict context. MUST NOT be flagged:
# nothing branches on its status, so SIGPIPE decides nothing.
printf '%s' "$OUT" | grep -q '^ok:thing$'
# CASE 4 — reviewed and marked. MUST NOT be flagged.
if printf '%s' "$OUT" | grep -q '^ok:x$'; then echo y; fi # sigpipe-ok: reviewed
EOF
git -C "$R" add -A
git -C "$R" commit -qm "fixture: four cases"

echo "sigpipe standing census — does the empty-tree mode discriminate?"

echo "arm 1 — exactly one of four cases is flagged"
EMPTY="$(git -C "$R" hash-object -t tree /dev/null)"
out="$(TILLANDSIAS_SIGPIPE_ROOT="$R" TILLANDSIAS_SIGPIPE_BASE="$EMPTY" \
       bash "$DECIDER" 2>&1 || true)"
n="$(printf '%s\n' "$out" | grep -c '^REFUSED:' || true)"
if [ "$n" -eq 1 ]; then
    ok "flagged exactly 1 of 4"
else
    bad "expected 1 flagged, got $n — the mode does not discriminate"
fi

echo "arm 2 — it flagged the RIGHT one"
# Counting one hit is not the same as hitting the right line. A mode that
# flagged only the here-string would also answer 1.
# THE FIRST VERSION OF THIS ARM COULD NOT FAIL, and it is recorded rather than
# quietly replaced. It grepped the report for lines starting `if printf`, then
# asked whether THAT result contained `sigpipe-ok`; when the inner grep matched
# nothing the outer grep saw an empty string, answered false, and the arm passed
# — so "no flagged line at all" and "the right flagged line" were the same
# outcome. A discriminator that reports success on an empty input is the shape
# this entire order is about, written into the test for it.
#
# Assert the CONTENT of the reported line instead. The decider echoes the
# offending source line indented under its REFUSED header, so it is there to be
# read: it must carry CASE 1's pattern and must NOT carry CASE 4's.
flagged="$(grep -A1 '^REFUSED:' <<<"$out" | grep -v '^REFUSED:' | head -1)"
if [ -z "$flagged" ]; then
    bad "no flagged line found in the report — arm 1 counted something this arm cannot see"
elif ! grep -q "ok:thing" <<<"$flagged"; then
    bad "the flagged line is not CASE 1: '$flagged'"
elif grep -q 'sigpipe-ok' <<<"$flagged"; then
    bad "the flagged line carries a sigpipe-ok marker — the exemption is not honoured: '$flagged'"
elif grep -q 'ok:x' <<<"$flagged"; then
    bad "flagged CASE 4 (the exempt one) instead of CASE 1: '$flagged'"
else
    ok "the flagged line is CASE 1, the unmarked verdict pipeline"
fi

echo "arm 3 — NEGATIVE CONTROL: a corpus with no violations answers 0"
R2="$W/clean"; mkdir -p "$R2/scripts"
git init -q "$R2"
git -C "$R2" config user.email "fixture@example.com"
git -C "$R2" config user.name "Fixture"
cat > "$R2/scripts/clean.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if grep -q '^ok:thing$' <<<"$OUT"; then echo yes; fi
EOF
git -C "$R2" add -A && git -C "$R2" commit -qm "fixture: clean"
out2="$(TILLANDSIAS_SIGPIPE_ROOT="$R2" TILLANDSIAS_SIGPIPE_BASE="$EMPTY" \
        bash "$DECIDER" 2>&1 || true)"
n2="$(printf '%s\n' "$out2" | grep -c '^REFUSED:' || true)"
if [ "$n2" -eq 0 ]; then
    ok "a clean corpus answers 0 (the mode is not flagging everything)"
else
    bad "expected 0 on a clean corpus, got $n2"
fi

echo "arm 4 — the census is a REPORT: exit 0 even with violations present"
"$CENSUS" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "exit 0 on a corpus that carries violations"
else
    bad "census exited $rc — it must never fail a build (699-dycj, 660-ryhn)"
fi

echo "arm 5 — the verdict matches the pinned grammar"
v="$("$CENSUS" 2>/dev/null | tail -1)"
case "$v" in
    ok:sigpipe-verdict-standing:[0-9]*" sites in "[0-9]*" files") ok "grammar: $v" ;;
    *) bad "verdict outside the grammar: '$v'" ;;
esac

echo "census fixture: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:census-sigpipe-verdict-fixture:$pass"
exit 0
