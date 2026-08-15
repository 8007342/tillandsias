#!/usr/bin/env bash
# @trace order:736-mcy3, spec:ci-release
set -uo pipefail

# Fixture for scripts/nix-toolbox.sh (order 736-mcy3).
#
# What is worth pinning here is the GRAMMAR and the IDEMPOTENCE, not which rung
# a given host lands on — that legitimately differs per host, which is the whole
# reason the script reports the rung instead of assuming one. A test that
# demanded `daemon` would fail on exactly the hosts the script exists to serve.
#
# The one behavioural trap it does pin: `nix eval --expr '1'` is PURE and
# succeeds with the daemon dead, so an ensure that probed with eval reported
# `daemon` on a host where `nix build` then failed to connect to the socket.
# The probe must exercise the STORE.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/nix-toolbox.sh"

failures=()

# 1. GRAMMAR: exactly one line, from the closed vocabulary.
out="$("$SCRIPT" ensure 2>/dev/null)"
rc=$?
lines="$(printf '%s' "$out" | grep -c '')"
[ "$lines" = 1 ] || failures+=("ensure printed $lines lines, expected 1: $out")
printf '%s' "$out" | grep -qE '^(ok:nix-toolbox:(daemon|chroot|toolbox)|blocked:nix-toolbox:(no-nix-and-no-toolbox|image-pull-failed|create-failed))$' \
    || failures+=("ensure verdict outside the pinned grammar: $out")

# 2. EXIT CODE agrees with the verdict — a blocked rung that exits 0 would let a
#    caller build on a nix that does not work.
case "$out" in
    ok:*)      [ "$rc" -eq 0 ] || failures+=("ok verdict with non-zero exit $rc") ;;
    blocked:*) [ "$rc" -ne 0 ] || failures+=("blocked verdict with exit 0") ;;
esac

# 3. IDEMPOTENCE: running it again on an already-prepared host is a no-op that
#    reports the same rung. This is the property the operator asked for — the
#    script must be safe to call from any runbook, on a fresh host or a warm one.
out2="$("$SCRIPT" ensure 2>/dev/null)"
[ "$out" = "$out2" ] || failures+=("not idempotent: first='$out' second='$out2'")

# 4. The store probe is not a pure eval. Asserted on the SOURCE because
#    reproducing a dead daemon inside a fixture would mean stopping a system
#    service; this is the one place a source assertion is cheaper than the
#    behaviour, and its negative control is that `eval --expr` must NOT be the
#    probe.
if grep -q 'nix "${NIX_FEATURES\[@\]}" eval --expr .* >/dev/null 2>&1$' "$SCRIPT"; then
    failures+=("daemon probe uses a pure eval — it answers with the daemon dead")
fi
grep -q 'store ping' "$SCRIPT" || failures+=("no store-exercising probe found")

# 5. nix-args must be consumable: either flags, or a refusal on stderr with a
#    non-zero exit. Never flags AND a refusal.
args="$("$SCRIPT" nix-args 2>/dev/null)"
argrc=$?
if [ "$argrc" -eq 0 ]; then
    printf '%s' "$args" | grep -q 'extra-experimental-features' \
        || failures+=("nix-args exited 0 without usable flags: $args")
fi

if [ "${#failures[@]}" -gt 0 ]; then
    printf 'FAIL: %s\n' "${failures[@]}" >&2
    echo "nix-toolbox: FAIL ${#failures[@]} scenario(s)"
    exit 1
fi
echo "PASS: nix-toolbox fixture 5/5 (grammar, exit-code agreement, idempotence, store-probe-not-pure-eval, nix-args usable) rung=${out#ok:nix-toolbox:}"
