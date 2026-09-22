#!/usr/bin/env bash
# @trace spec:init-command
# @trace order:1339-r9xv
#
# Pin 1339-r9xv: the Windows installer REPORTS the guest shape a user's
# .wslconfig will produce, NAMES a known-bad ratio with its numbers, and
# OFFERS the configuration -- and never writes .wslconfig itself.
#
# WHY THE ROW EXISTS, measured on yolanda-windows 2026-09-21: with WSL
# defaults a 16-logical-CPU host ran its guest with ALL 16 vCPUs inside a
# 4.8 GiB balloon (~320 MB per vCPU) and FOUR consecutive builds were killed
# for host memory. The same gates on a FOUR-core machine with processors=4
# (100% of that host) and autoMemoryReclaim=gradual were never killed once.
# The more capable machine was the unreliable one and the difference was
# entirely configuration. install-windows.ps1 mentioned .wslconfig zero times.
#
# ARM 0 IS WRITTEN FIRST AND ON PURPOSE. Every other arm reads the installer
# source; if that read fails, the arms see nothing and would report the
# SUBJECT as broken. This fleet met that failure five times in one night --
# a fixture whose awk separator read empty and blamed a correct fix, a memory
# floor reading the wrong machine, a probe containing a copy of its subject.
# So arm 0 refuses with could-not-run and says plainly that a measurement
# failure is NOT a verdict.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

SRC="${TILLANDSIAS_INSTALLER_SRC:-scripts/install-windows.ps1}"
fail=0
_ok()  { echo "ok:   $1"; }
_bad() { echo "FAIL: $1"; fail=1; }

# --- ARM 0: can this arm measure at all? -----------------------------------
if [ ! -f "$SRC" ]; then
    echo "could-not-run:wsl-guest-shape:no-installer:$SRC"
    echo "  This is a MEASUREMENT FAILURE, not a verdict on the installer."
    exit 2
fi
# Comments are stripped for the source arms: this file and the installer both
# QUOTE the idioms under test while explaining them, and a scan that reads
# comments refuses the very tree that satisfies it.
CODE="$(mktemp)"; trap 'rm -f "$CODE"' EXIT
sed 's/#.*//' "$SRC" > "$CODE"
if [ ! -s "$CODE" ]; then
    echo "could-not-run:wsl-guest-shape:comment-strip-produced-nothing"
    echo "  This is a MEASUREMENT FAILURE, not a verdict on the installer."
    exit 2
fi
_ok "ARM 0: the installer is readable and survives comment-stripping ($(wc -l < "$CODE") lines)"

# --- ARM 1: it READS the user's .wslconfig ---------------------------------
if grep -q 'wslconfig' "$CODE"; then
    _ok "ARM 1: the installer references .wslconfig (pre-fix: zero mentions)"
else
    _bad "ARM 1: the installer never mentions .wslconfig -- the pre-fix state"
fi

# --- ARM 2: it DERIVES the effective shape, not just echoes the file -------
# The user cannot compute this themselves; deriving it is the deliverable.
_d=0
grep -q 'NumberOfLogicalProcessors' "$CODE" && _d=$((_d+1))
grep -q 'TotalVisibleMemorySize'    "$CODE" && _d=$((_d+1))
grep -qE '\$EffCpus|EffMemGiB'      "$CODE" && _d=$((_d+1))
if [ "$_d" -eq 3 ]; then
    _ok "ARM 2: it derives the effective guest shape from host CPU + memory + config ($_d/3 signals)"
else
    _bad "ARM 2: expected 3 derivation signals (host CPUs, host memory, effective shape), found $_d"
fi

# --- ARM 3: the known-bad ratio is NAMED WITH NUMBERS ----------------------
# A generality tells the user nothing about their own machine.
if grep -q 'MB per vCPU' "$CODE" && grep -qE '320 MB per vCPU' "$CODE"; then
    _ok "ARM 3: the warning names the ratio AND the measured failure figure"
else
    _bad "ARM 3: the known-bad ratio is not named with its measured numbers"
fi

# --- ARM 4: the [experimental] trap is called out -------------------------
# autoMemoryReclaim under [wsl2] silently does nothing -- a user following
# generic advice lands exactly there.
if grep -q 'experimental' "$CODE" && grep -qi 'appending it to \[wsl2\] does nothing' "$CODE"; then
    _ok "ARM 4: the [experimental] section trap is stated, not assumed"
else
    _bad "ARM 4: nothing warns that autoMemoryReclaim under [wsl2] is inert"
fi

# --- ARM 5: IT MUST NOT WRITE THE USER'S FILE ------------------------------
# THIS IS THE ARM THAT MATTERS MOST. Writing .wslconfig silently would be a
# worse defect than the one being fixed: the file is the user's and may carry
# settings for unrelated work. Assert the absence of every write verb aimed
# at that path, by CARDINALITY rather than by a single grep.
# THE SEPARATOR IS LOAD-BEARING AND ITS ABSENCE FAILED THIS ARM ONCE. The
# first version required the write verb and the variable to be ADJACENT --
# `(Set-Content|...)\$WslCfgPath` -- so a control injecting the obvious
# `Set-Content $WslCfgPath "x"` sailed straight through the arm written to
# forbid exactly that. An arm that cannot catch its own named sabotage is
# not an arm. Allow any run of non-newline characters between the verb and
# the path, and count every match rather than asking whether one exists.
_w=$(grep -cE '(Set-Content|Out-File|Add-Content|New-Item|Move-Item|Copy-Item|Remove-Item)[^\n]*\$WslCfgPath' "$CODE" 2>/dev/null || true)
_w=$((_w + $(grep -cE '\$WslCfgPath[^\n]*(-Value|>>|>)' "$CODE" 2>/dev/null || true)))
if [ "$_w" -eq 0 ]; then
    _ok "ARM 5: the installer never writes .wslconfig -- it reports and offers only"
else
    _bad "ARM 5: found $_w write path(s) targeting the user's .wslconfig -- it must never write that file"
fi

# --- ARM 6: could-not-measure is distinguished from a verdict --------------
# The installer's own version of arm 0: if it cannot read the host, it must
# say so rather than advise from a shape it does not have.
if grep -q 'could not read this host' "$CODE"; then
    _ok "ARM 6: the installer refuses to advise when it cannot read the host"
else
    _bad "ARM 6: nothing handles the case where the host CPU/memory read fails"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:installer-reports-wsl-guest-shape:7/7 arms"
else
    echo "violation:installer-reports-wsl-guest-shape"
fi
exit "$fail"
