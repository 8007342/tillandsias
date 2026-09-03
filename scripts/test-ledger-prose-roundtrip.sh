#!/usr/bin/env bash
# freshness: added 2026-09-03 lenovinha-tillandsias-forge (order 971-7muc)
# @trace order:971-7muc
#
# test-ledger-prose-roundtrip.sh — does the ledger store the prose it was given,
# byte for byte, including the characters a shell would have eaten?
#
# ── THE DEFECT (order 971-7muc) ──────────────────────────────────────────────
#
# Two hosts, one evening, independently: an event summary passed to
# `append-event` as a shell argument had backtick-quoted tokens
# command-substituted away before the program ever started, and the stored text
# read "only  licenses reading accel_mem_budget_gb as the whole machine" — the
# SUBJECT of the sentence silently deleted.
#
# WHAT MAKES IT WORTH A TEST RATHER THAN A NOTE: the corruption produces VALID
# YAML AND PLAUSIBLE PROSE. validate-yaml passes it, `plan check` passes it, the
# fragment-keys guard passes it, `./build.sh --check` passes it. Every instrument
# reports success because each measures something adjacent to what broke. Only a
# byte-identity assertion can see it.
#
# Prose that quotes an identifier is prose explaining WHY something is named what
# it is — precisely what the ledger exists to carry, and backticks are how anyone
# writes that. So this bites hardest on the most valuable writes.
#
# ── WHAT IS ASSERTED ─────────────────────────────────────────────────────────
#   1. --summary-file  round-trips backticks, $(...) and $VAR byte-identically.
#   2. --summary-file -  (stdin) does the same.
#   3. The argv path REFUSES residue: unbalanced backtick, and a literal `$(`.
#   4. The argv path still accepts correctly-quoted balanced prose.
#   5. THE NEGATIVE CONTROL: the historical hazard is reproduced through a real
#      shell, proving the mangling is silent and that the file path avoids it.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${TILLANDSIAS_PLAN_BIN:-}"
# Respect CARGO_TARGET_DIR: on a host that redirects it (every forge does), the
# in-tree target/ is absent and falling through to the INSTALLED binary would
# silently test a different build than the one just compiled — which is how the
# first run of this test reported five failures against a stale artifact.
if [ -z "$BIN" ]; then
    for cand in "${CARGO_TARGET_DIR:-$ROOT/target}/release/tillandsias-plan" \
                "$ROOT/target/release/tillandsias-plan"; do
        [ -x "$cand" ] && { BIN="$cand"; break; }
    done
fi
[ -n "$BIN" ] && [ -x "$BIN" ] || BIN="$(command -v tillandsias-plan 2>/dev/null || true)"
if [ ! -x "$BIN" ]; then
    echo "SKIP: no tillandsias-plan binary (build with: cargo build --release -p tillandsias-plan)"
    exit 0
fi

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  [OK]   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }

# The exact shape that was lost in the field: an identifier in backticks, a
# command substitution, and a variable — all of which must survive verbatim.
PROSE='Only `accel_mem_budget_gb` licenses reading it as the whole machine.
A card will read $(nproc) and $HOME, and that is the correct answer.
Trailing `balanced` pair.'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf '%s' "$PROSE" > "$WORK/note.md"

# ── 1. file round-trip ───────────────────────────────────────────────────────
# Compare what the tool READ against the source, without needing a live ledger:
# a bad ref exits before any write, so stderr tells us nothing about the prose.
# Instead assert on the file reader directly through a real append to a scratch
# ledger.
cat > "$WORK/index.yaml" <<'YEOF'
packets:
  - packet_id: roundtrip-fixture
    order: 000-test
    status: ready
    title: |
      fixture
YEOF

run_append() { # $1=extra args... ; writes into $WORK
    ( cd "$WORK" && TILLANDSIAS_AGENT_ID=linux-testhost-opus5-20260903t054300z "$BIN" --index "$WORK/index.yaml" \
        append-event roundtrip-fixture note "$@" --host testhost 2>&1 )
}

out="$(run_append --summary-file "$WORK/note.md")"
rc=$?
stored="$(cat "$WORK"/index.d/*.yaml 2>/dev/null || true)"
if [ $rc -ne 0 ] && [ -z "$stored" ]; then
    bad "--summary-file write failed: $out"
else
    # Extract the block scalar body and compare to the source.
    got="$(printf '%s\n' "$stored" | awk '
        /^[[:space:]]*summary: \|/ { insum=1; next }
        insum {
            if ($0 !~ /^[[:space:]]{8}/ && $0 != "") { insum=0; next }
            sub(/^        /, ""); print
        }')"
    if [ "$(printf '%s' "$got")" = "$(printf '%s' "$PROSE")" ]; then
        ok "--summary-file round-trips backticks, \$(...) and \$VAR byte-identically"
    else
        bad "--summary-file altered the prose"
        printf '    want: %s\n' "$(printf '%s' "$PROSE" | head -1)"
        printf '    got : %s\n' "$(printf '%s' "$got" | head -1)"
    fi
fi
rm -rf "$WORK"/index.d

# ── 2. stdin round-trip ──────────────────────────────────────────────────────
out="$( cd "$WORK" && TILLANDSIAS_AGENT_ID=linux-testhost-opus5-20260903t054300z "$BIN" --index "$WORK/index.yaml" \
    append-event roundtrip-fixture note --summary-file - --host testhost < "$WORK/note.md" 2>&1 )"
stored="$(cat "$WORK"/index.d/*.yaml 2>/dev/null || true)"
if printf '%s' "$stored" | grep -q 'accel_mem_budget_gb' \
   && printf '%s' "$stored" | grep -q '\$(nproc)' \
   && printf '%s' "$stored" | grep -q '`balanced`'; then
    ok "--summary-file - (stdin) preserves backticks and \$(...)"
else
    bad "stdin path lost characters: $out"
fi
rm -rf "$WORK"/index.d

# ── 3. argv refuses residue ──────────────────────────────────────────────────
out="$(run_append --summary 'lost the closing ` here')"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'unbalanced backtick'; then
    ok "argv path REFUSES an unbalanced backtick"
else
    bad "argv path accepted an unbalanced backtick (rc=$rc)"
fi

out="$(run_append --summary 'a literal $(hostname) survived')"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'command substitution'; then
    ok "argv path REFUSES a literal \$("
else
    bad "argv path accepted a literal \$( (rc=$rc)"
fi
rm -rf "$WORK"/index.d

# ── 4. argv still accepts correct prose ──────────────────────────────────────
out="$(run_append --summary 'a `balanced` pair is correct quoting')"; rc=$?
if [ $rc -eq 0 ]; then
    ok "argv path still accepts balanced backticks (correct single-quoting)"
else
    bad "argv path rejected legitimate balanced prose: $out"
fi
rm -rf "$WORK"/index.d

# ── 5. NEGATIVE CONTROL: reproduce the historical silent mangling ────────────
# This is the part that proves the test is testing something. Run the ORIGINAL
# hazardous form through a real shell and confirm the word vanishes with no
# error — then confirm the sanctioned path keeps it.
mangled="$(eval 'printf "%s" "only `printf %s ""` licenses reading it"' 2>/dev/null)"
if [ "$mangled" = "only  licenses reading it" ]; then
    ok "negative control: the shell silently deletes backticked text (no error)"
else
    bad "negative control did not reproduce the mangling (got: '$mangled')"
fi

printf '\n  passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "ok:ledger-prose-roundtrip"
