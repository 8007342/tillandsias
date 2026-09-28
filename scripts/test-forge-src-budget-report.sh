#!/usr/bin/env bash
# @trace spec:forge-hot-cold-split, order:1445-7u63
#
# test-forge-src-budget-report.sh — when /home/forge/src (a kernel-capped tmpfs,
# 997-e4v2) is full, the forge NAMES the exhausted source budget instead of git
# dying with a bare write error and the clone path blaming the mirror.
# Measured 2026-09-27: lenovinha-forge's 256M tmpfs filled with a 167M .git and
# git died mid-write; the clone-failure path's only words were "the git mirror
# service is unreachable or has not finished initialising".
#
# forge_src_budget_report is EXTRACTED from the real lib-common.sh (never the
# whole file) and run against a stubbed `df`, because a rootless host cannot
# mount a tmpfs to fill.
#
# Arms:
#   1 FULL      df reports 97% used: one line naming the source budget, rc 0
#   2 NOT FULL  df reports 40% used: no output, rc 1 (so a caller's generic
#               message is left alone)
#   3 UNREADABLE df fails: no output, rc 1 (never a guess)
#   4 WIRED     both clone-failure paths call the report BEFORE their FATAL line
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

FN="$(awk '/^forge_src_budget_report\(\) \{/ { p = 1 } p { print } p && /^}$/ { exit }' "$LIB")"
[ -n "$FN" ] || { echo "FAIL: forge_src_budget_report not found in $LIB"; exit 1; }
eval "$FN"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/src-budget.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/src"
stub_df() {   # <used%> | fail
    if [ "$1" = fail ]; then
        printf '#!/bin/sh\nexit 1\n' >"$scratch/bin/df"
    else
        printf '#!/bin/sh\necho "Filesystem Size Used Avail Use%% Mounted on"\necho "tmpfs 256M 249M 7M %s%% /home/forge/src"\n' "$1" >"$scratch/bin/df"
    fi
    chmod +x "$scratch/bin/df"
}

stub_df 97
out="$(PATH="$scratch/bin:$PATH" forge_src_budget_report "$scratch/src")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q "FULL: 249M of 256M (97%)" <<<"$out" && grep -q "not a mirror or network fault" <<<"$out"; then
    ok "ARM1 a full source tmpfs is named, with its numbers"
else bad "ARM1 rc=$rc out='$out'"; fi

stub_df 40
out="$(PATH="$scratch/bin:$PATH" forge_src_budget_report "$scratch/src")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] && ok "ARM2 a source tmpfs with room says nothing" \
    || bad "ARM2 rc=$rc out='$out'"

stub_df fail
out="$(PATH="$scratch/bin:$PATH" forge_src_budget_report "$scratch/src")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] && ok "ARM3 an unreadable df reports nothing rather than guessing" \
    || bad "ARM3 rc=$rc out='$out'"

# ARM 4 — each FATAL clone line is preceded, on the line before, by the report.
wired="$(awk '
    /echo "\[forge\] FATAL: (filesystem clone failed|git clone failed from git:)/ {
        n++; if (prev ~ /forge_src_budget_report/) w++
    }
    { prev = $0 }
    END { printf "%d/%d", w, n }' "$LIB")"
[ "$wired" = "2/2" ] && ok "ARM4 both clone-failure paths name the budget before failing ($wired)" \
    || bad "ARM4 clone-failure paths wired: $wired (want 2/2)"

[ "$FAIL" -eq 0 ] && { echo "PASS: forge-src-budget-report (1445-7u63)"; exit 0; }
echo "FAILED: forge-src-budget-report (1445-7u63)"; exit 1
