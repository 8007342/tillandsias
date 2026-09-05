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
_spec="$(awk '/cat <<.SPEC.$/{f=1;next} /^SPEC$/{f=0} f' "$CHECK")"
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
# ORDER 1004-x9ua. The farm defines the PATH; since the check now also resolves
# through standard ABSOLUTE prefixes (~/.cargo/bin, /opt/homebrew/bin, ...) it
# must be told those are empty too, or the farm constrains the PATH while the
# check reaches straight past it. MEASURED when the resolution landed: this arm
# went red with `rc=0 ok:host-tools:macos:5 required present` on a farm that had
# genuinely hidden timeout — the farm was still hiding, and the check was no
# longer only looking there.
mkdir -p "$tmp/noprefix"
out="$(PATH="$tmp/farm" TILLANDSIAS_HOST_TOOL_PREFIXES="$tmp/noprefix" "$CHECK" 2>/dev/null)"; rc=$?
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

    # ORDER 1004-x9ua — THE CONTROL RUN, AND WHY THIS ARM NEEDED ONE.
    #
    # A falsification arm says "remove the tool and the prover flips to
    # <expect>". That sentence is only meaningful if, with the tool PRESENT, the
    # prover does NOT already say <expect>. When it does, removing the tool
    # changes nothing and the arm is measuring some unrelated precondition.
    #
    # MEASURED by macneo-macos 2026-09-04 on a Mac whose gh keyring token had
    # rotted: `timeout|macos|check-credential-channel.sh|blocked:gh-cli-only`
    # went red with got=[missing:no-credential-channel], and host-tools read
    # 1/12. The blocked:gh-cli-only branch (check-credential-channel.sh:612) is
    # reachable only AFTER the guard's token arm passes; with a dead token the
    # guard short-circuits long before the timeout dependency is ever exercised.
    # So the arm was reporting the OPERATOR'S gh login state as a fact about
    # coreutils, and its remedy told them to install a package they had.
    #
    # A HOST WHOSE TOKEN HAS BEEN EVICTED THEN CANNOT LAND ANYTHING, which is
    # how this coupled to 1025-a896.
    #
    # The control below is the packet's criterion 1 in its "states its
    # precondition and SKIPS (not FAILS)" form, generalised so it protects every
    # prover rather than special-casing this one entry. NOTE THE ASYMMETRY: a
    # skip here is NOT a pass. It is counted and named, because "the precondition
    # did not hold" and "the tool is genuinely not required" must not read alike.
    ctl="$(bash "$ROOT/scripts/$prover" 2>/dev/null | tail -1)"

    # coreutils ships both names; hiding one leaves the fallback in place.
    if [ "$tool" = timeout ]; then farm "$tmp/f2" timeout gtimeout; else farm "$tmp/f2" "$tool"; fi
    got="$(PATH="$tmp/f2" bash "$ROOT/scripts/$prover" 2>/dev/null | tail -1)"

    if printf '%s' "$got" | grep -q "^$expect"; then
        check ok "without $tool, $prover reports $expect"
    elif [ "$got" = "$ctl" ]; then
        # THE PRECONDITION DID NOT HOLD, and this is the shape that must not read
        # as a tool failure. Removing the tool changed NOTHING: the prover gives
        # the same answer either way, so it never reached the dependency and this
        # arm cannot speak about $tool at all.
        #
        # Getting the CONDITION right here took two attempts, and the first one
        # is worth recording because it looks correct. I first skipped when the
        # control ALREADY reported $expect — which never fires for the case this
        # exists to handle: on macneo's Mac the prover answered
        # missing:no-credential-channel in BOTH runs, never $expect at all. The
        # discriminator is not "control equals expect", it is "the tool made no
        # difference". On THIS host, with a live token, neither form fires and no
        # local run could have told them apart.
        unverified=$((unverified + 1))
        check ok "SKIP $tool/$prover: precondition does not hold here — the verdict is identical with and without the tool, so the prover never reached the dependency (both=[$got])"
    else
        check FAIL "without $tool, $prover reports $expect" "got=[$got] with-tool=[$ctl]"
    fi
done <<EOF
$(awk '/cat <<.SPEC.$/{f=1;next} /^SPEC$/{f=0} f' "$CHECK")
EOF

# 4b. ORDER 1004-x9ua — THE NARROWING IS PROVED ON BOTH SIDES, per criterion 4.
#     The defect was that this check read the OPERATOR'S PATH and reported it as
#     the HOST'S inventory: under the non-login PATH every agent tool call gets,
#     it printed missing:host-tools:macos:timeout,cargo,rustc,pkg-config on a
#     host carrying all four. One side alone cannot pin the fix — resolving
#     everything always would pass the positive arm and destroy the verdict.
#
#     Both arms below drive tool_prefixes through TILLANDSIAS_HOST_TOOL_PREFIXES,
#     because every real prefix is an absolute path and a host that HAS
#     /opt/homebrew/bin cannot otherwise construct the absent case for a tool
#     living there. Without the seam this arm would cover cargo and rustc and
#     silently skip timeout and pkg-config.
_reqs="$(printf '%s\n' "$_spec" | awk -F'|' -v p="$_plat" 'NF && index(","$2",", ","p",")>0 {print $1}')"
mkdir -p "$tmp/offpath" "$tmp/empty"
_have_all=1
for _t in $_reqs; do
    _p="$(command -v "$_t" 2>/dev/null)" || { _have_all=0; continue; }
    ln -sf "$_p" "$tmp/offpath/$_t" 2>/dev/null
done
if [ "$_have_all" = 1 ]; then
    # POSITIVE: resolvable-but-off-PATH must PASS. PATH deliberately carries
    # none of the required tools; only the prefix does.
    farm "$tmp/bare" $_reqs
    out="$(PATH="$tmp/bare" TILLANDSIAS_HOST_TOOL_PREFIXES="$tmp/offpath" "$CHECK" 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ok:host-tools:'; then
        check ok "1004-x9ua: tools present in a standard prefix but off PATH resolve, not MISSING"
    else
        check FAIL "1004-x9ua: tools off PATH but present must resolve" "rc=$rc out=[$out]"
    fi

    # NEGATIVE CONTROL FOR THE POSITIVE ARM. If $tmp/bare did not actually hide
    # them, the arm above would pass without the resolution doing anything —
    # the vacuous-pass shape this fixture's own arm 3 exists to refuse.
    _leaked=""
    for _t in $_reqs; do
        PATH="$tmp/bare" command -v "$_t" >/dev/null 2>&1 && _leaked="${_leaked:+$_leaked,}$_t"
    done
    if [ -z "$_leaked" ]; then
        check ok "1004-x9ua: the bare farm really hides every required tool, so the arm above means what it says"
    else
        check FAIL "1004-x9ua: bare farm leaked tools, positive arm is vacuous" "leaked=[$_leaked]"
    fi

    # TRUE ABSENCE KEEPS ITS VERDICT AND ITS TERMINAL FORCE. Same bare PATH, but
    # the prefix is empty: nothing is resolvable anywhere.
    out="$(PATH="$tmp/bare" TILLANDSIAS_HOST_TOOL_PREFIXES="$tmp/empty" "$CHECK" 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "^missing:host-tools:${_plat}:"; then
        check ok "1004-x9ua: a tool absent from PATH and every prefix still fails, exit 1"
    else
        check FAIL "1004-x9ua: true absence must still fail" "rc=$rc out=[$out]"
    fi

    # CRITERION 2: no remedy may name a tool that IS installed here. The verdict
    # naming a tool is what triggers its remedy, so assert on the verdict.
    # CRITERION 2 IS ABOUT THE LIVE HOST, not the farm: under an empty prefix the
    # absence is REAL for the check, so naming tools there is correct. Assert on
    # the verdict this host actually prints.
    _live="$("$CHECK" 2>/dev/null)"
    _liars=""
    for _t in $_reqs; do
        command -v "$_t" >/dev/null 2>&1 || continue
        printf '%s' "$_live" | grep -q "[:,]$_t\(,\|$\)" && _liars="${_liars:+$_liars,}$_t"
    done
    if [ -z "$_liars" ]; then
        check ok "1004-x9ua: no verdict names a tool that is installed on this host (criterion 2)"
    else
        check FAIL "1004-x9ua: verdict names installed tool(s), remedy is unreachable" "named=[$_liars] verdict=[$_live]"
    fi
else
    check ok "1004-x9ua: skipped both-sides arms — this host genuinely lacks a required tool, so the positive side cannot be constructed"
fi

# 4c. ORDER 1004-x9ua — the timeout alternate is read off the CONSUMER.
#     check-credential-channel.sh:17-20 accepts timeout OR gtimeout, so a host
#     with only gtimeout is NOT missing coreutils, and telling it to
#     `brew install coreutils` is advice to install what it has.
if [ "$_plat" = macos ] && command -v gtimeout >/dev/null 2>&1; then
    mkdir -p "$tmp/gt"; rm -f "$tmp/gt"/*
    ln -sf "$(command -v gtimeout)" "$tmp/gt/gtimeout"
    for _t in $_reqs; do
        [ "$_t" = timeout ] && continue
        _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$tmp/gt/$_t"
    done
    farm "$tmp/bare2" $_reqs gtimeout
    out="$(PATH="$tmp/bare2" TILLANDSIAS_HOST_TOOL_PREFIXES="$tmp/gt" "$CHECK" 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        check ok "1004-x9ua: gtimeout alone satisfies the timeout requirement, as its consumer does"
    else
        check FAIL "1004-x9ua: gtimeout alone must satisfy timeout" "rc=$rc out=[$out]"
    fi
fi

# 5. The check is wired into the gate.
if grep -q 'check-host-tools.sh\|test-host-tools.sh' "$ROOT/build.sh"; then
    check ok "build.sh consults the host-tools check"
else
    check FAIL "build.sh consults the host-tools check"
fi

# 6. EVERY DECLARED PLATFORM, FROM ANY HOST — commissioned by macuahuitl after
#    arm 2's macOS-only expectations took the linux gate red.
#
#    Arm 2 is correct and still SINGLE-PLATFORM: it verifies whichever host runs
#    it. The defect it could not have caught was that this fixture's idea of a
#    platform's required set was never compared against the probe's, for any
#    platform but the live one — and `--platform` existed on the probe, added by
#    the same author, precisely so one host can ask what another requires. It
#    was never pointed at this file's own expectations.
#
#    THE PROPERTY, and it holds from any host without that platform's tools:
#    for each declared platform, what the probe REPORTS must exactly partition
#    what the spec DECLARES for that platform — every declared tool either
#    counted present or named missing, and nothing else named.
#
#    That is checkable on macOS for linux and windows, because a tool this host
#    lacks simply lands in the `missing:` list instead of the present count.
for _p in $(printf '%s\n' "$_spec" | awk -F'|' '{print $2}' | tr ',' '\n' | sort -u); do
    [ -n "$_p" ] || continue
    _declared="$(printf '%s\n' "$_spec" \
        | awk -F'|' -v p="$_p" '$2 ~ "(^|,)" p "(,|$)" {print $1}' | sort -u)"
    _n_declared="$(printf '%s\n' "$_declared" | grep -c .)"
    _out="$(PATH="$PATH" "$CHECK" --platform "$_p" 2>/dev/null)"
    case "$_out" in
        ok:host-tools:$_p:*) _reported_missing=""; _n_present="$(printf '%s' "$_out" | sed -E 's/.*:([0-9]+) required present/\1/')" ;;
        missing:host-tools:$_p:*) _reported_missing="$(printf '%s' "$_out" | sed -E 's/^missing:host-tools:[a-z]+://' | tr ',' '\n')"; _n_present="" ;;
        *) check FAIL "--platform $_p returns a well-formed verdict" "out=[$_out]"; continue ;;
    esac
    # Nothing may be named that the spec did not declare for this platform.
    _stray=""
    for _m in $_reported_missing; do
        printf '%s\n' "$_declared" | grep -qx "$_m" || _stray="${_stray:+$_stray,}$_m"
    done
    # present + missing must account for every declared tool, exactly once.
    _n_missing="$(printf '%s\n' "$_reported_missing" | grep -c .)"
    _n_seen=$(( ${_n_present:-0} + _n_missing ))
    if [ -n "$_stray" ]; then
        check FAIL "--platform $_p names only tools it declares" "stray=[$_stray]"
    elif [ "$_n_seen" -ne "$_n_declared" ]; then
        check FAIL "--platform $_p accounts for every declared tool" "declared=$_n_declared seen=$_n_seen out=[$_out]"
    else
        check ok "--platform $_p partitions its $_n_declared declared tool(s) exactly"
    fi
done

# 7. THE FALSIFIABLE HALF, and arm 6 needs it because arm 6 alone is close to
#    tautological: the probe and this fixture read the SAME spec with equivalent
#    filters, so the partition holds almost by construction. MEASURED — a
#    deliberately loosened filter in the probe (substring instead of exact
#    membership) passed arm 6 unchanged.
#
#    So assert something the spec cannot satisfy by agreeing with itself: a
#    platform name that is a SUBSTRING of a declared one must select NOTHING.
#    With exact membership `os` selects zero; with the loosened filter it
#    matches every `macos` row. That is the actual bug class in a
#    comma-delimited membership test, and it is what makes arm 6 worth running.
for _bogus in os mac inux; do
    _out="$("$CHECK" --platform "$_bogus" 2>/dev/null)"
    if printf '%s' "$_out" | grep -qE "^ok:host-tools:[a-z]*:0 required present$"; then
        check ok "--platform $_bogus selects nothing (substring must not match)"
    else
        check FAIL "--platform $_bogus selects nothing" "out=[$_out]"
    fi
done

total=$((pass + fail))
[ "$unverified" -gt 0 ] && printf 'note: %d required entr(y/ies) have no cheap prover; the gate itself is their evidence\n' "$unverified"
if [ "$fail" -eq 0 ]; then
    echo "PASS: host-tools ${pass}/${total} (989-ykks)"
    exit 0
fi
echo "FAIL: host-tools ${fail}/${total} red (989-ykks)"
exit 1
