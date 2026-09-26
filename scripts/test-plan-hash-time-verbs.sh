#!/usr/bin/env bash
# test-plan-hash-time-verbs.sh — order 1375-8g5t.
#
#   1  `printf abc | tillandsias-plan hash sha256 -` is the NIST vector
#   2  the file form matches whichever of sha256sum / `shasum -a 256` the host
#      has, byte for byte on the hex (skip-named when the host has neither)
#   3  `time now --ms` prints 13 digits, and two calls 10 ms apart differ by a
#      POSITIVE amount — a one-second clock cannot pass (1279-a7b6: BSD date
#      answers `+%s%3N` at one-second resolution)
#   4  `time now --iso` matches ^[0-9]{8}t[0-9]{6}z$, the fragment-filename clock
#   5  `time now --rfc3339` is UTC with a Z
#   6  an unknown form is a usage error (exit 2), never output
#
#   PASS: plan-hash-time-verbs <n>/<n>     every arm held
#   blocked:hash-time-verbs-absent         the binary lacks the verbs (pre-fix)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
PLAN="$(resolve_plan_binary 2>/dev/null)" || { echo "skip:plan-hash-time-verbs:no-plan-binary"; exit 3; }
caps="$("$PLAN" capabilities 2>/dev/null)"
case "
$caps
" in
    *"
hash
"*"
time
"*) ;;
    *) echo "blocked:hash-time-verbs-absent"; exit 1 ;;
esac

pass=0
fail=0
ok() { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/hash-time.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# ARM 1
got="$(printf abc | "$PLAN" hash sha256 -)"
if [ "$got" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ]; then
    ok "ARM 1: sha256(abc) from stdin is the NIST vector"
else
    bad "ARM 1: sha256(abc) = '$got'"
fi

# ARM 2 — against the host's own tool, over a file that is not a toy.
f="$scratch/blob"
i=0
while [ "$i" -lt 2000 ]; do printf 'line %d of a file larger than one read block\n' "$i"; i=$((i + 1)); done > "$f"
mine="$("$PLAN" hash sha256 "$f")"
if command -v sha256sum >/dev/null 2>&1; then
    theirs="$(sha256sum "$f")"; tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    theirs="$(shasum -a 256 "$f")"; tool="shasum -a 256"
else
    theirs=""; tool=""
fi
if [ -z "$tool" ]; then
    printf 'skip: ARM 2: host has neither sha256sum nor shasum\n'
elif [ "$mine" = "${theirs%% *}" ]; then
    ok "ARM 2: the file digest equals $tool's hex"
else
    bad "ARM 2: file digest $mine vs $tool ${theirs%% *}"
fi

# ARM 3 — real milliseconds.
a="$("$PLAN" time now --ms)"
sleep 0.01 2>/dev/null || perl -e 'select(undef, undef, undef, 0.01)' 2>/dev/null || sleep 1
b="$("$PLAN" time now --ms)"
case "$a$b" in *[!0-9]*) digits=no ;; *) digits=yes ;; esac
if [ "$digits" = yes ] && [ "${#a}" -eq 13 ] && [ "${#b}" -eq 13 ] && [ "$b" -gt "$a" ]; then
    ok "ARM 3: time now --ms is 13 digits and advanced by $((b - a)) ms across a 10 ms sleep"
else
    bad "ARM 3: time now --ms gave '$a' then '$b'"
fi

# ARM 4
iso="$("$PLAN" time now --iso)"
if grep -Eq '^[0-9]{8}t[0-9]{6}z$' <<<"$iso"; then
    ok "ARM 4: time now --iso = $iso"
else
    bad "ARM 4: time now --iso = '$iso'"
fi

# ARM 5
r="$("$PLAN" time now --rfc3339)"
if grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$r"; then
    ok "ARM 5: time now --rfc3339 = $r"
else
    bad "ARM 5: time now --rfc3339 = '$r'"
fi

# ARM 6
out6="$("$PLAN" hash md5 "$f" 2>/dev/null)"; rc6=$?
if [ "$rc6" -eq 2 ] && [ -z "$out6" ]; then
    ok "ARM 6: an unknown form is a usage error (rc 2), not output"
else
    bad "ARM 6: hash md5 gave rc=$rc6 out='$out6'"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'PASS: plan-hash-time-verbs %d/%d (1375-8g5t)\n' "$pass" "$total"
    exit 0
fi
printf 'FAIL: plan-hash-time-verbs %d/%d (1375-8g5t)\n' "$pass" "$total"
exit 1
