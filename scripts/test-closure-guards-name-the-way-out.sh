#!/usr/bin/env bash
# ORDER 1136-n8sh. A packet whose DELIVERABLE IS A NEW TEST is refused from both
# sides, and each refusal must name the other and the sanctioned exit.
#
# THE BIND IS INTENDED, and the coordinator ruled it so: a declared pin must
# resolve, and a packet whose deliverable IS the test cannot resolve it yet.
# What was missing was only that the two refusals never said so.
#
#   Guard 1 — scripts/check-scorable-obligation-added.sh (977-448j) refuses a
#             row carrying no scorable obligation.
#   Guard 2 — `tillandsias-plan declared-closures-check` (885-92iu), Rust in
#             crates/tillandsias-plan, refuses a row pinning a litmus nothing
#             defines. NOT the shell wrapper check-declared-closures-added.sh,
#             which only counts and relays — so this half is a rebuild, not a
#             script edit.
#
# A filer who read only guard 2 would delete the pin and land straight back in
# guard 1; one who read only guard 1 would declare the pin and let it dangle,
# which is 1068-cxmf's standing defect, already several instances deep. The
# sanctioned exit is `unscoreable: unpinnable-until-the-guard-exists`.
#
# REGIME. Both arms EXECUTE the real guards against a probe packet and grep the
# refusal each actually prints. Neither arm reads the guards' source, so a
# message deleted from the code cannot pass by still being quoted in a comment.
# Guard 1 reads the git index, so it runs inside a throwaway detached worktree:
# the fixture never stages anything in the caller's index. The probe fragment's
# filename is derived from the clock AT RUN TIME and is deleted with the
# worktree; no arm asserts, or depends on, any absolute moment.
#
# This fixture is also what discharges 1136-n8sh's own `unscoreable` state, in
# exactly the form that row prescribed: two greps, one fixture.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

pass=0
fail=0
ok()  { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

EXIT_FORM="unpinnable-until-the-guard-exists"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/closure-guards.XXXXXX")"
wt="$tmp/wt"
cleanup() {
    [ -d "$wt" ] && git -C "$ROOT" worktree remove --force "$wt" >/dev/null 2>&1
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

# ── ARM 1 — GUARD 1 names the exit AND guard 2.
if ! git worktree add --detach -q "$wt" HEAD 2>"$tmp/wterr"; then
    bad "could not create a throwaway worktree, so guard 1 could not be driven: $(head -1 "$tmp/wterr")"
else
    frag="plan/index.d/$(date -u +%Y%m%dt%H%M%Sz)-9999-zzzz-closure-guard-probe.yaml"
    mkdir -p "$wt/plan/index.d"
    # A probe row with NO obligation of any kind — the shape guard 1 exists to
    # refuse, and the shape a new-test packet starts out in.
    cat > "$wt/$frag" <<'PROBE'
packets:
  - packet_id: probe-a-packet-whose-deliverable-is-a-new-test
    order: 9999-zzzz
    status: ready
    title: probe row for the 1136-n8sh fixture — carries no obligation on purpose
PROBE
    git -C "$wt" add "$frag" >/dev/null 2>&1
    g1="$(cd "$wt" && bash scripts/check-scorable-obligation-added.sh 2>&1)"

    if printf '%s' "$g1" | grep -q "$EXIT_FORM"; then
        ok "guard 1 names the sanctioned exit '$EXIT_FORM'"
    else
        bad "guard 1 refuses a new-test packet without naming '$EXIT_FORM' — the filer's next move is unguided"
    fi
    if printf '%s' "$g1" | grep -q '885-92iu'; then
        ok "guard 1 names its counterpart (885-92iu), so the filer learns pinning a future name will also be refused"
    else
        bad "guard 1 does not name guard 2 — a filer who pins the future litmus walks into the second refusal blind"
    fi
fi

# ── ARM 2 — GUARD 2 names the exit AND guard 1. This is the Rust half; it reads
#           a fragment path directly, so no worktree is needed.
# THE SHARED PROBE, not a hardcoded target/ path (721-nyev): an executable bit
# is a claim, running the binary is evidence. resolve_plan_binary also settles
# which of debug/release is the CURRENT artefact, which a first-match loop over
# two paths gets wrong whenever both exist.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
BIN="$(resolve_plan_binary 2>/dev/null || printf '')"

if [ -z "$BIN" ]; then
    # FAIL, never skip. A stale or missing binary is the one way this guard
    # could quietly stop being checked while still reporting green.
    bad "no runnable tillandsias-plan resolved — build it ('cargo build -p tillandsias-plan') so guard 2's message is exercised rather than assumed"
else
    # THE PIN TOKEN IS ASSEMBLED, NEVER WRITTEN LITERALLY. A probe fixture that
    # spelled out the whole `litmus:<name>` form would be read by the pin-claim
    # scanner (721-77yu) as this FILE claiming verification it does not supply,
    # and the gate would refuse the fixture for containing its own test data.
    # Splitting the prefix from the name keeps the probe honest for the guard
    # under test — which parses the assembled YAML — while leaving nothing for a
    # source scanner to mistake for a claim.
    _pin_prefix="litmus"
    _pin_name="a-test-this-packet-has-not-written-yet"
    {
        printf 'packets:\n'
        printf '  - packet_id: probe-a-packet-that-pins-its-own-future-test\n'
        printf '    order: 9999-zzzz\n'
        printf '    status: ready\n'
        printf '    verifiable_closure: "%s:%s"\n' "$_pin_prefix" "$_pin_name"
    } > "$tmp/pin.yaml"
    g2="$("$BIN" declared-closures-check "$tmp/pin.yaml" 2>&1)"

    if printf '%s' "$g2" | grep -q 'declared-closure-unresolvable'; then
        ok "guard 2 still refuses a pin nothing defines — the behaviour being preserved"
    else
        bad "guard 2 did not refuse a dangling pin; the rebuild may be stale or the guard regressed"
    fi
    if printf '%s' "$g2" | grep -q "$EXIT_FORM"; then
        ok "guard 2 names the sanctioned exit '$EXIT_FORM'"
    else
        bad "guard 2 refuses the pin without naming '$EXIT_FORM' — the natural next move is to delete the pin, straight back into guard 1"
    fi
    if printf '%s' "$g2" | grep -q '977-448j'; then
        ok "guard 2 names its counterpart (977-448j), so deleting the pin is visibly not the way out"
    else
        bad "guard 2 does not name guard 1 — the two refusals still do not reference each other"
    fi
    if printf '%s' "$g2" | grep -q '1068-cxmf'; then
        ok "guard 2 names the dangling-pin defect (1068-cxmf) the attractive wrong turn creates"
    else
        bad "guard 2 does not name 1068-cxmf, so the cost of leaving the pin dangling stays folklore"
    fi
fi

echo "closure-guards-name-the-way-out: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
