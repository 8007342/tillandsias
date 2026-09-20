#!/usr/bin/env bash
# @trace order:1313-w78k
#
# Both directions of the asymmetric rule, and the asymmetry IS the contract:
# a future ts is refused with no declaration that admits it, a past ts is
# accepted and printed. A fixture that only proved the refusal would pass a
# checker that refused everything, which would break every relay fold in the
# fleet — lenovinha's fragments are written hours before they are folded.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1
CHECK=scripts/check-fragment-ts-skew.sh
[ -x "$CHECK" ] || { echo "FAIL: $CHECK missing or not executable"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  [OK]   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }

PROBE=plan/index.d/zz-1313-probe.yaml
cleanup() { rm -f "$PROBE"; }
trap cleanup EXIT INT TERM HUP PIPE

# Portable offsets: GNU `date -d`, else BSD `date -v`. Neither is universal and
# this fixture runs on macOS too (osx-next pushes through the same hook).
# VALIDATE THE OUTPUT, NEVER THE EXIT STATUS. BSD date accepts -d and SUCCEEDS
# WITH GARBAGE, so `cmd || fallback` never reaches the fallback and the caller
# gets nonsense that looks like a timestamp — the relay found exactly this in
# check-fragment-ts-skew.sh the same day. Each candidate is checked against the
# shape it must have before it is accepted.
_at() { # $1 = signed seconds
    local out
    out="$(date -u -d "@$(( $(date -u +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    case "$out" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-*Z) printf '%s\n' "$out"; return 0 ;; esac
    # BSD `date -v` REQUIRES AN EXPLICIT SIGN. `-v7200S` is not "+7200 seconds",
    # it is a parse error ("7200S: Cannot apply date adjustment"), so the two
    # non-negative callers below (+7200 and 0) both produced an empty string and
    # the `[ -n ... ]` guard skipped the whole fixture on every macOS host —
    # MEASURED on macneo 2026-09-20, before and after the epoch-shape hardening:
    # `skip:fragment-ts-skew:no-portable-date`, so 1313-w78k's guard had NO macOS
    # coverage at all. The negative caller worked, which is why it reads as a
    # date-support problem rather than a sign problem. GNU `date -d` needs no
    # sign, so the first arm above is unaffected.
    local _off="$1"
    case "$_off" in -*|+*) : ;; *) _off="+$_off" ;; esac
    out="$(date -u -v"${_off}S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    case "$out" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-*Z) printf '%s\n' "$out"; return 0 ;; esac
    return 1
}
_plant() { printf 'events:\n  - packet_id: probe\n    event:\n      type: note\n      ts: "%s"\n      agent_id: probe\n      host: probe\n      summary: probe\n' "$1" > "$PROBE"; }

FUTURE="$(_at 7200)"; PAST="$(_at -7200)"; NOW="$(_at 0)"
[ -n "$FUTURE" ] && [ -n "$PAST" ] && [ -n "$NOW" ] || { echo "skip:fragment-ts-skew:no-portable-date"; exit 0; }

# ── ARM 1: two hours ahead is REFUSED, and the file is named ────────────────
_plant "$FUTURE"
out="$(bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a ts two hours AHEAD is refused (rc=$rc)"; else bad "a future ts was accepted (rc=$rc)"; fi
case "$out" in *"$PROBE"*) ok "the refusal names the file" ;; *) bad "the refusal does not name the file" ;; esac
case "$out" in *"not a backfill"*) ok "the refusal says a future ts is not a backfill" ;; *) bad "the refusal does not explain why no declaration admits it" ;; esac
case "$out" in *"date -u"*) ok "the refusal carries a remedy the operator can type" ;; *) bad "no remedy in the refusal" ;; esac

# ── ARM 2: two hours behind is ACCEPTED and PRINTED ─────────────────────────
# The load-bearing half. A delayed push is real and common.
_plant "$PAST"
out="$(bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "a ts two hours BEHIND is accepted (rc=0)"; else bad "a past ts was refused (rc=$rc) — this breaks every relay fold"; fi
case "$out" in *note:fragment-ts-past:*) ok "the past skew is PRINTED, not swallowed" ;; *) bad "a past ts was accepted silently — the skew is invisible" ;; esac

# ── ARM 3: CONTROL — a clock-read ts is accepted with no note ───────────────
_plant "$NOW"
out="$(bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "CONTROL: a ts read from the clock is accepted" ;else bad "CONTROL: a current ts was refused (rc=$rc)"; fi
case "$out" in *note:fragment-ts-past:*) bad "CONTROL: a current ts produced a past-skew note" ;; *) ok "CONTROL: a current ts produces no note" ;; esac

# ── ARM 4: NEGATIVE CONTROL — the check is DIFF-SCOPED ──────────────────────
# Fragments already on the base ref are not re-judged: one host's mistake must
# not turn every other host's gate red until someone else fixes it (698-7n6q's
# construction). The six future-dated fragments this row is about are on trunk
# and are deliberately left standing, so this also pins that they stay quiet.
cleanup
out="$(bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "NEGATIVE CONTROL: with nothing added, the check is silent and passes" ;else bad "the check refuses a tree it did not change (rc=$rc)"; fi

printf 'fragment-ts-skew %d/%d\n' "$pass" "$((pass+fail))"
[ "$fail" -eq 0 ] || exit 1
echo "ok:fragment-ts-skew-fixture:$pass/$pass"
