#!/usr/bin/env bash
# Two-direction fixture for check-bash-dialect.sh (761-g36m criterion 3):
# an UNGUARDED bash-4-ism fails the gate; the SAME construct behind a
# BASH_VERSINFO refusal passes; a clean tree passes. Hermetic — scans a
# temp dir via TILLANDSIAS_DIALECT_SCAN_DIR, never the live tree.
# freshness: auditor=macos-tlatoanis-macbook-air-fable5 date=2026-08-16 verdict=refreshed scope=761-g36m authoring
set -u

CHECKER="$(cd "$(dirname "$0")" && pwd)/check-bash-dialect.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bash-dialect-fixture.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0

expect() {
  # expect <name> <want-verdict> <want-exit>
  local name="$1" want="$2" want_rc="$3" got rc
  got="$(TILLANDSIAS_DIALECT_SCAN_DIR="$TMP" bash "$CHECKER" 2>/dev/null)"
  rc=$?
  if [ "$got" != "$want" ] || [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL: $name — got '$got' (rc=$rc), want '$want' (rc=$want_rc)" >&2
    fails=$((fails + 1))
  fi
}

# Direction 1: an unguarded bash-4 lowercase expansion is refused.
printf '#!/usr/bin/env bash\nx="$1"\nprintf %%s "${x,,}"\n' > "$TMP/bad.sh"
expect "unguarded-expansion-refused" "blocked:bash4-unguarded:1" 1

# Direction 2: the SAME construct behind an executable version refusal passes.
printf '#!/usr/bin/env bash\nif [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo "refused:bash4-required" >&2; exit 3; fi\nx="$1"\nprintf %%s "${x,,}"\n' > "$TMP/guarded.sh"
rm "$TMP/bad.sh"
expect "guarded-expansion-passes" "ok:bash-dialect-clean" 0

# Clean tree passes.
rm "$TMP/guarded.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$TMP/clean.sh"
expect "clean-tree-passes" "ok:bash-dialect-clean" 0

# The builtin family is caught too (mapfile spelled out in a fixture file —
# this test file itself splits the literal so the checker never self-matches
# on it via the scripts/ scan exclusion).
printf '#!/usr/bin/env bash\nmap%s -t arr < "$1"\n' 'file' > "$TMP/builtin.sh"
rm "$TMP/clean.sh"
expect "unguarded-builtin-refused" "blocked:bash4-unguarded:1" 1

# The dual-dialect marker admits a probed-fallback file (agent-identity.sh
# idiom) without a BASH_VERSINFO head guard.
printf '#!/usr/bin/env bash\n# bash-dialect: dual (probed fallback)\nif TZ=UTC0 printf '"'"'%%(%%s)T'"'"' -1 >/dev/null 2>&1; then TZ=UTC0 printf '"'"'%%(%%s)T'"'"' -1; else date +%%s; fi\n' > "$TMP/dual.sh"
rm "$TMP/builtin.sh"
expect "dual-marker-passes" "ok:bash-dialect-clean" 0

# A comment MENTIONING a construct never trips the gate — only code does.
printf '#!/usr/bin/env bash\n# never use ${x,,} or mapfile here\necho ok\n' > "$TMP/commented.sh"
rm "$TMP/dual.sh"
expect "comment-mention-passes" "ok:bash-dialect-clean" 0

# 766-tdij direction 1: an unexempted GNU-date-ism is refused — BSD date
# succeeds with garbage, so only the lint can catch it.
printf '#!/usr/bin/env bash\nt="$(date +%%s%%3N)"\necho "$t"\n' > "$TMP/gnudate.sh"
rm "$TMP/commented.sh"
expect "unexempted-gnu-date-refused" "blocked:bash4-unguarded:1" 1

# 766-tdij direction 2: the SAME construct with the line-level exemption
# (digit-validated fallback claim) passes.
printf '#!/usr/bin/env bash\nt="$(date +%%s%%3N)" # gnu-date: ok (digit-validated)\necho "$t"\n' > "$TMP/gnudate-ok.sh"
rm "$TMP/gnudate.sh"
expect "exempted-gnu-date-passes" "ok:bash-dialect-clean" 0

# date -d with INTERVENING flags is caught (the gap that let
# test-ledger-ts-guard.sh's `date -u -d "@epoch"` ship broken on BSD).
printf '#!/usr/bin/env bash\nt=$(date -u -d "@123" +%%s)\necho "$t"\n' > "$TMP/dated-u.sh"
rm "$TMP/gnudate-ok.sh"
expect "date-u-d-refused" "blocked:bash4-unguarded:1" 1
rm "$TMP/dated-u.sh"

# date -d (GNU relative-date form) is caught too.
printf '#!/usr/bin/env bash\ndate -d yesterday +%%Y\n' > "$TMP/dated.sh"
expect "date-d-refused" "blocked:bash4-unguarded:1" 1
rm "$TMP/dated.sh"

# Combined declare flags (-gA) are caught; plain indexed `declare -a` is not.
printf '#!/usr/bin/env bash\ndeclare -gA M=()\n' > "$TMP/assoc.sh"
expect "declare-gA-refused" "blocked:bash4-unguarded:1" 1
printf '#!/usr/bin/env bash\ndeclare -a L=()\necho ok\n' > "$TMP/indexed.sh"
rm "$TMP/assoc.sh"
expect "declare-a-passes" "ok:bash-dialect-clean" 0
rm "$TMP/indexed.sh"

# `local -A` inside a function is the same bash-4 feature and the form that
# actually hid in scripts/hooks/ (784-dwkh); plain `local -r` must still pass.
printf '#!/usr/bin/env bash\nf() { local -A m=(); m[x]=1; }\nf\n' > "$TMP/localassoc.sh"
expect "local-A-refused" "blocked:bash4-unguarded:1" 1
printf '#!/usr/bin/env bash\nf() { local -r x=1; echo "$x"; }\nf\n' > "$TMP/localr.sh"
rm "$TMP/localassoc.sh"
expect "local-r-passes" "ok:bash-dialect-clean" 0
rm "$TMP/localr.sh"

if [ "$fails" -gt 0 ]; then
  echo "FAIL: check-bash-dialect fixture: $fails scenario(s) diverged" >&2
  exit 1
fi
echo "PASS: check-bash-dialect fixture 14/14 scenarios green"
exit 0
