#!/usr/bin/env bash
# @trace spec:meta-orchestration
# @trace order:989-ykks
#
# Fixture for check-host-tools.sh.
#
# THE PACKET'S SECOND CRITERION is that this be verified on a host that is
# ACTUALLY MISSING SOMETHING, "not only on a host where everything is present —
# the whole defect is that a complete host cannot detect this". A complete host
# can only satisfy that by CONSTRUCTING absence, and doing so soundly is
# harder than it looks:
#
#   * A non-executable shim in a PATH prefix DOES NOT HIDE ANYTHING. `command -v`
#     skips the non-executable entry and finds the real binary further along
#     PATH. Measured here 2026-09-03 — a first attempt at this fixture used
#     shims, reported "jq is not required", and was proving nothing at all while
#     looking exactly like a measurement.
#   * Removing a PATH DIRECTORY removes unrelated siblings. Dropping
#     /opt/homebrew/bin to hide `timeout` also hides `gh`, and the resulting
#     failure cannot be attributed.
#
# So isolation is a SYMLINK FARM: a directory holding exactly the tools that
# should be present, used as the entire PATH. One variable moves at a time.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-host-tools.sh"
[ -x "$CHECK" ] || { echo "blocked:no-check:$CHECK"; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/host-tools.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; unverified=0
check() {
    if [ "$1" = ok ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$2"
    else fail=$((fail + 1)); printf 'FAIL %s\n' "$2"; [ -n "${3:-}" ] && printf '     %s\n' "$3"; fi
}

# Build a farm of everything the checks might reach, minus the named tools.
farm() {
    local dir="$1"; shift
    rm -rf "$dir"; mkdir -p "$dir"
    local t p skip
    for t in git jq cargo rustc rustup gh timeout gtimeout pkg-config curl shasum sha256sum \
             plutil codesign xcrun podman python3 ruby awk sed grep tar gzip xz find sort head \
             tail wc basename dirname mktemp chmod cp mv rm ln ls cat printf date hostname \
             uname id stat openssl ssh-keygen nc pgrep lsof file diff comm tr cut env bash sh; do
        for skip in "$@"; do [ "$t" = "$skip" ] && continue 2; done
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$dir/$t" 2>/dev/null
    done
}

# 1. This host, as it is. Whatever the answer, it must be well-formed.
out="$("$CHECK" 2>/dev/null)"; rc=$?
if printf '%s' "$out" | grep -qE '^(ok:host-tools:[a-z]+:[0-9]+ required present|missing:host-tools:[a-z]+:[a-z0-9,.-]+)$'; then
    check ok "live verdict is well-formed: $out"
else
    check FAIL "live verdict is well-formed" "rc=$rc out=[$out]"
fi

# 2. CONSTRUCTED ABSENCE — the criterion. Hide a required tool and require the
#    check to NAME it. Uses the farm, so only that one tool differs.
#
#    PLATFORM-AWARE (order 989-ykks follow-up, macuahuitl 2026-09-03). This arm
#    used to hide `timeout`/`gtimeout` and grep for a literal
#    `missing:host-tools:macos:`. Both halves are macOS-only: `timeout` is
#    REQUIRED on macos and not on linux, so hiding it on linux correctly changes
#    nothing, and the verdict names the live platform rather than `macos`. On
#    linux the arm therefore read rc=0 / "3 required present" and failed, taking
#    ./build.sh --check red for every linux host.
#
#    That is this packet's OWN thesis turned on its fixture: the authoring host's
#    build is a smaller universe than the fleet's. Hide something the CURRENT
#    platform actually requires, and assert the CURRENT platform's verdict.
case "$(uname -s)" in
    Darwin) _absent_tool=timeout; _absent_extra=gtimeout ;;
    *)      _absent_tool=cargo;   _absent_extra=cargo ;;
esac
_plat="$(uname -s | tr 'A-Z' 'a-z' | sed 's/darwin/macos/')"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) _plat=windows ;; esac
farm "$tmp/farm" "$_absent_tool" "$_absent_extra"
out="$(PATH="$tmp/farm" "$CHECK" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "^missing:host-tools:${_plat}:.*${_absent_tool}"; then
    check ok "a genuinely absent required tool is named, exit 1 ($_plat/$_absent_tool)"
else
    check FAIL "a genuinely absent required tool is named ($_plat/$_absent_tool)" "rc=$rc out=[$out]"
fi

# 3. NEGATIVE CONTROL FOR THE ISOLATION ITSELF. If the farm did not actually
#    hide the tool, arm 2 would pass for the wrong reason — and that is not
#    hypothetical, it is what the shim approach did. Assert the absence is real.
if PATH="$tmp/farm" command -v "$_absent_tool" >/dev/null 2>&1; then
    check FAIL "the farm actually hides the tool (arm 2 would be vacuous)"
else
    check ok "the farm actually hides the tool, so arm 2 means what it says"
fi

# 4. EVERY CLAIM WITH A PROVER IS FALSIFIED. This is what stops the required
#    list from becoming the same unmaintained prose it replaces: an entry that
#    is not actually required fails HERE.
while IFS='|' read -r tool platforms prover expect why remedy; do
    [ -n "$tool" ] || continue
    case ",$platforms," in *",$(uname -s | tr 'A-Z' 'a-z' | sed 's/darwin/macos/'),"*) ;; *) continue ;; esac
    if [ "$prover" = "-" ]; then
        unverified=$((unverified + 1)); continue
    fi
    [ -x "$ROOT/scripts/$prover" ] || { check FAIL "prover for $tool exists: $prover"; continue; }
    # coreutils ships both names; hiding one leaves the fallback in place.
    if [ "$tool" = timeout ]; then farm "$tmp/f2" timeout gtimeout; else farm "$tmp/f2" "$tool"; fi
    got="$(PATH="$tmp/f2" bash "$ROOT/scripts/$prover" 2>/dev/null | tail -1)"
    if printf '%s' "$got" | grep -q "^$expect"; then
        check ok "without $tool, $prover reports $expect"
    else
        check FAIL "without $tool, $prover reports $expect" "got=[$got]"
    fi
done <<EOF
$(awk '/cat <<.SPEC.$/{f=1;next} /^SPEC$/{f=0} f' "$CHECK")
EOF

# 5. The check is wired into the gate.
if grep -q 'check-host-tools.sh\|test-host-tools.sh' "$ROOT/build.sh"; then
    check ok "build.sh consults the host-tools check"
else
    check FAIL "build.sh consults the host-tools check"
fi

total=$((pass + fail))
[ "$unverified" -gt 0 ] && printf 'note: %d required entr(y/ies) have no cheap prover; the gate itself is their evidence\n' "$unverified"
if [ "$fail" -eq 0 ]; then
    echo "PASS: host-tools ${pass}/${total} (989-ykks)"
    exit 0
fi
echo "FAIL: host-tools ${fail}/${total} red (989-ykks)"
exit 1
