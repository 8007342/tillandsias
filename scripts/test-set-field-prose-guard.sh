#!/usr/bin/env bash
# @trace order:1151-td46
# @trace order:642-fedr (the LWW channel that replaces wholesale)
#
# REGIME: hermetic, against a THROWAWAY ledger. Every arm builds its own
# plan/ tree under a temp dir and points the binary at it with --index, so no
# arm reads or writes this checkout's real ledger. That is not politeness: a
# fixture for a guard about clobbering shared prose must not itself clobber
# shared prose, and the first live probe of this change wrote a real fragment
# onto a real row's next_action before it was removed.
#
# NO ABSOLUTE TIMESTAMP IS ENCODED HERE. --append stamps its attribution line
# with the write's own ts; an arm asserts the OLD LINES SURVIVE and that the new
# text is present, never that the stamp equals any particular time.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
. scripts/plan-binary-probe.sh
PLAN="$(resolve_plan_binary)" || { echo "could-not-run:set-field-prose-guard:no-plan-binary"; exit 3; }
# RESOLVE BEFORE ANY cd. resolve_plan_binary answers a path relative to the repo
# root, and every arm below runs inside a scratch ledger dir — so a relative
# path becomes 127 there, which the first run of this fixture spent ten arms
# reporting as "the guard did not refuse". A PATH fallback would have hidden it
# worse (tool-resolution-after-cd, and it once cost a platform outage).
case "$PLAN" in
    /*) ;;
    *) PLAN="$ROOT/${PLAN#./}" ;;
esac
[ -x "$PLAN" ] || { echo "could-not-run:set-field-prose-guard:not-executable:$PLAN"; exit 3; }

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/prose-guard.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT

# A three-line next_action, the shape esme lost three warnings from.
_ledger() {
    local d; d="$(mktemp -d "$W/l.XXXXXX")"
    mkdir -p "$d/plan/index.d"
    cat > "$d/plan/index.yaml" <<'YAML'
packets:
  - packet_id: a-row-with-shared-prose
    order: 9999-test
    status: ready
    kind: bug
    priority: p2
    next_action: |
      FIRST LINE, this host's own sentence.
      DO NOT MOVE legacy_tier WITHOUT TELLING YOGA — a downstream grep -m1 makes key order load-bearing.
      VERIFICATION DEBT: the hwfp-v2 field list is unconfirmed on two hosts.
YAML
    printf '%s' "$d"
}

_sf() { # _sf <ledger-dir> <args...> -> prints output; rc in $W/rc
    local d="$1"; shift
    ( cd "$d" && "$PLAN" --index "$d/plan/index.yaml" set-field "$@" 2>&1 )
    printf '%s' "$?" > "$W/rc"
}
_rc() { cat "$W/rc" 2>/dev/null || echo 99; }
# READ WHAT WAS WRITTEN, from the fragment's LWW value. There is no subcommand
# that prints one folded field (the first version of this helper called `show`,
# which this binary does not have — every assertion below then read an empty
# string and three arms failed for a reason unrelated to the guard). The fold
# APPLYING this channel is 642-fedr's subject and is guarded there; what this
# fixture owns is what set-field puts in the fragment.
_written() { # _written <ledger-dir> -> the value set-field recorded
    cat "$1"/plan/index.d/*.yaml 2>/dev/null
}

# ── 1. a dropping write is REFUSED and NAMES what it would drop ─────────────
d="$(_ledger)"
out="$(_sf "$d" 9999-test next_action "one short replacement line" --host yoga)"
rc="$(_rc)"
if [ "$rc" = "2" ] && case "$out" in *refused:set-field:would-drop-prose*) true ;; *) false ;; esac; then
    ok "a value that drops old lines is refused with rc 2"
else
    bad "a dropping write was not refused (rc=$rc): $(printf '%s' "$out" | head -1)"
fi
_named=0
case "$out" in *"DO NOT MOVE legacy_tier"*) _named=$((_named+1)) ;; esac
case "$out" in *"VERIFICATION DEBT"*)      _named=$((_named+1)) ;; esac
if [ "$_named" -eq 2 ]; then
    ok "the refusal PRINTS the lines it would have dropped, both of them"
else
    bad "the refusal did not name the dropped lines ($_named of 2 shown)"
fi
# CONJOINED WITH THE REFUSAL ON PURPOSE: on this fixture's first run every arm
# failed at 127 and THIS one still passed — nothing had run, so of course no
# fragment existed. An arm that passes when the tool never executed is the
# green-asserting-nothing shape this ledger keeps paying for.
if [ "$rc" = "2" ] && [ -z "$(ls -A "$d/plan/index.d" 2>/dev/null)" ]; then
    ok "a refused write leaves NO fragment behind"
else
    bad "a refused write still wrote a fragment — the refusal is cosmetic"
fi

# ── 2. --replace is the deliberate escape, and it still replaces wholesale ──
d="$(_ledger)"
out="$(_sf "$d" 9999-test next_action "one short replacement line" --replace --host yoga)"
rc="$(_rc)"
[ "$rc" = "0" ] && ok "--replace replaces wholesale, as before" \
                || bad "--replace was refused (rc=$rc): $(printf '%s' "$out" | head -1)"

# ── 3. --append preserves EVERY old line and adds the new text ─────────────
d="$(_ledger)"
out="$(_sf "$d" 9999-test next_action "and a fourth line from another host" --append --host yoga)"
rc="$(_rc)"
folded="$(_written "$d")"
_kept=0
case "$folded" in *"DO NOT MOVE legacy_tier"*) _kept=$((_kept+1)) ;; esac
case "$folded" in *"VERIFICATION DEBT"*)      _kept=$((_kept+1)) ;; esac
case "$folded" in *"FIRST LINE"*)             _kept=$((_kept+1)) ;; esac
if [ "$rc" = "0" ] && [ "$_kept" -eq 3 ]; then
    ok "--append keeps all three old lines"
else
    bad "--append lost old lines (rc=$rc, kept $_kept of 3)"
fi
case "$folded" in
    *"and a fourth line from another host"*) ok "--append adds the new text" ;;
    *) bad "--append did not add the new text" ;;
esac
case "$folded" in
    *"[20"*"yoga]"*) ok "--append stamps an attribution line naming the writing host" ;;
    *) bad "--append added no attribution, so a later reader cannot tell who added which half" ;;
esac

# ── 4. NEGATIVE CONTROL: short fields are untouched by this guard ──────────
#    status, priority and a single-line next_action must behave exactly as
#    before — a guard that refuses ordinary status writes would stop the fleet.
d="$(_ledger)"
out="$(_sf "$d" 9999-test priority p1 --host yoga)"; rc="$(_rc)"
[ "$rc" = "0" ] && ok "NC: a short field (priority) is unaffected" \
                || bad "NC: the guard refused a short-field write (rc=$rc): $(printf '%s' "$out" | head -1)"

d="$(_ledger)"
out="$(_sf "$d" 9999-test status in_progress --host yoga)"; rc="$(_rc)"
[ "$rc" = "0" ] && ok "NC: a status write is unaffected" \
                || bad "NC: the guard refused a status write (rc=$rc): $(printf '%s' "$out" | head -1)"

# ── 5. NEGATIVE CONTROL: a single-line long field is not protected prose ───
#    The subject is DROPPED LINES, not field length. Replacing a one-line
#    next_action drops one line and SHOULD refuse; replacing it with text that
#    still contains that line must not.
#    The rule is LINE-EXACT, and the consequence is deliberate rather than
#    accidental: EDITING a line in place counts as dropping it, so changing a
#    sentence another host wrote needs --replace (having read it) or --append.
#    That is the case the row exists for — a "small edit" to someone else's
#    warning is exactly how the three lines were lost. Adding a line while
#    keeping the old ones verbatim needs no flag at all.
d="$(_ledger)"
out="$(_sf "$d" 9999-test next_action "FIRST LINE, this host's own sentence.
DO NOT MOVE legacy_tier WITHOUT TELLING YOGA — a downstream grep -m1 makes key order load-bearing.
VERIFICATION DEBT: the hwfp-v2 field list is unconfirmed on two hosts.
and a new line that adds to them" --host yoga)"
rc="$(_rc)"
[ "$rc" = "0" ] && ok "NC: ADDING a line while keeping every old one verbatim needs no flag" \
                || bad "NC: an additive rewrite was refused (rc=$rc) — the guard is about dropping, not editing"

# ── 6. --append and --replace together are a contradiction, not a preference ─
d="$(_ledger)"
out="$(_sf "$d" 9999-test next_action x --append --replace --host yoga)"; rc="$(_rc)"
[ "$rc" = "2" ] && ok "--append with --replace is refused rather than silently picking one" \
                || bad "the two modes did not conflict (rc=$rc)"

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: set-field prose guard $pass/$total (1151-td46)"
    exit 0
fi
echo "FAIL: set-field prose guard $pass/$total (1151-td46)"
exit 1
