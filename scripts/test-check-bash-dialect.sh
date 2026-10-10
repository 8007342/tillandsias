#!/usr/bin/env bash
# Two-direction fixture for check-bash-dialect (scripts/lua/check-bash-dialect.lua since 1384-ddua) (761-g36m criterion 3):
# an UNGUARDED bash-4-ism fails the gate; the SAME construct behind a
# BASH_VERSINFO refusal passes; a clean tree passes. Hermetic — scans a
# temp dir via TILLANDSIAS_DIALECT_SCAN_DIR, never the live tree.
# freshness: auditor=macos-tlatoanis-macbook-air-fable5 date=2026-08-16 verdict=refreshed scope=761-g36m authoring
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 1384-ddua: the checker is scripts/lua/check-bash-dialect.lua on the one
# runner; its scratch scans reach /tmp through the script's declared
# `-- @read-env TILLANDSIAS_DIALECT_SCAN_DIR` root, and nothing else.
CHECKER="$ROOT/scripts/lua/check-bash-dialect.lua"
PLAN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || PLAN=""
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
if [ -z "$PLAN" ] || ! grep -qx script <<<"$("$PLAN" capabilities 2>/dev/null)"; then
  echo "could-not-run:check-bash-dialect-fixture:no-script-runner — build it: cargo build --release -p tillandsias-plan"
  exit 3
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bash-dialect-fixture.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0
scenarios=0

expect() {
  # expect <name> <want-verdict> <want-exit>
  local name="$1" want="$2" want_rc="$3" got rc
  scenarios=$((scenarios + 1))
  got="$(TILLANDSIAS_DIALECT_SCAN_DIR="$TMP" "$PLAN" script run "$CHECKER" 2>/dev/null)"
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

# Empty-array expansion under set -u (761-g36m extension). Direction 1 is the
# EXACT shape that broke hash-image-sources.sh and blocked every macOS push on
# 2026-08-30: an array initialised empty, appended to only inside a branch,
# then iterated bare.
printf '#!/usr/bin/env bash\nset -euo pipefail\nfile_list=()\nif [ -n "${X:-}" ]; then\n    file_list+=("a")\nfi\nfor file in "${file_list[@]}"; do\n    echo "$file"\ndone\n' > "$TMP/emptyarr.sh"
expect "empty-array-expansion-refused" "blocked:bash4-unguarded:1" 1

# Direction 2: the remedy idiom passes. Inert when non-empty, expands to
# nothing instead of dying when empty.
printf '#!/usr/bin/env bash\nset -euo pipefail\nfile_list=()\nif [ -n "${X:-}" ]; then\n    file_list+=("a")\nfi\nfor file in ${file_list[@]+"${file_list[@]}"}; do\n    echo "$file"\ndone\n' > "$TMP/emptyarr.sh"
expect "empty-array-remedy-passes" "ok:bash-dialect-clean" 0

# The exemption marker passes, for arrays provably populated on every path.
printf '#!/usr/bin/env bash\nset -euo pipefail\nfile_list=()\nfile_list+=("a")\nfor file in "${file_list[@]}"; do # maybe-empty: ok (populated above)\n    echo "$file"\ndone\n' > "$TMP/emptyarr.sh"
expect "empty-array-exemption-passes" "ok:bash-dialect-clean" 0

# Scope guard: a COUNT on an empty array is safe on bash 3.2 (verified: yields
# 0, does not error), so count guards must NOT be flagged.
printf '#!/usr/bin/env bash\nset -euo pipefail\nfile_list=()\nif [ "${#file_list[@]}" -eq 0 ]; then echo none; fi\n' > "$TMP/emptyarr.sh"
expect "array-count-not-flagged" "ok:bash-dialect-clean" 0

# Scope guard: without set -u the construct is harmless on both dialects.
printf '#!/usr/bin/env bash\nfile_list=()\nfor file in "${file_list[@]}"; do\n    echo "$file"\ndone\n' > "$TMP/emptyarr.sh"
expect "no-set-u-not-flagged" "ok:bash-dialect-clean" 0
rm "$TMP/emptyarr.sh"

# 1373-sr9g: sourcing a process substitution defines nothing on bash 3.2.
# MUTATION ARM: the exact pre-fix line from test-preflight-scratch-is-off-checkout.sh:102.
printf '#!/usr/bin/env bash\n    . <(sed -n %s "$SIDECAR")\n' "'/if \\[ -n \"\\\${TILLANDSIAS_SIDECAR_TARGET_DIR/,/^fi/p'" > "$TMP/procsub.sh"
expect "dot-procsub-refused" "blocked:bash4-unguarded:1" 1
printf '#!/usr/bin/env bash\nsource <(printf X=1)\n' > "$TMP/procsub.sh"
expect "source-procsub-refused" "blocked:bash4-unguarded:1" 1
# The remedy passes, and so does a process substitution that is not sourced.
printf '#!/usr/bin/env bash\n    eval "$(sed -n %s "$SIDECAR")"\n' "'/if \\[ -n \"\\\${TILLANDSIAS_SIDECAR_TARGET_DIR/,/^fi/p'" > "$TMP/procsub.sh"
expect "eval-remedy-passes" "ok:bash-dialect-clean" 0
printf '#!/usr/bin/env bash\ndiff <(sort a) <(sort b)\nwhile read -r l; do :; done < <(ls)\n' > "$TMP/procsub.sh"
expect "unsourced-procsub-not-flagged" "ok:bash-dialect-clean" 0
printf '#!/usr/bin/env bash\n. <(printf X=1) # procsub-source: ok (fixture)\n' > "$TMP/procsub.sh"
expect "procsub-exemption-passes" "ok:bash-dialect-clean" 0
rm "$TMP/procsub.sh"

# 1399-wtpq: a multi-line value in `awk -v` is EMPTY on BSD awk ("newline in
# string"). The two real call sites of 2026-09-26, verbatim in shape; both
# were masked (the 88tp block ran under `2>/dev/null || true`, the tsfu join
# had no rc check), which is why each read as a clean run on darwin.
cat > "$TMP/awkv.sh" <<'EOF'
#!/usr/bin/env bash
_pt_digests="$(tr '\n' '\0' <<<"$_pt_files" | xargs -0 sha256sum 2>/dev/null || true)"
{ printf '%s' "$_PER_TEST_LOG" | awk -F'\t' \
    -v digests="$_pt_digests" \
    'BEGIN { n = split(digests, dl, "\n") } { print }'; } 2>/dev/null || true
EOF
expect "awkv-88tp-digests-refused" "blocked:bash4-unguarded:1" 1
cat > "$TMP/awkv.sh" <<'EOF'
#!/usr/bin/env bash
floor_text="$(grep -vE '^#' "$FLOOR")"
joined="$(awk -v ft="$floor_text" '
    BEGIN { n = split(ft, L, "\n") } NF == 2 { print }' <<<"$counts")"
EOF
expect "awkv-tsfu-floor-refused" "blocked:bash4-unguarded:1" 1
# The remedy passes; so does a scalar -v the program never splits on "\n";
# so does the exemption marker on the -v line.
cat > "$TMP/awkv.sh" <<'EOF'
#!/usr/bin/env bash
joined="$(FT="$floor_text" awk 'BEGIN { n = split(ENVIRON["FT"], L, "\n") }' <<<"$counts")"
EOF
expect "awkv-environ-remedy-passes" "ok:bash-dialect-clean" 0
cat > "$TMP/awkv.sh" <<'EOF'
#!/usr/bin/env bash
ps -W | awk -v p="$pid" '$4 == p { found = 1 } END { exit !found }'
EOF
expect "awkv-scalar-not-flagged" "ok:bash-dialect-clean" 0
cat > "$TMP/awkv.sh" <<'EOF'
#!/usr/bin/env bash
awk -v t="$tags" 'BEGIN { n = split(t, T, "\n") }' # awk-v-multiline: ok (fixture)
EOF
expect "awkv-exemption-passes" "ok:bash-dialect-clean" 0
rm "$TMP/awkv.sh"

# 1413-8bee: an unparenthesised case arm inside $( ) does not parse on bash
# 3.2 (measured, both shapes). The keyword is spliced in with %s so this file,
# which the live scan also reads, never spells the shape it refuses.
C=case
printf '#!/usr/bin/env bash\nx=$(%s "$1" in /*) echo a ;; *) echo r ;; esac)\n' "$C" > "$TMP/cics.sh"
expect "case-in-cs-single-line-refused" "blocked:bash4-unguarded:1" 1
printf '#!/usr/bin/env bash\nx=$(%s "$1" in (/*) echo a ;; (*) echo r ;; esac)\n' "$C" > "$TMP/cics.sh"
expect "case-in-cs-single-line-parenthesised-passes" "ok:bash-dialect-clean" 0
printf '#!/usr/bin/env bash\nx=$(\n  %s "$1" in\n    /*) echo a ;;\n    *) echo r ;;\n  esac\n)\n' "$C" > "$TMP/cics.sh"
expect "case-in-cs-multi-line-refused" "blocked:bash4-unguarded:1" 1
printf '#!/usr/bin/env bash\nx=$(\n  %s "$1" in\n    (/*) echo a ;;\n    (*) echo r ;;\n  esac\n)\n' "$C" > "$TMP/cics.sh"
expect "case-in-cs-multi-line-parenthesised-passes" "ok:bash-dialect-clean" 0
# The 84f37ff24 shape: quoted, with a NESTED $( ) before the case. bash -n
# passes it; at runtime the value is the rest of the line as text.
printf '#!/usr/bin/env bash\nP="$(cd / && _p="$(pwd)" && %s "$_p" in /*) printf a ;; *) printf r ;; esac)"\n' "$C" > "$TMP/cics.sh"
expect "case-in-cs-quoted-nested-refused" "blocked:bash4-unguarded:1" 1
printf '#!/usr/bin/env bash\nx=$(%s "$1" in /*) echo a ;; esac) # case-in-cs: ok (fixture)\n' "$C" > "$TMP/cics.sh"
expect "case-in-cs-exemption-passes" "ok:bash-dialect-clean" 0
# A case in a plain ( ) subshell, or in a function called through $(f), parses.
printf '#!/usr/bin/env bash\n( %s "$1" in /*) echo a ;; esac )\nf() { %s "$1" in /*) echo a ;; esac; }\nx=$(f "$1")\n' "$C" "$C" > "$TMP/cics.sh"
expect "case-outside-cs-passes" "ok:bash-dialect-clean" 0
# TILLANDSIAS_DIALECT_SCAN_FILES scopes like SCAN_DIR (the enclave-service-health
# litmus used that name, which was never read: a "one-file" check scanned the
# whole tree). Ignored, this falls back to the clean live tree and reads ok.
printf '#!/usr/bin/env bash\nx=$(%s "$1" in /*) echo a ;; esac)\n' "$C" > "$TMP/cics.sh"
scenarios=$((scenarios + 1))
got="$(TILLANDSIAS_DIALECT_SCAN_FILES="$TMP/cics.sh" "$PLAN" script run "$CHECKER" 2>/dev/null)"
[ "$got" = "blocked:bash4-unguarded:1" ] \
  || { echo "FAIL: scan-files-alias-scopes — got '$got'" >&2; fails=$((fails + 1)); }
rm "$TMP/cics.sh"

# 1374-4u6i: the count is FILES. One file tripping two rules is one; two
# offending files are two.
printf '#!/usr/bin/env bash\nmap%s -t arr < "$1"\n' 'file' > "$TMP/two-a.sh"
printf '#!/usr/bin/env bash\nx="$1"\nprintf %%s "${x,,}"\n' > "$TMP/two-b.sh"
expect "two-files-count-two" "blocked:bash4-unguarded:2" 1
rm "$TMP/two-a.sh" "$TMP/two-b.sh"

# ── 1553-x8js: sed brace groups, suffixless sed -i, stat -c without -f ─────
# Each rule goes RED on a planted violation and GREEN on the portable form: a
# rule that never fires is not a guard. Every planted file is checked to be
# the file intended (non-empty, holding the construct) before its verdict
# counts, so a heredoc that silently wrote nothing cannot pass for a refusal.
plant() { # plant <file> <must-contain> ; content on stdin
  cat > "$1"
  if [ ! -s "$1" ] || ! grep -qF -- "$2" "$1"; then
    echo "FAIL: MUTATION SETUP $1 is empty or lacks '$2' — the arm proves nothing" >&2
    fails=$((fails + 1))
  fi
}
S=sed   # spliced, so this file never spells an invocation it refuses
X="$TMP/x8.sh"
plant "$X" '{p}' <<EOF
#!/usr/bin/env bash
$S -n '/a/{p}' "\$1"
EOF
expect "sed-brace-p-refused" "blocked:bash4-unguarded:1" 1
plant "$X" '{p;}' <<EOF
#!/usr/bin/env bash
$S -n '/a/{p;}' "\$1"
EOF
expect "sed-brace-p-terminated-passes" "ok:bash-dialect-clean" 0
# The 1545-qdb5 / test-plan-only-lane-structural.sh:99 shape, verbatim in form.
plant "$X" 'return 1#}' <<EOF
#!/usr/bin/env bash
$S "\\\\#marker line#{n;s#return 0#return 1#}" "\$G" > "\$M"
EOF
expect "sed-brace-hash-delim-refused" "blocked:bash4-unguarded:1" 1
plant "$X" 'return 1#;}' <<EOF
#!/usr/bin/env bash
$S "\\\\#marker line#{n;s#return 0#return 1#;}" "\$G" > "\$M"
EOF
expect "sed-brace-hash-delim-terminated-passes" "ok:bash-dialect-clean" 0
plant "$X" '{s/x/y/}' <<EOF
#!/usr/bin/env bash
$S '/a/{s/x/y/}' "\$1"
EOF
expect "sed-brace-subst-refused" "blocked:bash4-unguarded:1" 1
plant "$X" '{p;}}' <<EOF
#!/usr/bin/env bash
$S -n '1{/a/{p;}}' "\$1"
EOF
expect "sed-brace-nested-close-refused" "blocked:bash4-unguarded:1" 1
plant "$X" '{p;};}' <<EOF
#!/usr/bin/env bash
$S -n '1{/a/{p;};}' "\$1"
x="\${HOME}/s/{a}"; $S "s/\${x}/{lit}/" "\$1"
EOF
expect "sed-brace-nested-terminated-and-braces-in-text-pass" "ok:bash-dialect-clean" 0
# Several -e scripts are one script joined by newlines (check-claim-protocol-agrees.sh:58).
plant "$X" "-e '}'" <<EOF
#!/usr/bin/env bash
$S -e ':a' -e '/\\\\\$/{N;s/\\\\\\n//;ba' -e '}' "\$1"
EOF
expect "sed-brace-multi-e-newline-passes" "ok:bash-dialect-clean" 0
# A brace group closed on its own line inside a multi-line quoted script.
plant "$X" '/a/{' <<EOF
#!/usr/bin/env bash
$S -n '/a/{
p
}' "\$1"
EOF
expect "sed-brace-multi-line-passes" "ok:bash-dialect-clean" 0
plant "$X" "sed-brace: ok (" <<EOF
#!/usr/bin/env bash
$S -n '/a/{p}' "\$1" # sed-brace: ok (fixture: GNU-only tool, never run on darwin)
EOF
expect "sed-brace-marker-with-reason-passes" "ok:bash-dialect-clean" 0
plant "$X" "sed-brace: ok" <<EOF
#!/usr/bin/env bash
$S -n '/a/{p}' "\$1" # sed-brace: ok
EOF
expect "sed-brace-marker-without-reason-refused" "blocked:bash4-unguarded:1" 1

for form in "-i 's/a/b/' \"\$f\"" "-i \"s/a/\$v/\" \"\$f\"" "-i '2i cat >/dev/null' \"\$f\"" "-i '' 's/a/b/' \"\$f\"" "-n -i 's/a/b/' \"\$f\""; do
  printf '#!/usr/bin/env bash\n%s %s\n' "$S" "$form" | plant "$X" "$S -"
  expect "sed-i-suffixless-refused[$form]" "blocked:bash4-unguarded:1" 1
done
plant "$X" ' > "$f.tmp" && mv' <<EOF
#!/usr/bin/env bash
$S 's/a/b/' "\$f" > "\$f.tmp" && mv "\$f.tmp" "\$f"
$S -i.bak 's/a/b/' "\$f" && rm -f "\$f.bak"
echo "never write $S -i 's/a/b/' here"
EOF
expect "sed-i-portable-forms-and-mention-pass" "ok:bash-dialect-clean" 0

T=stat
plant "$X" "$T -c" <<EOF
#!/usr/bin/env bash
m="\$($T -c %Y "\$d" 2>/dev/null || echo '')"
EOF
expect "stat-c-no-fallback-refused" "blocked:bash4-unguarded:1" 1
plant "$X" "$T -f -c" <<EOF
#!/usr/bin/env bash
t="\$($T -f -c %T "\$d" 2>/dev/null)" || t=""
EOF
expect "stat-f-c-gnu-filesystem-mode-refused" "blocked:bash4-unguarded:1" 1
plant "$X" "|| $T -f" <<EOF
#!/usr/bin/env bash
m="\$($T -c %Y "\$d" 2>/dev/null || $T -f %m "\$d" 2>/dev/null)"
if ! mode="\$($T -c '%a' "\$f" 2>/dev/null)"; then
    mode="\$($T -f '%Lp' "\$f")"
fi
EOF
expect "stat-c-with-bsd-fallback-passes" "ok:bash-dialect-clean" 0
plant "$X" "_mt()" <<EOF
#!/usr/bin/env bash
_mt() {
  local m
  m="\$($T -c %Y "\$1" 2>/dev/null)" && { echo "\$m"; return; }
  :
  :
  :
  :
  $T -f %m "\$1"
}
EOF
expect "stat-c-fallback-in-same-function-passes" "ok:bash-dialect-clean" 0
plant "$X" "stat-c: ok (" <<EOF
#!/usr/bin/env bash
t="\$($T -c %a /dev/net/tun 2>/dev/null)" # stat-c: ok (linux-only device probe)
EOF
expect "stat-c-marker-with-reason-passes" "ok:bash-dialect-clean" 0
rm -f "$X"

# HOST REALITY, so the rule answers the question that matters (does THIS sed
# refuse it?) and not only the question it was written to (does it match?).
# On BSD sed every refused script must FAIL and every passing one succeed; on
# GNU sed only the passing half is decidable. The red forms are BSD-fatal by
# measurement, not by assertion, on every darwin run of this fixture.
printf 'a\nreturn 0\nb\n' > "$TMP/in.txt"
if sed --version >/dev/null 2>&1; then BSD=0; else BSD=1; fi
for red in '/a/{p}' '/a/{n;s#return 0#return 1#}' '/a/{s/a/X/}' '1{/a/{p;}}'; do
  scenarios=$((scenarios + 1))
  if [ "$BSD" = 1 ] && sed -n "$red" "$TMP/in.txt" >/dev/null 2>&1; then
    echo "FAIL: host-reality: BSD sed ACCEPTED '$red', which the rule refuses — the rule is wrong" >&2
    fails=$((fails + 1))
  fi
done
for green in '/a/{p;}' '/a/{n;s#return 0#return 1#;}' '/a/{s/a/X/;}' '1{/a/{p;};}'; do
  scenarios=$((scenarios + 1))
  if ! sed -n "$green" "$TMP/in.txt" >/dev/null 2>&1; then
    echo "FAIL: host-reality: this host's sed REFUSED '$green', which the rule passes" >&2
    fails=$((fails + 1))
  fi
done
scenarios=$((scenarios + 1))
cp "$TMP/in.txt" "$TMP/in2.txt"
sed 's/return 0/return 1/' "$TMP/in2.txt" > "$TMP/in2.txt.tmp" && mv "$TMP/in2.txt.tmp" "$TMP/in2.txt"
grep -qx 'return 1' "$TMP/in2.txt" \
  || { echo "FAIL: host-reality: the portable 'sed EXPR f > f.tmp && mv' form did not edit" >&2; fails=$((fails + 1)); }

if [ "$fails" -gt 0 ]; then
  echo "FAIL: check-bash-dialect fixture: $fails scenario(s) diverged" >&2
  exit 1
fi
echo "PASS: check-bash-dialect fixture $scenarios/$scenarios scenarios green"
exit 0
