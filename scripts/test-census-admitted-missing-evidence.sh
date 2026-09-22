#!/usr/bin/env bash
# @trace spec:ci-release, plan 1349-tdpg
#
# test-census-admitted-missing-evidence.sh — THE POSITIVE CONTROL, written and
# passing BEFORE the census was pointed at this repo.
#
# WHY THIS ORDER, and the row specifies it. The census reports a COUNT. A count
# is the least self-announcing result there is: "3 hits" and "my pattern matches
# nothing, and 3 unrelated lines happen to contain the word" are the same
# output. This suite exists so the number can be shown to respond — it plants
# exactly one dated admission beside a plain comment that must NOT be counted,
# and requires the census to find one and only one.
#
# Every arm runs against a hermetic throwaway git repo, because the ages the
# census reports come from `git blame` and a fixture without real commits would
# exercise the pattern matching and nothing else. The dated admission is
# committed with a known author date, so the reported age is checkable rather
# than merely present.
#
# Usage: scripts/test-census-admitted-missing-evidence.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CENSUS="$REPO_ROOT/scripts/census-admitted-missing-evidence.sh"
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }

[ -x "$CENSUS" ] || { echo "FAIL: $CENSUS missing or not executable"; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/census-ame.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

# ── The hermetic tree. ──────────────────────────────────────────────────────
R="$W/repo"
mkdir -p "$R/src"
git init -q "$R" 2>/dev/null
git -C "$R" config user.email "fixture@example.com"
git -C "$R" config user.name "Fixture"

# THE ADMISSION. One line, in a comment, deferring its own evidence. This is the
# shape the row is about: an honest note whose author was right to write it and
# which nothing has ever aged.
cat > "$R/src/capped.rs" <<'EOF'
/// The page size for the menu.
///
/// Nobody has yet measured a real repo count against a real screen, so it
/// stays at 10 until someone does.
pub const MAX_ITEMS: usize = 10;
EOF

# THE DECOY. A plain comment, in the same tree, that must NOT be counted. It
# deliberately contains the WORDS the patterns look for, arranged so they do not
# admit anything: this is the difference between matching a phrase and matching
# a claim, and it is where a lazy pattern fails.
cat > "$R/src/plain.rs" <<'EOF'
/// We measured this against three screens before choosing it, and someone
/// verified the result independently. Nothing here is assumed.
pub const ROWS: usize = 24;
EOF

git -C "$R" add -A
GIT_AUTHOR_DATE="2026-08-01T12:00:00Z" GIT_COMMITTER_DATE="2026-08-01T12:00:00Z" \
    git -C "$R" commit -qm "fixture: one admission, one decoy"

echo "admitted-missing-evidence census — positive control"

echo "arm 1 — POSITIVE CONTROL: exactly the admission is counted"
out="$("$CENSUS" --root "$R" 2>/dev/null)"
n="$(printf '%s\n' "$out" | sed -n 's/^ok:admitted-missing-evidence:\([0-9]\{1,\}\) .*/\1/p')"
if [ "$n" = "1" ]; then
    ok "counted exactly 1 admission"
else
    bad "expected 1 hit, got '${n:-<no verdict>}'; output was: $out"
fi
# HERE-STRING, not `printf | grep -q`: grep -q exits on its first match and
# SIGPIPEs the producer, which under pipefail surfaces as 141 -- a failure that
# fires only when the pattern MATCHES. Caught on a sibling branch by
# check-sigpipe-verdict-pipelines-added and fixed here BEFORE that decider saw
# this PR, because the same hazard does not become acceptable by being in a
# different file.
if grep -q 'src/capped.rs' <<<"$out"; then
    ok "names the file holding the admission"
else
    bad "did not name src/capped.rs: $out"
fi
if grep -q 'src/plain.rs' <<<"$out"; then
    bad "COUNTED THE DECOY — the pattern matches words, not claims"
else
    ok "did not count the decoy"
fi

echo "arm 2 — the age is real, not merely present"
# The fixture commit is dated 2026-08-01. The age must be a plausible day count
# derived from blame, not a constant and not zero.
age="$(printf '%s\n' "$out" | sed -n 's/.*oldest \([0-9]\{1,\}\)d.*/\1/p')"
if [ -n "$age" ] && [ "$age" -ge 1 ] 2>/dev/null; then
    ok "reports an age of ${age}d from git blame"
else
    bad "no usable age in the verdict: $out"
fi

echo "arm 3 — NEGATIVE CONTROL: a tree with no admission counts zero"
R2="$W/clean"; mkdir -p "$R2/src"
git init -q "$R2" 2>/dev/null
git -C "$R2" config user.email "fixture@example.com"
git -C "$R2" config user.name "Fixture"
cp "$R/src/plain.rs" "$R2/src/plain.rs"
git -C "$R2" add -A && git -C "$R2" commit -qm "fixture: decoy only"
out2="$("$CENSUS" --root "$R2" 2>/dev/null)"
n2="$(printf '%s\n' "$out2" | sed -n 's/^ok:admitted-missing-evidence:\([0-9]\{1,\}\) .*/\1/p')"
if [ "$n2" = "0" ]; then
    ok "a clean tree reports 0 (and still emits a verdict)"
else
    bad "expected 0 on a clean tree, got '${n2:-<no verdict>}': $out2"
fi

echo "arm 4 — IT IS A REPORT, NEVER A GATE"
# The row is explicit and the reason is 1338-x5rq's 187 suppressions: this
# instrument matches honest, correct, deliberately-deferred notes, because that
# is precisely what it looks for. Gate on it and the rational response is to
# stop writing the admission — which destroys the only signal it has and leaves
# the debt behind, now invisible. So a tree FULL of hits must still exit 0.
"$CENSUS" --root "$R" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "exit 0 with hits present (a report, not a gate)"
else
    bad "exited $rc with hits present — this must never fail a build"
fi

echo "arm 5 — the counter can MOVE (the control on the control)"
# "1" proves nothing unless a second admission makes it 2. Without this, an
# arm-1 pass is consistent with a census hardcoded to answer 1.
cat > "$R/src/second.rs" <<'EOF'
// TODO: this threshold is assumed, not measured; nobody has checked it
// against a real workload yet.
pub const LIMIT: usize = 64;
EOF
git -C "$R" add -A
GIT_AUTHOR_DATE="2026-09-01T12:00:00Z" GIT_COMMITTER_DATE="2026-09-01T12:00:00Z" \
    git -C "$R" commit -qm "fixture: a second admission"
out3="$("$CENSUS" --root "$R" 2>/dev/null)"
n3="$(printf '%s\n' "$out3" | sed -n 's/^ok:admitted-missing-evidence:\([0-9]\{1,\}\) .*/\1/p')"
if [ "$n3" = "2" ]; then
    ok "adding a second admission moved the count 1 -> 2"
else
    bad "counter did not move on a second admission (read '${n3:-<none>}') — it is not counting admissions"
fi

echo "arm 6 — oldest first, because the age is the actionable part"
# The row says the actionable output is the AGE, not the sentence. A listing
# that buries the oldest debt under the newest is the same information in an
# order nobody acts on.
first_listed="$(printf '%s\n' "$out3" | grep -E '^[0-9]+d[[:space:]]' | head -1 | awk '{print $1}' | tr -d 'd')"
last_listed="$(printf '%s\n' "$out3" | grep -E '^[0-9]+d[[:space:]]' | tail -1 | awk '{print $1}' | tr -d 'd')"
if [ -n "$first_listed" ] && [ -n "$last_listed" ] && [ "$first_listed" -ge "$last_listed" ]; then
    ok "listing is oldest-first (${first_listed}d before ${last_listed}d)"
else
    bad "listing is not oldest-first: first='${first_listed}' last='${last_listed}'"
fi

echo "census fixture: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:census-admitted-missing-evidence-fixture:$pass"
exit 0
