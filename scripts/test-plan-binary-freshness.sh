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

set_mtimes() { # $1 = binary stamp, $2 = source stamp (POSIX touch -t CCYYMMDDhhmm)
    # POSIX `touch -t`, never `-d` (851-28b5 defect class, caught by this
    # fixture's own gate run on the first macOS host): BSD touch's -d demands
    # strict ISO 'YYYY-MM-DDThh:mm:SS', so '2026-01-02 00:00' failed silently
    # under 2>/dev/null-free stderr, nothing was backdated, and both "stale"
    # scenarios ran against FRESH mtimes — rc=0 where the contract says 2.
    touch -t "$1" "$TMPD/target/release/tillandsias-plan"
    touch -t "$2" "$TMPD/crates/tillandsias-plan/src/main.rs" \
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
set_mtimes 202601020000 202601010000
out="$(run_case none)"
ck "fresh binary resolves"            "rc=0" "$(printf '%s' "$out" | tail -1)"
ck "fresh binary prints its path"     "./target/release/tillandsias-plan" \
   "$(printf '%s' "$out" | head -1)"

# ── case B: source newer, rebuild fails → rc 2, silent ──────────────────────
set_mtimes 202601020000 202601030000
out="$(run_case fail)"
ck "stale + failed rebuild returns 2" "rc=2" "$(printf '%s' "$out" | tail -1)"
ck "stale + failed rebuild is silent" ""     "$(printf '%s' "$out" | head -1)"

# ── case C: source newer, rebuild heals → rc 0, path printed ────────────────
set_mtimes 202601020000 202601030000
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
set_mtimes 202601020000 202601030000   # stale by mtime, on purpose
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

# ── ORDER 1129-4su6: THE PRE-PUSH LANE MUST REFUSE A STALE VALIDATOR ────────
#
# The cases above pin plan_binary_is_stale and ensure_fresh_plan_binary as
# FUNCTIONS. This arm pins the CONSUMER that never called either: the pre-push
# plan-only lane resolved a binary and validated pushed ledger bytes with it,
# however old it was, while six other consumers called ensure_fresh.
#
# MEASURED on esmeraldinha 2026-09-12: an eight-day-old ELF that RUNS, winning
# the probe's candidate order over a .exe rebuilt the previous day, would have
# been the lane's fold validator — adjudicating a status-loss rule that had
# changed that same night (ac0ea1089).
#
# REFUSE, NOT REFRESH: a git hook that silently starts a cargo build is a
# surprise on a floor host. Both arms below therefore assert a REFUSAL and its
# named cause, never a rebuild.
# `touch -t YYYYMMDDhhmm` throughout, never `touch -d`: -d is GNU-only and a
# BSD touch (macOS) rejects it, which would fail these arms for a reason that
# has nothing to do with staleness. Seventh regime gap of the night.
_LANE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LW="$(mktemp -d "${TMPDIR:-/tmp}/lane-stale.XXXXXX")"
trap 'rm -rf "$TMPD" "$LW"' EXIT
LG() { git -C "$LW/wc" -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare "$LW/bare.git"
git init -q -b linux-next "$LW/wc"
( cd "$LW/wc" && git remote add origin "$LW/bare.git" && git config core.hooksPath .git/hooks )
mkdir -p "$LW/wc/scripts/hooks" "$LW/wc/plan/index.d" "$LW/wc/crates/tillandsias-plan/src" "$LW/wc/target/release"
cp "$_LANE_ROOT/scripts/hooks/pre-push-local-gate.sh" "$LW/wc/scripts/hooks/"
for f in plan-binary-probe.sh gate-stamp.sh common.sh check-fragment-status-loss.sh check-issue-citation-convention.sh; do
    cp "$_LANE_ROOT/scripts/$f" "$LW/wc/scripts/" 2>/dev/null || true
done
chmod +x "$LW/wc/scripts"/*.sh "$LW/wc/scripts/hooks"/*.sh 2>/dev/null
printf 'packets: []\n' > "$LW/wc/plan/index.yaml"
echo 'fn main() {}' > "$LW/wc/crates/tillandsias-plan/src/main.rs"
echo '# lock' > "$LW/wc/Cargo.lock"
cat > "$LW/wc/target/release/tillandsias-plan" <<'LSTUB'
#!/usr/bin/env bash
case "${1:-}" in
    capabilities) echo compact; exit 0 ;;
    check) exit 0 ;;
    validate-yaml) exit 0 ;;
    yaml-type) echo '!!map'; exit 0 ;;
esac
exit 0
LSTUB
chmod +x "$LW/wc/target/release/tillandsias-plan"
LG add -A >/dev/null 2>&1; LG commit -q -m base
( cd "$LW/wc" && git push -q -u origin linux-next 2>/dev/null )

_lane_push() { ( cd "$LW/wc" && env -u TILLANDSIAS_PLAN_BIN -u CARGO_TARGET_DIR \
    bash scripts/hooks/pre-push-local-gate.sh origin "$LW/bare.git" 2>&1 <<< \
    "refs/heads/linux-next $(git -C "$LW/wc" rev-parse HEAD) refs/heads/linux-next $(git -C "$LW/wc" rev-parse origin/linux-next)" ); }

printf 'packets: []\n' > "$LW/wc/plan/index.d/20260912t000000z-stale-arm.yaml"
LG add -A >/dev/null 2>&1; LG commit -q -m "a fragment push"

# CASE: sources NEWER than the binary -> the validator is stale -> REFUSE.
touch -t 202609041215 "$LW/wc/target/release/tillandsias-plan"
touch -t 202609111933 "$LW/wc/crates/tillandsias-plan/src/main.rs"
_out="$(_lane_push)"; _rc=$?
ck "lane REFUSES a fragment push validated by a stale binary" 1 "$_rc"
case "$_out" in
    *"is STALE"*) ck "the refusal names STALENESS as the cause" yes yes ;;
    *)            ck "the refusal names STALENESS as the cause" yes no ;;
esac
case "$_out" in
    *"cargo build --release -p tillandsias-plan"*) ck "the refusal carries a remedy the operator can type" yes yes ;;
    *)                                             ck "the refusal carries a remedy the operator can type" yes no ;;
esac
# esme asked for the "newer:" line specifically — it answers "stale relative to
# what" without a second command. Asserted because the way it is COMPUTED
# changed: `find -printf` is GNU-only and would have gone silently empty on a
# BSD find, dropping this line on macOS only.
# Either source may be the newest — Cargo.lock is written last in this fixture,
# so it usually wins. Assert the LINE and that it names a real source, not which
# one: pinning a particular file would make this arm fail on a setup change that
# is not a defect, and the claim being tested is "it says stale relative to
# what", not "it says main.rs".
case "$_out" in
    *"newer:"*Cargo.lock*|*"newer:"*main.rs*)
        ck "the refusal names the newer file that makes it stale" yes yes ;;
    *)  ck "the refusal names the newer file that makes it stale" yes no ;;
esac
# NOT a rebuild: a hook must not start one. The stub cargo would leave a marker.
case "$_out" in
    *"Compiling"*|*"Finished"*) ck "the lane did NOT rebuild inside the hook" yes no ;;
    *)                          ck "the lane did NOT rebuild inside the hook" yes yes ;;
esac

# ── esme's CONFIGURATION: DERIVATION UNIT-CHECKED HERE, END-TO-END ON THEIRS ─
#
# WHAT THIS HOST CAN AND CANNOT PROVE, stated rather than implied, because an
# arm that claims more than it tests is the defect this whole packet chain is
# about.
#
# esme's case is: CARGO_TARGET_DIR UNSET at push time (it is exported only for
# the duration of a wrapped build), a STALE ./target/release/tillandsias-plan
# that the probe therefore resolves, and a FRESH copy under the redirect the
# probe cannot see. The refusal finds that copy by deriving the redirect from
# scripts/with-wsl2-builder.sh's own declaration (:276).
#
# That path is /root/.cache/tillandsias-wsl2-target/<repo>, which this host
# cannot write. And the obvious substitute does not reproduce it: setting
# CARGO_TARGET_DIR to a writable directory makes the PROBE resolve the fresh
# copy first, so nothing is stale and there is correctly no refusal at all.
# The gap between "probe cannot see it" and "refusal can" is exactly what makes
# the case awkward, and it is not constructible without the redirect.
#
# So: unit-check the DERIVATION here, and esme verifies the end-to-end line on
# the only host in the fleet that has the configuration.
_decl_raw="$(sed -n 's|.*export CARGO_TARGET_DIR=\\"\([^"]*\)\\".*|\1|p' "$_LANE_ROOT/scripts/with-wsl2-builder.sh" 2>/dev/null | head -1)"
case "$_decl_raw" in
    */'$REPO_BASENAME') ck "the wsl2 redirect declaration is still readable and still ends in \$REPO_BASENAME" yes yes ;;
    '')                 ck "the wsl2 redirect declaration is still readable and still ends in \$REPO_BASENAME" yes no ;;
    *)                  ck "the wsl2 redirect declaration is still readable and still ends in \$REPO_BASENAME" yes no ;;
esac
# If that declaration ever moves, the hook finds nothing and falls back to the
# rebuild remedy — degraded, never wrong — and this arm is what notices.

# NEGATIVE CONTROL: binary NEWER than its sources -> not stale -> lane proceeds.
# Without this, a fix that refused every push would pass the arm above and
# destroy the lane, whose reason to exist is speed (930-i6x4).
touch -t 202609120600 "$LW/wc/target/release/tillandsias-plan"
_out2="$(_lane_push)"; _rc2=$?
case "$_out2" in
    *"is STALE"*) ck "CONTROL: a CURRENT binary is not refused as stale" yes no ;;
    *)            ck "CONTROL: a CURRENT binary is not refused as stale" yes yes ;;
esac

printf 'plan-binary-freshness: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
    echo "ok:plan-binary-freshness:$pass"
    exit 0
fi
exit 1
