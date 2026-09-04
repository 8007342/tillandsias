#!/usr/bin/env bash
# @trace order:901-jtvi
#
# test-litmus-grep-escapes.sh — pin check-litmus-grep-escapes.sh.
#
# EVERY ARM NAMES THE BINARY IT WAS MEASURED AGAINST, because this guard exists
# because that went unrecorded. All escape behaviour below was measured against
# /usr/bin/grep (GNU grep 3.12) on lenovinha 2026-09-04, NOT against the `grep`
# an interactive shell resolves — which on three of three Linux hosts is a ugrep
# compat function that interprets \t and would make half these arms pass for the
# wrong reason.
#
# PRE-FIX RESULT, stated as the fleet rule now requires: the guard PASSES on the
# committed corpus today (421 files, 0 violations). That is not evidence it
# works — it is the defect, and it is why arm 1 is the load-bearing one: the
# corpus contains no instance because the two that existed were fixed by
# 6fc5b7ac2 before this guard was written. An arm that has never gone red is a
# claim, so arm 1 runs the guard against the PRE-FIX file and requires refusal.
#
# The false-positive arms (2, 4, 5, 6) matter as much as the true-positive one.
# A guard that fires on working code gets switched off, and the first draft of
# this one reported 31 violations against a corpus with zero — sweeping up `\n`
# from awk programs on the same line, `-F` fixed-string patterns, and `-P` PCRE
# patterns where \x IS defined. Those three classes are the whole reason the
# extraction reads the grep PATTERN ARGUMENT and not the line.

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SUT="$REPO_ROOT/scripts/check-litmus-grep-escapes.sh"
FIXCOMMIT=6fc5b7ac2   # "fix(1011-d578)": the commit that replaced the two steps
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT

# ── arm 1: THE NEGATIVE CONTROL — the real pre-fix steps must be REFUSED ─────
# Not a synthetic pattern: the actual committed text that failed in the runner.
if git cat-file -e "${FIXCOMMIT}^:openspec/litmus-tests/litmus-capability-routing-shape.yaml" 2>/dev/null; then
    mkdir -p "$work/neg"
    git show "${FIXCOMMIT}^:openspec/litmus-tests/litmus-capability-routing-shape.yaml" > "$work/neg/x.yaml"
    if out="$(bash "$SUT" "$work/neg" 2>&1)"; then
        bad "arm1 pre-fix steps ACCEPTED — the guard has no teeth: $out"
    else
        case "$out" in
            *":55:"*|*":64:"*) ok "arm1 pre-fix steps refused, at the two real lines" ;;
            *) bad "arm1 refused but not at lines 55/64: $out" ;;
        esac
    fi
else
    echo "  skip: arm1 — $FIXCOMMIT not in this clone (shallow?)"
fi

# ── arm 2: THE POSITIVE CONTROL — the post-fix forms must be ACCEPTED ────────
# `case "$out" in` and `awk -F'\t'` are grep-independent: case matches a literal
# tab and awk expands \t itself, so neither depends on which grep is on PATH.
if git cat-file -e "${FIXCOMMIT}:openspec/litmus-tests/litmus-capability-routing-shape.yaml" 2>/dev/null; then
    mkdir -p "$work/pos"
    git show "${FIXCOMMIT}:openspec/litmus-tests/litmus-capability-routing-shape.yaml" > "$work/pos/x.yaml"
    bash "$SUT" "$work/pos" >/dev/null 2>&1 \
        && ok "arm2 post-fix forms accepted" \
        || bad "arm2 post-fix forms REFUSED — the guard rejects the fix"
fi

# ── arm 3: the committed corpus is clean, and that is the PRE-FIX result ─────
if out="$(bash "$SUT" 2>&1)"; then
    ok "arm3 committed corpus clean ($out) — stated as the guard's pre-fix result, not as evidence"
else
    bad "arm3 committed corpus now has violations: $out"
fi

# ── arm 4: the CORRECT idiom must not be refused ─────────────────────────────
# "$(printf '\t')" is how a real tab is passed; the backslash belongs to printf
# and grep never sees it. It appears twelve times in litmus-cycle-batch-triage-
# shape.yaml. Refusing it would refuse the remedy the guard recommends.
mkdir -p "$work/idiom"
printf 'steps:\n  - command: "out=$(x); printf %%s \\"$out\\" | grep -c \\"^packet$(printf \x27\\\\t\x27)\\""\n' \
    > "$work/idiom/x.yaml"
bash "$SUT" "$work/idiom" >/dev/null 2>&1 \
    && ok "arm4 \$(printf '\\t') idiom accepted" \
    || bad "arm4 the CORRECT idiom was refused"

# ── arm 5: -F interprets no regex, so no escape in it can be undefined ───────
mkdir -p "$work/fixed"
printf 'steps:\n  - command: "grep -qF \x27Servicing\\\\tRebootPending\x27 f.ps1"\n' > "$work/fixed/x.yaml"
bash "$SUT" "$work/fixed" >/dev/null 2>&1 \
    && ok "arm5 grep -F pattern accepted (fixed strings interpret no regex)" \
    || bad "arm5 a -F fixed-string pattern was refused"

# ── arm 6: -P is PCRE, where \t \d \s \w \xNN ARE defined ────────────────────
# Measured: `grep -qP 'a\tb'` matches a real tab and emits no stray warning.
# Two committed litmus files use `grep -P '[^\x00-\x7F]'` and must stay green.
mkdir -p "$work/pcre"
printf 'steps:\n  - command: "grep -qP \x27[^\\\\x00-\\\\x7F]\x27 scripts/install-windows.ps1"\n' > "$work/pcre/x.yaml"
bash "$SUT" "$work/pcre" >/dev/null 2>&1 \
    && ok "arm6 grep -P pattern accepted (PCRE defines these escapes)" \
    || bad "arm6 a -P PCRE pattern was refused"

# ── arm 7: \s and \w are GNU EXTENSIONS and must NOT be refused ──────────────
# The rule this packet was scoped with said "refuse \t \d \s \w". Measured
# against GNU grep 3.12: \s and \w are defined, emit no warning, and match
# correctly; ten committed lines across six files use them. Refusing them would
# have been a false-positive generator on working code.
mkdir -p "$work/gnuext"
printf 'steps:\n  - command: "grep -qE \x27^\\\\s+-\\\\s*name:\x27 .github/workflows/x.yml"\n' > "$work/gnuext/x.yaml"
bash "$SUT" "$work/gnuext" >/dev/null 2>&1 \
    && ok "arm7 \\s and \\w accepted (GNU extensions, measured defined)" \
    || bad "arm7 GNU extensions \\s/\\w were refused — 10 committed lines would go red"

# ── arm 8: a fresh \t violation IS caught (the guard keeps working) ──────────
mkdir -p "$work/fresh"
printf 'steps:\n  - command: "printf %%s \\"$out\\" | grep -qE \x27^hardware\\\\tloci=\x27"\n' > "$work/fresh/x.yaml"
bash "$SUT" "$work/fresh" >/dev/null 2>&1 \
    && bad "arm8 a fresh \\t violation was ACCEPTED" \
    || ok "arm8 a fresh \\t violation is refused"

printf 'litmus-grep-escapes: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { echo "fail:test-litmus-grep-escapes:$fail"; exit 1; }
echo "ok:test-litmus-grep-escapes:$pass"
