#!/usr/bin/env bash
# Fixture for order 851-cduu: point-of-use instrument freshness.
#
# WHY THIS EXISTS. resolve_plan_binary proves the artifact RUNS, not that it
# matches the checkout. Two same-day field breaches (2026-08-23) rode that
# gap: yolanda's gate consulted a 6-day-stale binary in a CARGO_TARGET_DIR
# preflight never rebuilds, and macuahuitl's check-resumable-claim-dirt.sh sat
# inert for 11 hours behind a binary built before sibling work was pulled
# mid-cycle. A stale instrument does not fail; it answers wrong. This fixture
# pins ensure_fresh_plan_binary's contract so the distinction cannot regress:
#   rc 0 + path — current (or rebuilt-in-locus) binary
#   rc 1 silent — no runnable binary at all
#   rc 2 silent — stale and NOT refreshable here (callers must refuse loudly)
#   override    — TILLANDSIAS_PLAN_BIN passes through on existence alone
#
# HERMETIC: fake crate tree, stub binary and stub cargo under mktemp; mtimes
# are set explicitly (the vintage test is cargo's own model, mtimes — commit
# timestamps are stamped on the ORIGIN host and would call a pre-merge binary
# fresh). Never touches the real target/ or ledger.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ck() { # ck <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/plan-binary-freshness.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

# A fake checkout: the instrument's vintage source set, a runnable stub
# "binary" (answers `capabilities` with exit 0, which is all resolve probes),
# and a bin dir whose `cargo` each case controls.
mkdir -p "$TMPD/crates/tillandsias-plan/src" "$TMPD/target/release" "$TMPD/bin"
echo 'fn main() {}' > "$TMPD/crates/tillandsias-plan/src/main.rs"
echo '# lock' > "$TMPD/Cargo.lock"
cat > "$TMPD/target/release/tillandsias-plan" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "capabilities" ] && { echo compact; exit 0; }
exit 0
STUB
chmod +x "$TMPD/target/release/tillandsias-plan"

set_mtimes() { # $1 = binary date, $2 = source date
    touch -d "$1" "$TMPD/target/release/tillandsias-plan"
    touch -d "$2" "$TMPD/crates/tillandsias-plan/src/main.rs" \
                  "$TMPD/crates/tillandsias-plan" "$TMPD/Cargo.lock"
}

# run_case <cargo-mode: none|fail|touch> → stdout is the function's stdout,
# a trailing "rc=<n>" line carries its return code. Env is scrubbed of the
# real CARGO_TARGET_DIR / TILLANDSIAS_PLAN_BIN so the fixture cannot resolve
# the checkout's actual instrument.
run_case() {
    local mode="$1"
    case "$mode" in
        none)  rm -f "$TMPD/bin/cargo" ;;
        fail)  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMPD/bin/cargo"
               chmod +x "$TMPD/bin/cargo" ;;
        touch) printf '#!/usr/bin/env bash\ntouch target/release/tillandsias-plan\nexit 0\n' > "$TMPD/bin/cargo"
               chmod +x "$TMPD/bin/cargo" ;;
    esac
    # SHADOW ANY PATH-INSTALLED tillandsias-plan. resolve_plan_binary's LAST
    # candidate is `command -v tillandsias-plan`, so on a host that has one
    # installed (macuahuitl keeps one at ~/.local/bin) case D's premise — "no
    # binary at all" — is false: the resolver finds the installed copy, returns
    # 0, and the case fails with rc=0 where it expects rc=1. It passed on the
    # host that wrote it because that host has no installed copy.
    #
    # A stub that FAILS its `capabilities` probe is the shadow; deleting
    # something from $TMPD/bin cannot hide a binary that lives elsewhere on
    # PATH. The relative ./target candidates are checked BEFORE the PATH
    # fallback, so the cases that expect a real local binary are unaffected.
    printf '#!/usr/bin/env bash\nexit 127\n' >"$TMPD/bin/tillandsias-plan"
    chmod +x "$TMPD/bin/tillandsias-plan"
    (
        cd "$TMPD" || exit 99
        unset CARGO_TARGET_DIR TILLANDSIAS_PLAN_BIN
        PATH="$TMPD/bin:$PATH"
        . "$ROOT/scripts/plan-binary-probe.sh"
        out="$(ensure_fresh_plan_binary)"; rc=$?
        printf '%s\nrc=%d\n' "$out" "$rc"
    )
}

# ── case A: binary newer than every source → fresh, no cargo consulted ──────
set_mtimes '2026-01-02 00:00' '2026-01-01 00:00'
out="$(run_case none)"
ck "fresh binary resolves"            "rc=0" "$(printf '%s' "$out" | tail -1)"
ck "fresh binary prints its path"     "./target/release/tillandsias-plan" \
   "$(printf '%s' "$out" | head -1)"

# ── case B: source newer, rebuild fails → rc 2, silent ──────────────────────
set_mtimes '2026-01-02 00:00' '2026-01-03 00:00'
out="$(run_case fail)"
ck "stale + failed rebuild returns 2" "rc=2" "$(printf '%s' "$out" | tail -1)"
ck "stale + failed rebuild is silent" ""     "$(printf '%s' "$out" | head -1)"

# ── case C: source newer, rebuild heals → rc 0, path printed ────────────────
set_mtimes '2026-01-02 00:00' '2026-01-03 00:00'
out="$(run_case touch)"
ck "stale + rebuild-in-locus heals"   "rc=0" "$(printf '%s' "$out" | tail -1)"
ck "healed binary prints its path"    "./target/release/tillandsias-plan" \
   "$(printf '%s' "$out" | head -1)"

# ── case D: no binary at all, rebuild fails → rc 1 (resolve contract) ───────
mv "$TMPD/target/release/tillandsias-plan" "$TMPD/stashed-binary"
out="$(run_case fail)"
ck "no binary returns 1"              "rc=1" "$(printf '%s' "$out" | tail -1)"
mv "$TMPD/stashed-binary" "$TMPD/target/release/tillandsias-plan"

# ── case E: explicit override passes through on existence alone ─────────────
set_mtimes '2026-01-02 00:00' '2026-01-03 00:00'   # stale by mtime, on purpose
out="$(
    cd "$TMPD" || exit 99
    unset CARGO_TARGET_DIR
    export TILLANDSIAS_PLAN_BIN="$TMPD/target/release/tillandsias-plan"
    . "$ROOT/scripts/plan-binary-probe.sh"
    o="$(ensure_fresh_plan_binary)"; rc=$?
    printf '%s\nrc=%d\n' "$o" "$rc"
)"
ck "override honoured despite staleness" "rc=0" "$(printf '%s' "$out" | tail -1)"
ck "override path passes through" "$TMPD/target/release/tillandsias-plan" \
   "$(printf '%s' "$out" | head -1)"

printf 'plan-binary-freshness: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
    echo "ok:plan-binary-freshness:$pass"
    exit 0
fi
exit 1
