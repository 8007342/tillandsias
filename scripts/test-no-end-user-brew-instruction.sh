#!/usr/bin/env bash
# ORDER 956-llei. Mutation pair for scripts/check-no-end-user-brew-instruction.sh:
#   1. the CURRENT tree passes (the removal comment in tray-diagnose.sh is not
#      an instruction — the old guard failed on exactly that comment);
#   2. a copy with a LIVE instruction fails, naming file and line;
#   3. a copy whose only mention is a trailing comment still passes.
# A guard that cannot fail on the thing it forbids is not a guard.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$ROOT/scripts/check-no-end-user-brew-instruction.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/brew-guard.XXXXXX")"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
check() { if [ "$1" = ok ]; then pass=$((pass+1)); echo "ok   $2"; else fail=$((fail+1)); echo "FAIL $2"; fi; }

out="$(bash "$G" "$ROOT/scripts/tray-diagnose.sh" "$ROOT/scripts/diagnose-macos-provision.sh")"; rc=$?
[ $rc -eq 0 ] && [ "$out" = "ok:no-end-user-brew-instruction:2" ] && check ok "current tree passes: $out" || check FAIL "current tree passes (rc=$rc: $out)"

cp "$ROOT/scripts/tray-diagnose.sh" "$W/live.sh"
printf '\necho "install it: brew install jq" >&2\nexit 1\n' >> "$W/live.sh"
out="$(bash "$G" "$W/live.sh")"; rc=$?
case "$out" in FAIL:end-user-brew-instruction:*live.sh:[0-9]*) [ $rc -eq 1 ] && check ok "live instruction FAILS with file:line ($out)" || check FAIL "live instruction rc=$rc" ;; *) check FAIL "live instruction not caught: $out" ;; esac

cp "$ROOT/scripts/tray-diagnose.sh" "$W/comment.sh"
printf '\necho "jq is optional"  # we no longer say brew install jq here\n' >> "$W/comment.sh"
out="$(bash "$G" "$W/comment.sh")"; rc=$?
[ $rc -eq 0 ] && check ok "trailing comment mention still passes" || check FAIL "trailing comment mention failed: $out"

total=$((pass+fail))
if [ $fail -eq 0 ]; then echo "PASS: no-end-user-brew-instruction guard mutation pair ${pass}/${total} (956-llei)"; exit 0; fi
echo "FAIL: no-end-user-brew-instruction guard ${fail}/${total} red (956-llei)"; exit 1
