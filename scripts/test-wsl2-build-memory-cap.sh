#!/usr/bin/env bash
# @trace order:667-kfyn
#
# scripts/wsl2-build-memory-cap.sh against a constructed cgroup-v2 tree (the
# TILLANDSIAS_WSL2_CGROUP_ROOT seam), so it runs on any host:
#   1 JOIN      a tree with the memory controller: the controller is enabled
#               for children, the group gets memory.high, the pid is written
#               to the group's cgroup.procs, and the verdict names the cap
#   2 DEFAULT   no argument and no env: the cap is 3G (the measured value)
#   3 OFF       "off" touches nothing (NEGATIVE CONTROL: no group created)
#   4 NO-MEM    a tree whose controllers lack memory: skip, exit 0, no group
#   5 WIRED     with-wsl2-builder.sh runs it in the guest prefix, before the build
#   6 NESTED    wsl-guest-session.sh nests its teardown cgroup inside the cap
# Prints one summary line; exit 0/1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/wsl2-build-memory-cap.sh"
pass=0; fail=0
ok()  { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/wsl2-memory-cap.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

tree() {  # tree <name> <controllers line>
    mkdir -p "$work/$1"
    printf '%s\n' "$2" > "$work/$1/cgroup.controllers"
    : > "$work/$1/cgroup.subtree_control"
    T="$work/$1"
}
cap() {  # cap <tree> [args...] — runs the subject with pid 4242
    local t="$1"; shift
    O="$(env -u TILLANDSIAS_WSL2_BUILD_MEMORY_HIGH TILLANDSIAS_WSL2_CGROUP_ROOT="$t" TILLANDSIAS_WSL2_CGROUP_PID=4242 bash "$SUBJECT" "$@" 2>&1)"; RC=$?
}

tree join "cpuset cpu io memory pids"; cap "$T" 2G
if [ "$RC" -eq 0 ] && grep -qx '+memory' "$T/cgroup.subtree_control" \
   && [ "$(cat "$T/tillandsias-build/memory.high" 2>/dev/null)" = 2G ] \
   && [ "$(cat "$T/tillandsias-build/cgroup.procs" 2>/dev/null)" = 4242 ] \
   && [ "$O" = "ok:wsl2-build-memory-cap:tillandsias-build:high=2G" ]; then
    ok "1 JOIN the controller is enabled, the cap written and the pid joined"
else
    bad "1 JOIN got rc=$RC '$O' high=$(cat "$T/tillandsias-build/memory.high" 2>/dev/null) procs=$(cat "$T/tillandsias-build/cgroup.procs" 2>/dev/null)"
fi

tree default "memory"; cap "$T"
if [ "$RC" -eq 0 ] && [ "$(cat "$T/tillandsias-build/memory.high" 2>/dev/null)" = 3G ]; then
    ok "2 DEFAULT with no argument and no env the cap is 3G"
else
    bad "2 DEFAULT got rc=$RC '$O'"
fi

tree off "memory"; cap "$T" off
if [ "$RC" -eq 0 ] && [ "$O" = "skip:wsl2-build-memory-cap:off" ] && [ ! -e "$T/tillandsias-build" ] \
   && [ ! -s "$T/cgroup.subtree_control" ]; then
    ok "3 OFF touches nothing"
else
    bad "3 OFF got rc=$RC '$O'"
fi

tree nomem "cpuset cpu io pids"; cap "$T"
if [ "$RC" -eq 0 ] && [ "$O" = "skip:wsl2-build-memory-cap:no-memory-controller" ] && [ ! -e "$T/tillandsias-build" ]; then
    ok "4 NO-MEM a tree without the memory controller is a named skip, exit 0"
else
    bad "4 NO-MEM got rc=$RC '$O'"
fi

if grep -q '^_ENV_PREFIX="\$_ENV_PREFIX bash scripts/wsl2-build-memory-cap.sh >&2 || true;"$' "$ROOT/scripts/with-wsl2-builder.sh"; then
    ok "5 WIRED with-wsl2-builder.sh runs the cap in the guest prefix"
else
    bad "5 WIRED with-wsl2-builder.sh no longer runs scripts/wsl2-build-memory-cap.sh in _ENV_PREFIX"
fi

# The session supervisor makes a cgroup of its own for teardown (1567-9fgi). At
# the root it escaped the cap: measured 2026-10-17, Windows fell to 1.2 GB free
# with the build outside tillandsias-build. It must nest under its own cgroup.
# (Verified live in tillandsias-build: 0::/tillandsias-build/tillandsias-session-<pid>.)
if grep -q '^    _gs_base="\$_gs_root\$(sed -n '"'"'s/^0:://p'"'"' /proc/\$\$/cgroup 2>/dev/null)"$' "$ROOT/scripts/wsl-guest-session.sh" \
   && grep -q '^    _gs_cg="\$_gs_base/tillandsias-session-\$\$"$' "$ROOT/scripts/wsl-guest-session.sh"; then
    ok "6 NESTED the guest session cgroup is created under the supervisor's own cgroup, inside the cap"
else
    bad "6 NESTED wsl-guest-session.sh creates its cgroup outside the supervisor's own — the build escapes the memory cap"
fi

echo "wsl2-build-memory-cap: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
