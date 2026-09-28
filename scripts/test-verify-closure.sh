#!/usr/bin/env bash
# @trace order:1443-qwpj, spec:meta-orchestration
#
# Fixture for scripts/verify-closure.sh (order 1443-qwpj), over a scratch
# ledger and a scratch repo holding the scripts the closures name:
#
#   1. closure "bash scripts/x.sh prints ok:x:3/3 and exits 0, where …" and x.sh
#      prints ok:x:3/3, rc 0 -> ok:closure:<o>:ok:x:3/3, exit 0;
#   2. the script prints ok:x:2/3 -> unmet:closure:<o>:expected=ok:x:3/3
#      measured=ok:x:2/3, exit 1;
#   3. the expected line is present but rc is non-zero -> unmet:closure:<o>:rc=<n>, exit 1;
#   4. a <placeholder> in the expected token matches any non-empty token;
#   5. NEGATIVE CONTROL: a closure with no leading command of the scorable
#      grammar -> unscoreable:closure:<o>:no-command-grammar, exit 2, never ok;
#   6. NEGATIVE CONTROL: `--claim met` with an unmet measurement is ignored ->
#      unmet, exit 1;
#   7. the 1437-gbwi shape: a command that exits 0 plus a prose threshold ->
#      unscoreable:…:uncovered-criterion, exit 2 (the misreport this row exists for);
#   8. an rc-only closure whose command SKIPS (last line skip:…, rc 0) ->
#      unmet:…:skipped:…, exit 1: a skip exercised nothing.
#
# PRE-FIX RESULT: FAILS — scripts/verify-closure.sh did not exist, and nothing
# between a delegate's report and its acceptance ran the closure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VC="$ROOT/scripts/verify-closure.sh"
pass=0; total=8
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

[ -f "$VC" ] || { echo "fail:verify-closure:0/$total (scripts/verify-closure.sh missing)"; exit 1; }
_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
[ -n "$_plan" ] || { echo "skip:verify-closure:no-plan-binary — build one: cargo build --release -p tillandsias-plan"; exit 0; }
export TILLANDSIAS_PLAN_BIN="$_plan"

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/verify-closure.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# A scratch repo: scripts/x.sh prints $X_LINE and exits $X_RC (both from a file,
# so each arm rewrites the file rather than relying on environment the verifier
# might not pass through).
R="$W/repo"; mkdir -p "$R/scripts" "$R/plan/index.d"
cat > "$R/scripts/x.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/x.conf"
echo "some preamble"
printf '%s\n' "$X_LINE"
exit "$X_RC"
EOF
chmod +x "$R/scripts/x.sh"
setx() { printf 'X_LINE=%q\nX_RC=%s\n' "$1" "$2" > "$R/scripts/x.conf"; }

printf 'packets: []\n' > "$R/plan/index.yaml"
row() { # row <order> <closure text>
    {
        printf 'packets:\n  - packet_id: row-%s\n    order: %s\n    status: ready\n' "$1" "$1"
        printf '    kind: bug\n    priority: p2\n    desired_release: v0.5\n    pickup_role: any\n'
        printf '    title: a fixture row\n    verifiable_closure: |\n'
        printf '%s\n' "$2" | sed 's/^/      /'
    } > "$R/plan/index.d/20260928t000000z-$1-fixture.yaml"
}
row 1-aaaa 'bash scripts/x.sh prints ok:x:3/3 and exits 0, where the three
arms are described here in prose. PRE-FIX RESULT: FAILS.'
row 1-bbbb 'bash scripts/x.sh prints hit:<key12> and exits 0.'
row 1-cccc 'The operator confirms the tray looks right after a restart.'
row 1-dddd 'bash scripts/x.sh exits 0 with every existing ok line unchanged, and
the timing record carries duration_ms under 20,000 on this host.'
row 1-eeee 'bash scripts/x.sh exits 0 with the four arms above.'

vc() { OUT="$(bash "$VC" "$@" --index "$R/plan/index.yaml" --root "$R" 2>/dev/null)"; RC=$?; }

# 1 — met.
setx "ok:x:3/3" 0; vc 1-aaaa
[ "$RC" -eq 0 ] && [ "$OUT" = "ok:closure:1-aaaa:ok:x:3/3" ] \
    && ok "arm 1: expected line printed, rc 0 -> ok:closure:1-aaaa:ok:x:3/3" \
    || bad "arm 1: rc=$RC out=[$OUT]"

# 2 — the wrong count is unmet, and names what was measured.
setx "ok:x:2/3" 0; vc 1-aaaa
[ "$RC" -eq 1 ] && [ "$OUT" = "unmet:closure:1-aaaa:expected=ok:x:3/3 measured=ok:x:2/3" ] \
    && ok "arm 2: ok:x:2/3 -> unmet expected=ok:x:3/3 measured=ok:x:2/3" \
    || bad "arm 2: rc=$RC out=[$OUT]"

# 3 — the right line with the wrong exit code is unmet.
setx "ok:x:3/3" 3; vc 1-aaaa
[ "$RC" -eq 1 ] && [ "$OUT" = "unmet:closure:1-aaaa:rc=3" ] \
    && ok "arm 3: expected line but rc 3 -> unmet:closure:1-aaaa:rc=3" \
    || bad "arm 3: rc=$RC out=[$OUT]"

# 4 — placeholders match any non-empty token, and only a token.
setx "hit:0123456789ab" 0; vc 1-bbbb; rc4a=$RC; out4a="$OUT"
setx "hit:" 0; vc 1-bbbb; rc4b=$RC
[ "$rc4a" -eq 0 ] && [ "$out4a" = "ok:closure:1-bbbb:hit:0123456789ab" ] && [ "$rc4b" -eq 1 ] \
    && ok "arm 4: hit:<key12> matches hit:0123456789ab, and not an empty hit:" \
    || bad "arm 4: filled rc=$rc4a [$out4a] | empty rc=$rc4b"

# 5 — NEGATIVE CONTROL: prose with no command is refused, never ok.
setx "ok:x:3/3" 0; vc 1-cccc
[ "$RC" -eq 2 ] && [ "$OUT" = "unscoreable:closure:1-cccc:no-command-grammar" ] \
    && ok "arm 5: no command grammar -> unscoreable:…:no-command-grammar, exit 2" \
    || bad "arm 5: rc=$RC out=[$OUT]"

# 6 — NEGATIVE CONTROL: a delegate's "met" is not an input.
setx "ok:x:2/3" 0; vc 1-aaaa --claim met
[ "$RC" -eq 1 ] && [ "${OUT#unmet:closure:1-aaaa:}" != "$OUT" ] \
    && ok "arm 6: --claim met with an unmet measurement -> still unmet" \
    || bad "arm 6: rc=$RC out=[$OUT]"

# 7 — the 1437-gbwi shape: rc 0 is not the criterion.
setx "anything" 0; vc 1-dddd
case "$OUT" in unscoreable:closure:1-dddd:uncovered-criterion:*) shape=1 ;; *) shape=0 ;; esac
[ "$RC" -eq 2 ] && [ "$shape" = 1 ] \
    && ok "arm 7: a command that exits 0 plus a prose threshold -> uncovered-criterion, exit 2" \
    || bad "arm 7: rc=$RC out=[$OUT]"

# 8 — an rc-only closure cannot be satisfied by a skip.
setx "skip:x:no-plan-binary — build one" 0; vc 1-eeee; rc8=$RC; out8="$OUT"
setx "ok:x:4/4" 0; vc 1-eeee; rc8b=$RC; out8b="$OUT"
[ "$rc8" -eq 1 ] && [ "$out8" = "unmet:closure:1-eeee:skipped:skip:x:no-plan-binary" ] \
   && [ "$rc8b" -eq 0 ] && [ "$out8b" = "ok:closure:1-eeee:rc=0" ] \
    && ok "arm 8: rc-only closure -> a skip is unmet, a real pass is ok" \
    || bad "arm 8: skip rc=$rc8 [$out8] | pass rc=$rc8b [$out8b]"

if [ "$pass" -eq "$total" ]; then
    echo "ok:verify-closure:$pass/$total"
    exit 0
fi
echo "fail:verify-closure:$pass/$total"
exit 1
