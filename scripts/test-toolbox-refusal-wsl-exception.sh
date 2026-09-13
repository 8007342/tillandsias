#!/usr/bin/env bash
# @trace order:922-curm, spec:methodology-accountability
#
# Order 922-curm. Pin BOTH arms of the toolbox refusal: a WSL2 distro is
# exempt, and a bare Linux host without toolbox is still refused.
#
# WHY BOTH ARMS AND NOT JUST THE FIX
#
# The 2026-08-26 "no host-native fallback" ruling is the thing being modified,
# and the whole point of that ruling is that it refuses. A test that only
# proved "WSL now passes through" would pass just as happily if someone deleted
# the refusal outright — which is precisely the regression this ruling exists to
# prevent. Arm 2 is therefore not decoration: it is the arm that gives arm 1 its
# meaning, and if you ever find yourself deleting arm 2 to make a change go
# green, the change is wrong.
#
# HOW THE ARMS ARE ISOLATED
#
# Neither arm may depend on the machine running it — this must give the same
# verdict on yolanda (really WSL), on macuahuitl (really not), and in a forge.
# So /proc/version is not consulted directly; each arm runs the real script with
# a stubbed PATH and a fabricated /proc/version supplied through a bind of the
# grep the script calls. The script under test is the REAL one, copied
# byte-for-byte, so this cannot drift into testing a paraphrase.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL="$ROOT/scripts/with-tillandsias-builder.sh"
PASS=0
FAIL=0

ok()   { echo "ok: $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# Run the real script against FABRICATED /etc/os-release and /proc/version.
#
# Both are bash file tests (`[[ -f ]]`, `grep FILE`), so a PATH stub cannot
# reach them — and on a Windows host /etc/os-release genuinely does not exist,
# which made the first version of arm 2 pass through an earlier guard and
# report a repeal that had not happened. The fixture must therefore be built
# by REWRITING the two literal paths in a copy of the real script.
#
# The rewrite is drift-checked: if either substitution stops matching, the test
# FAILS rather than silently exercising an unmodified script — the trap that
# scripts/test-ensure-toolbox-properties.sh:220 already guards against.
run_without_toolbox() {
    local proc_version="$1" os_release="$2"
    local d ; d="$(mktemp -d)"
    printf '%s
' "$proc_version" >"$d/proc-version"
    if [ -n "$os_release" ]; then
        printf '%s
' "$os_release" >"$d/os-release"
    fi

    sed -e "s#/proc/version#$d/proc-version#g"         -e "s#/etc/os-release#$d/os-release#g"         "$REAL" >"$d/under-test.sh"
    if cmp -s "$REAL" "$d/under-test.sh"; then
        echo "FAIL: fixture substitution matched nothing — the test would be exercising the unmodified script" >&2
        rm -rf "$d"
        return 125
    fi

    # No toolbox on PATH, and every skip-guard that could short-circuit the
    # decision explicitly cleared, so each arm reaches the branch it targets.
    PATH="/usr/bin:/bin"     TILLANDSIAS_SKIP_TOOLBOX=     TOOLBOX_PATH=     container=         bash "$d/under-test.sh" true >"$d/out" 2>&1
    local rc=$?
    cat "$d/out"
    rm -rf "$d"
    return $rc
}

FEDORA_OS_RELEASE='NAME="Fedora Linux"
ID=fedora
VERSION_ID=44'

echo "== arm 1: a WSL2 kernel is exempt from the toolbox refusal =="
out="$(run_without_toolbox "Linux version 6.18.33.2-microsoft-standard-WSL2 (root@f1bbfb02316b)" "$FEDORA_OS_RELEASE" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "WSL2 kernel + no toolbox -> pass-through, exit 0"
else
    bad "WSL2 kernel + no toolbox -> exit $rc (the Windows lane is blocked again)"
    echo "$out" | sed 's/^/    /' >&2
fi
if printf '%s' "$out" | grep -q "FATAL: 'toolbox' is not installed"; then
    bad "WSL2 kernel still printed the toolbox FATAL"
else
    ok "WSL2 kernel does not print the toolbox FATAL"
fi

echo "== arm 2 (NEGATIVE CONTROL): a bare Linux host is still refused =="
# This arm is what keeps the 2026-08-26 ruling real. Do not delete it to make
# a change pass.
out="$(run_without_toolbox "Linux version 6.11.3-200.fc40.x86_64 (mockbuild@fedora)" "$FEDORA_OS_RELEASE" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    ok "non-WSL Linux + no toolbox -> still refused, exit $rc"
else
    bad "non-WSL Linux + no toolbox -> exit 0; the no-host-native-fallback ruling has been silently repealed"
fi
if printf '%s' "$out" | grep -q "FATAL: 'toolbox' is not installed"; then
    ok "non-WSL Linux still prints the toolbox FATAL"
else
    bad "non-WSL Linux lost the toolbox FATAL message"
fi

echo "== arm 3: the comment no longer claims the os-release guard covers Windows =="
# The packet is a TRUTHFULNESS packet: the code fix and the comment fix are one
# deliverable, and a future edit that restores the false claim should go red.
if grep -q 'macOS and Windows are the sanctioned exceptions and are handled ABOVE' "$REAL"; then
    bad "the false claim is back: the os-release guard does not cover Windows (it fires only on the Git Bash side)"
else
    ok "the false os-release claim is gone"
fi
if grep -q 'grep -qi microsoft /proc/version' "$REAL"; then
    ok "native WSL detection is present in the real script"
else
    bad "native WSL detection is missing from the real script"
fi

echo
echo "toolbox-refusal-wsl-exception: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    echo "fail:toolbox-refusal-wsl-exception"
    exit 1
fi
echo "ok:toolbox-refusal-wsl-exception:$PASS"
