#!/usr/bin/env bash
# @trace order:1254-fdsu
#
# test-awk-float-lc-numeric.sh — the measurement producers must emit a DOT
# decimal separator even when the host's numeric locale uses a comma.
#
# WHY THIS EXISTS. awk's "%.2f" honours LC_NUMERIC: on a comma-decimal host it
# prints 100,00, and every consumer in this tree parses with a [0-9.] class, so
# the comma TRUNCATES the number instead of failing to match (100,00 reads as
# 100). Every CI lane runs LC_NUMERIC=C or en_US, where the defect cannot show,
# so merely RUNNING the producers proves nothing. This fixture INJECTS a comma
# locale around each producer and asserts ^[0-9]+\.[0-9]+$ on its fields.
#
# INJECTION. BSD/one-true awk (macOS) honours LC_NUMERIC on output always. GNU
# awk honours it only with --use-lc-numeric (or in POSIX mode), so on a GNU awk
# host an `awk` shim that adds the flag is put first on PATH to reproduce the
# macOS behaviour on a Linux lane. NEVER export POSIXLY_CORRECT to reach gawk:
# bash reads it too, and bash 3.2 in POSIX mode rejects `done < <(...)` as a
# syntax error (freshness-inventory.sh:182), so on darwin every arm went red
# from the HARNESS while the fix itself was correct (macbookair, 2026-09-26). The locale is chosen
# by MEASUREMENT (it must actually make awk print 1,00), never by name: a glibc
# host without fr_CH/de_DE generated usually still ships en_DK, which is comma.
#
# MUTATION ARM, per producer. Each producer is copied beside itself with its
# LC_ALL=C pins stripped and run the same way; its assertion MUST go red. A
# guard whose mutant passes only proved some number somewhere had a dot in it.
#
# scripts/hooks/pre-commit-openspec.sh is the fourth script 1254-fdsu named; it
# was pinned in 21c578622 and its awk output is a stderr warning, not a field a
# consumer parses, so it is checked here only statically (pin present).

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
DOT='^[0-9]+\.[0-9]+$'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/awklc.XXXXXX")"
SHIM_PATH="$PATH"
if awk --version 2>/dev/null | head -1 | grep -q 'GNU Awk'; then
    mkdir -p "$TMP/awkshim"
    real_awk="$(command -v awk)"
    printf '#!/bin/sh\nexec "%s" --use-lc-numeric "$@"\n' "$real_awk" >"$TMP/awkshim/awk"
    chmod +x "$TMP/awkshim/awk"
    SHIM_PATH="$TMP/awkshim:$PATH"
fi

# ── find a comma locale by measurement ─────────────────────────────────────────
COMMA=""
for l in fr_CH.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 en_DK.UTF-8 en_DK.utf8 de_DE.utf8 \
         $(locale -a 2>/dev/null | grep -iE '^(de|fr|es|it|nl|pt|da|sv|en_DK)' || true); do
    if [ "$(PATH="$SHIM_PATH" LC_ALL="$l" awk 'BEGIN{printf "%.2f", 1}' 2>/dev/null)" = "1,00" ]; then
        COMMA="$l"; break
    fi
done
if [ -z "$COMMA" ]; then
    # Loud, not green: the host cannot score this, and saying ok would be a lie.
    echo "unscoreable:awk-float-lc-numeric:no-comma-locale-on-host"
    exit 0
fi
echo "# injected comma locale: $COMMA (awk prints 1,00 under it)"
inject() { PATH="$SHIM_PATH" LC_ALL="$COMMA" "$@"; }

MUTANTS=()
cleanup() { rm -rf "$TMP"; for m in ${MUTANTS[@]+"${MUTANTS[@]}"}; do rm -f "$m"; done; }
trap cleanup EXIT

# make_mutant <script> — copy beside the original (so its relative sourcing
# still resolves) with every LC_ALL=C pin removed. Runs in THIS shell so the
# trap knows the copy; mpath prints where it went.
mpath() { printf '%s/.mutant-lcnum-%s\n' "$(dirname "$1")" "$(basename "$1")"; }
make_mutant() {
    local dst; dst="$(mpath "$1")"
    MUTANTS+=("$dst")
    sed 's/LC_ALL=C //g' "$1" >"$dst"; chmod +x "$dst"
    cmp -s "$1" "$dst" && bad "$1 carries no LC_ALL=C pin to strip"
    return 0
}
for s in scripts/freshness-inventory.sh scripts/refusal-calibration/measure-bands.sh scripts/select-work-batch.sh; do
    make_mutant "$s"
done

# every_dot <label> <values...> — all values match the dot grammar (and exist).
every_dot() {
    local label="$1"; shift
    [ $# -gt 0 ] || { echo "none"; return 1; }
    local v
    for v in "$@"; do [[ "$v" =~ $DOT ]] || { echo "$v"; return 1; }; done
    return 0
}

# ── 1. freshness-inventory.sh: freshness-coverage: X% ──────────────────────────
FX="$TMP/fresh"; mkdir -p "$FX"
printf '# freshness: auditor=t date=%s verdict=refreshed scope=x\n' "$(date -u +%Y-%m-%d)" >"$FX/a.sh"
printf '#!/bin/sh\n' >"$FX/b.sh"; printf '#!/bin/sh\n' >"$FX/c.sh"
fresh_pct() { FRESHNESS_FIXTURE_DIR="$FX" inject bash "$1" 2>/dev/null \
    | sed -n 's/^freshness-coverage: \([^%]*\)%.*/\1/p'; }
v="$(fresh_pct scripts/freshness-inventory.sh)"
if bad_v="$(every_dot fresh $v)"; then ok "freshness-inventory coverage=$v under $COMMA"
else bad "freshness-inventory emitted '${bad_v}' under $COMMA (want dot decimal)"; fi
v="$(fresh_pct "$(mpath scripts/freshness-inventory.sh)")"
if every_dot fresh $v >/dev/null; then bad "mutation arm vacuous: unpinned freshness-inventory still emitted '$v'"
else ok "mutation arm: unpinned freshness-inventory emits '$v' (red as it must be)"; fi

# ── 2. refusal-calibration/measure-bands.sh: margin column ─────────────────────
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
printf '{"data":[{"embedding":[0.1,0.2]}]}'
EOF
cat >"$TMP/plan-stub" <<'EOF'
#!/bin/sh
printf '[{"score":0.8312,"kind":"spec","path":"a"},{"score":0.7001,"kind":"spec","path":"b"}]'
EOF
chmod +x "$TMP/bin/curl" "$TMP/plan-stub"
mkdir -p "$TMP/idx"
printf '{"band":"answer","corpus":"spec","q":"what is x"}\n' >"$TMP/q.jsonl"
bands_margin() { SHIM_PATH="$TMP/bin:$SHIM_PATH" TILLANDSIAS_PLAN_BIN="$TMP/plan-stub" inject bash "$1" \
    --model m --index-dir "$TMP/idx" --questions "$TMP/q.jsonl" 2>/dev/null | awk -F'\t' 'NR==2{print $5}'; }
v="$(bands_margin scripts/refusal-calibration/measure-bands.sh)"
if bad_v="$(every_dot bands $v)"; then ok "measure-bands margin=$v under $COMMA"
else bad "measure-bands emitted margin '${bad_v}' under $COMMA (want dot decimal)"; fi
v="$(bands_margin "$(mpath scripts/refusal-calibration/measure-bands.sh)")"
if every_dot bands $v >/dev/null; then bad "mutation arm vacuous: unpinned measure-bands still emitted '$v'"
else ok "mutation arm: unpinned measure-bands emits '$v' (red as it must be)"; fi

# ── 3. select-work-batch.sh: frontier score, neglect=, p= ───────────────────────
# Runs against the real folded ledger (read-only). A refusal is a FAIL, not a
# skip: without frontier lines there is nothing to assert.
frontier_raw() { inject bash "$1" linux 2>/dev/null; }
frontier_vals() { printf '%s\n' "$1" | awk -F'\t' '/^frontier\t/{
    print $2; n=$6; sub(/^neglect=/,"",n); print n; p=$7; sub(/^p=/,"",p); print p }'; }
raw="$(frontier_raw scripts/select-work-batch.sh)"
if printf '%s\n' "$raw" | grep -q '^refused:no-plan-binary'; then
    # A precondition, not a verdict: no runnable plan binary means no frontier
    # to measure. Named skip, so the arm is visibly not scored.
    echo "  skip: select-work-batch arms — $(printf '%s\n' "$raw" | grep -m1 '^refused:no-plan-binary')"
else
    v="$(frontier_vals "$raw")"
    if bad_v="$(every_dot select $v)"; then ok "select-work-batch frontier fields all dot-decimal ($(printf '%s\n' $v | wc -l | tr -d ' ') values) under $COMMA"
    else bad "select-work-batch emitted '${bad_v}' under $COMMA (want dot decimal)"; fi
    v="$(frontier_vals "$(frontier_raw "$(mpath scripts/select-work-batch.sh)")")"
    if every_dot select $v >/dev/null; then bad "mutation arm vacuous: unpinned select-work-batch still all-dot"
    else ok "mutation arm: unpinned select-work-batch emits '$(printf '%s\n' $v | head -1)' (red as it must be)"; fi
fi

# ── 4. pre-commit-openspec.sh: static — every %.Nf awk carries the pin ──────────
unpinned="$(grep -nE 'awk .*%\.[0-9]f' scripts/hooks/pre-commit-openspec.sh | grep -v 'LC_ALL=C awk' || true)"
if [ -z "$unpinned" ]; then ok "pre-commit-openspec: every %.Nf awk is LC_ALL=C-pinned (static)"
else bad "pre-commit-openspec has an unpinned %.Nf awk: $unpinned"; fi

if [ "$fail" -eq 0 ]; then echo "ok:awk-float-lc-numeric:$pass"; exit 0; fi
echo "fail:awk-float-lc-numeric:$fail failed, $pass passed"; exit 1
