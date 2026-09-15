#!/usr/bin/env bash
# test-a-claim-names-a-workstation.sh — 1201-hsf9: a claim written without an
# explicit --host would record its holder as the COMPILED PLATFORM, so every
# host on one platform claims under the same name. set-field refuses it.
#
# WHY THIS EXISTS. MEASURED on the live ledger 2026-09-15: yoga's claim on
# 888-miiy landed as plan/index.d/20260915t073636z-35bca30d-linux.yaml because
# set-field was called without --host, and this coordinator then asked the
# wrong host to release it. Fixing the expiry sweep's channel (1198-7q95) did
# not close that: 1155-jurn still reads `claimant:windows`, and esme and
# yolanda are both windows, so the same wrong message is constructible one
# layer down. The claim is the one write whose purpose is to say WHOM TO ASK.
#
# ROUTE (a) of the three the row records. The 772-4se9 platform default is
# untouched — its unit test pins writer_host_from(None) == std::env::consts::OS
# exactly, and route (b) would have broken it — so the refusal is narrow: it
# fires only on `status in_progress` and only when the host WOULD be the
# platform. An explicit --host always wins, including --host <platform>.
#
# Hermetic: scratch ledgers under target/plan-scratch driven through --index.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

_validator="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _validator=""
case "$_validator" in ./*) _validator="$ROOT/${_validator#./}" ;; esac
if [ -z "$_validator" ]; then
    echo "skip:a-claim-names-a-workstation:no-validator — no runnable tillandsias-plan on this host; build one: cargo build --release -p tillandsias-plan"
    echo "a-claim-names-a-workstation: 0 passed, 0 failed (skipped)"
    exit 0
fi
PLAN="$_validator"
export TILLANDSIAS_PLAN_BIN="$PLAN"

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/claim-names-host.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# The platform this binary was compiled for is the string the refusal is about.
# Derived, never hardcoded: a fixture that pins "linux" is green here and red
# on every other host in the fleet, which is the shape this row is fixing.
PLATFORM="$(uname -s | tr 'A-Z' 'a-z')"
case "$PLATFORM" in darwin) PLATFORM=macos ;; mingw*|msys*|cygwin*) PLATFORM=windows ;; esac

mk() { # mk <dir>
    local d="$1"; mkdir -p "$d/plan/index.d"
    cat > "$d/plan/index.yaml" <<EOF
packets:
  - packet_id: a-fixture-row
    order: 1-aaaa
    status: ready
    kind: bug
    priority: p2
    desired_release: v0.5
    pickup_role: linux
    title: a row to claim
    unscoreable: "fixture packet; not scored"
    events: []
EOF
}

# Capture, never `if ! <pipeline>` (795-imz3): every arm below tests a captured
# exit status and captured text, so pipefail + SIGPIPE cannot invert a verdict.
run() { # run <dir> <args...> -> sets OUT, RC
    local d="$1"; shift
    OUT="$("$PLAN" --index "$d/plan/index.yaml" set-field "$@" 2>&1)"; RC=$?
}
frags() { find "$1/plan/index.d" -name '*.yaml' 2>/dev/null | wc -l | tr -d ' '; }

# ── ARM 1: the measured case — a claim with no --host is REFUSED ───────────
D="$W/a"; mk "$D"
run "$D" 1-aaaa status in_progress --reason "claimed with no host"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'refused:set-field:claim-without-a-host'; then
    ok "ARM 1: a claim with no --host is refused, with the typed verdict (rc=$RC)"
else
    bad "ARM 1: rc=$RC, output: $(printf '%s' "$OUT" | head -1 | cut -c1-90)"
fi

# ── ARM 2: THE REFUSAL WROTE NOTHING. A refusal that still leaves a fragment
# behind is worse than no refusal — the bad claim lands and the caller thinks
# it did not. This is the arm that distinguishes "refused" from "complained".
if [ "$(frags "$D")" = "0" ]; then
    ok "ARM 2: the refusal wrote NO fragment — it refused rather than complained"
else
    bad "ARM 2: the refusal left $(frags "$D") fragment(s) behind"
fi

# ── ARM 3: NEGATIVE CONTROL — an explicit --host still wins ───────────────
D2="$W/b"; mk "$D2"
run "$D2" 1-aaaa status in_progress --host macuahuitl --reason "claimed with a host"
if [ "$RC" -eq 0 ] && [ "$(frags "$D2")" = "1" ]; then
    ok "ARM 3 (negative control): an explicit --host is accepted and writes its fragment"
else
    bad "ARM 3: rc=$RC, fragments=$(frags "$D2") — the refusal must not catch a well-formed claim"
fi

# ── ARM 4: NEGATIVE CONTROL — an explicit --host <platform> still wins ────
# The row's own criterion: explicit beats any default, INCLUDING when what you
# explicitly mean is the platform. Without this arm the guard could be
# implemented as "refuse the platform string", which would be a different and
# wrong rule — it would refuse a deliberate, informed write.
D3="$W/c"; mk "$D3"
run "$D3" 1-aaaa status in_progress --host "$PLATFORM" --reason "I really do mean the platform"
if [ "$RC" -eq 0 ] && [ "$(frags "$D3")" = "1" ]; then
    ok "ARM 4 (negative control): --host $PLATFORM explicitly is ACCEPTED — the rule is about the default, not about the string"
else
    bad "ARM 4: rc=$RC, fragments=$(frags "$D3") — explicit must beat the default even when it names the platform"
fi

# ── ARM 5: NEGATIVE CONTROL — every OTHER write is untouched ──────────────
# The refusal is scoped to a claim. A closure, a release, and a non-status
# field must all still default their host exactly as 772-4se9 specifies,
# because that default is a correct fact about which PLATFORM wrote the row.
# EACH WRITE GETS A FRESH LEDGER. The first draft ran all three against one
# row, and the second failed for a reason that has nothing to do with this
# guard: `ready` after `completed` moves DOWN the closure ladder and a separate
# rule refuses it. A control that fails for an unrelated reason accuses the
# treatment — the arm reported "1 of 3 unrelated writes was caught by the claim
# refusal" when the claim refusal had not fired at all.
_other=0; _why=""
for _case in "status|completed|--evidence|fixture-evidence" "status|ready|--reason|released-with-no-host" "priority|p1|--reason|a-non-status-field"; do
    IFS='|' read -r _f _v _flag _arg <<< "$_case"
    _d="$W/d-$_f-$_v"; mk "$_d"
    run "$_d" 1-aaaa "$_f" "$_v" "$_flag" "$_arg"
    if [ "$RC" -ne 0 ]; then
        _other=$((_other+1))
        _why="$_why [$_f $_v -> rc=$RC: $(printf '%s' "$OUT" | head -1 | cut -c1-60)]"
    fi
done
if [ "$_other" -eq 0 ]; then
    ok "ARM 5 (negative control): completed, ready and a non-status field all still default their host — the refusal is scoped to the claim"
else
    bad "ARM 5: $_other of 3 unrelated writes were refused:$_why"
fi

# ── ARM 6: the 772-4se9 guarantee is untouched, checked by EXECUTION ──────
# The row requires that unit test to pass UNCHANGED. Asserting that here by
# grepping the source would be a structural check wearing a control's clothes;
# run it instead, and say plainly when the toolchain is absent rather than
# scoring a skip as a pass.
if command -v cargo >/dev/null 2>&1; then
    # CAPTURE, THEN MATCH ON A HERE-STRING. `cargo test … | grep -q` is an
    # unbounded producer feeding an early-exiting consumer under pipefail, so a
    # MATCH can surface as a failure (792-ksr8) — the sibling of the 795-imz3
    # shape, and the same author wrote both in one day. The here-string producer
    # is bounded, which is the remedy the guard itself names.
    _ut_out="$(cd "$ROOT" && cargo test --release -p tillandsias-plan writer_host_default_is_the_compiled_platform 2>&1)"
    _ut_rc=$?
    if [ "$_ut_rc" -eq 0 ] && grep -q '1 passed' <<<"$_ut_out"; then
        ok "ARM 6: 772-4se9's writer_host_default unit test still passes, EXECUTED not grepped (rc=$_ut_rc)"
    else
        bad "ARM 6: 772-4se9's unit test did not pass (rc=$_ut_rc): $(printf '%s' "$_ut_out" | grep -E 'FAILED|panicked|error' | head -1 | cut -c1-80)"
    fi
else
    echo "skip: ARM 6 — no cargo on this host; the 772-4se9 unit test is owed a run elsewhere"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "ok:a-claim-names-a-workstation"
    echo "PASS: a-claim-names-a-workstation $pass/$total (1201-hsf9)"
    exit 0
fi
echo "FAIL: a-claim-names-a-workstation $pass/$total (1201-hsf9)"
exit 1
