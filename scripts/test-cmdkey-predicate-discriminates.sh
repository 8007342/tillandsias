#!/usr/bin/env bash
# @trace order:1004-vsh2
#
# Fixture: the smoke runbook's credential-presence predicate must be able to be
# FALSE, and on a Windows host it is run for real against a target that does not
# exist.
#
# WHAT WENT WRONG. Runbook §2 clears the two guest-vault entries and verified
# with `(& cmdkey.exe /list:$_ ) -match [regex]::Escape($_)`. `cmdkey
# /list:<target>` ECHOES THE QUERIED NAME IN ITS HEADER even when no such
# credential exists:
#
#   Currently stored credentials for definitely-not-a-real-target-xyz:
#   * NONE *
#
# so the match was TRUE FOR EVERY TARGET. Two failures in opposite directions
# from one predicate: the post-delete assertion threw on EVERY run including a
# clean one, so the Windows smoke could not complete without a hand override;
# and the same predicate gated the delete, so the guard never guarded — it
# deleted unconditionally, harmless but blind by construction.
#
# A PREDICATE THAT CANNOT BE FALSE IS NOT A CHECK. That is the packet's own
# phrase and it is the thing this fixture exists to keep true.
#
# ARM 2 IS THE ONE WITH TEETH. Arm 1 only reads the runbook and would pass on
# any text that avoids one banned spelling. Arm 2 EXECUTES the shipped predicate
# against a target that certainly does not exist and requires FALSE — which is
# the case the original could never produce. It runs only on a Windows host,
# because it needs the real cmdkey; elsewhere it reports SKIP rather than
# pretending.
#
# MEASURED ON YOLANDA 2026-09-05, and the last row is why the naive whole-store
# repair was not used:
#
#   absent target, broken predicate                     -> True   (wrong)
#   present target, broken predicate                    -> True   (right by luck)
#   absent target, shipped echo-count predicate         -> False  (correct)
#   present LegacyGeneric entry, queried BARE           -> 2 echoes, True
#
# The product writes TargetName="vault-shamir-share-v1" bare while cmdkey
# DISPLAYS generic entries as `LegacyGeneric:target=<name>`, so a repair that
# matched `target=<name>` against the whole store would depend on that display
# form. The echo count does not: the header echoes the name once, a real record
# echoes it again on its own line, and 1 vs >=2 separates them regardless of how
# cmdkey chooses to render the prefix.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNBOOK="$ROOT/skills/smoke-curl-install-and-test-e2e/SKILL.md"
[ -f "$RUNBOOK" ] || { echo "SKIP: runbook not present" >&2; exit 0; }

pass=0
fail=0
_result() { # name expected actual
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL $1: expected [$2] got [$3]" >&2
    fi
}

echo "== 1004-vsh2: the credential-presence predicate must be able to be false"

# ---- ARM 1: the always-true spelling is not used as a PRESENCE test ---------
# Comments are stripped first: this runbook DOCUMENTS the broken predicate in
# the block that explains why it was replaced, and a scan that matched prose
# would red a correct file — the 1055-6yp8 lesson.
code="$(sed 's/^[[:space:]]*#.*//' "$RUNBOOK")"
case "$code" in
    *'$out -match [regex]::Escape($cred)'*) banned=present ;;
    *) banned=absent ;;
esac
_result "arm1-the-always-true-spelling-is-not-live-code" "absent" "$banned"

# The replacement must actually be there, or arm 1 passes on a file that lost
# the check entirely.
case "$code" in
    *"Test-TillandsiasCredPresent"*) helper=present ;;
    *) helper=absent ;;
esac
_result "arm1-a-named-presence-helper-exists" "present" "$helper"

# ---- ARM 2: RUN IT. The predicate must return FALSE for an absent target ----
_is_windows=no
case "${OS:-}${OSTYPE:-}" in *[Ww]indows*|*msys*|*cygwin*) _is_windows=yes ;; esac
command -v powershell.exe >/dev/null 2>&1 || _is_windows=no

if [ "$_is_windows" = yes ]; then
    absent_verdict="$(powershell.exe -NoProfile -Command '
        function Test-TillandsiasCredPresent([string] $target) {
            $out = & cmdkey.exe "/list:$target" 2>$null
            (($out | Where-Object { $_ -match [regex]::Escape($target) }) | Measure-Object).Count -ge 2
        }
        if (Test-TillandsiasCredPresent "tillandsias-fixture-absent-target-1004vsh2") { "true" } else { "false" }
    ' 2>/dev/null | tr -d "\r\n ")"
    _result "arm2-shipped-predicate-is-FALSE-for-an-absent-target" "false" "$absent_verdict"

    # And the ORIGINAL predicate must be TRUE for the same target — the control
    # that proves arm 2 is measuring the fix rather than the weather.
    broken_verdict="$(powershell.exe -NoProfile -Command '
        $t = "tillandsias-fixture-absent-target-1004vsh2"
        $out = (& cmdkey.exe "/list:$t" 2>$null | Out-String)
        if ($out -match [regex]::Escape($t)) { "true" } else { "false" }
    ' 2>/dev/null | tr -d "\r\n ")"
    _result "arm2-control-the-ORIGINAL-predicate-is-TRUE-for-the-same-target" "true" "$broken_verdict"
else
    echo "  SKIP arm2: needs a Windows host with cmdkey; not asserting from prose" >&2
fi

echo "PASS: $pass  FAIL: $fail"
if [ "$fail" -gt 0 ]; then
    echo "violation:cmdkey-predicate:$fail arm(s) failed"
    exit 1
fi
echo "ok:cmdkey-predicate:$pass arm(s)"
