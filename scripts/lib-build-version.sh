# shellcheck shell=bash
# @trace order:1238-b825, spec:ci-release
#
# lib-build-version.sh — the version label a LOCAL build shows, derived from
# the build clock. It never writes VERSION.
#
# THE DEFECT (1238-b825, operator-found 2026-09-17). VERSION is epoch-anchored
# CalVer, <years since 1970>.<month>.<day>.<build>, so the version IS the date.
# Local builds read VERSION and stamped whatever date the last bump left there:
# a 2026-09-17 build shipped as 56.9.13.1, four days stale, and two builds on
# different days produced the same tarball name.
#
# THE RULING (coordinator, 2026-09-28): DERIVE, NEVER WRITE VERSION. A build
# whose VERSION date is not today labels itself `<VERSION>+built.<today>`, which
# is SemVer build metadata, and says so. Refusing instead would push people into
# hand bumps in ordinary commits, which is the 702-eusw P0. The install target's
# autoincrement stays the only local VERSION writer, and release CI keeps
# refusing a VERSION mismatch.
#
# WHERE THE LABEL GOES, AND WHERE IT MUST NOT — do not "fix" the second list:
#   label:  the tray's --version line, the tray tarball name, the build log.
#   VERSION unchanged, because each of these is an identifier compared for
#   equality or constrained in form:
#     * Info.plist CFBundleVersion / CFBundleShortVersionString: Apple requires
#       the numeric dotted form, and `+built…` is not one.
#     * the tray's WORKSPACE_VERSION: pty_vsock_bridge compares it to the
#       guest's build_version, and the control channel keys on it.
#     * guest binaries' embedded version: the same equality from the guest side,
#       and build-guest-binaries.sh --verify checks it against VERSION.
#     * image tags (tillandsias-<img>:v<VERSION>): the tray finds its images by
#       its own version, and `+` is not a legal OCI tag character.
#
# A RELEASE build is exempt: TILLANDSIAS_RELEASE_BUILD=1, which only
# .github/workflows/release.yml sets, stamps VERSION verbatim. A published
# artifact is named by its release version, and release CI already refuses a
# VERSION mismatch. Without the exemption, a cut crossing UTC midnight would
# publish a `+built` tarball.
#
# TILLANDSIAS_BUILD_DATE_OVERRIDE=<Y.M.D in the same epoch CalVer, e.g. 56.9.17>
# stands in for the clock (the fixture's stub clock).

# build_today_calver -> today's UTC date as <years since 1970>.<month>.<day>
build_today_calver() {
    if [ -n "${TILLANDSIAS_BUILD_DATE_OVERRIDE:-}" ]; then
        printf '%s\n' "$TILLANDSIAS_BUILD_DATE_OVERRIDE"
        return 0
    fi
    local y m d
    y="$(date -u +%Y)"; m="$(date -u +%m)"; d="$(date -u +%d)"
    printf '%d.%d.%d\n' "$((10#$y - 1970))" "$((10#$m))" "$((10#$d))"
}

# build_version_label <VERSION> -> VERSION if its date is today, else
# VERSION+built.<today>; a stale date also prints one note line on stderr.
build_version_label() {
    local version="$1" today vdate
    if [ "${TILLANDSIAS_RELEASE_BUILD:-}" = "1" ]; then
        printf '%s\n' "$version"
        return 0
    fi
    today="$(build_today_calver)"
    vdate="${version%.*}"     # 56.9.13.1 -> 56.9.13
    if [ "$vdate" = "$today" ]; then
        printf '%s\n' "$version"
    else
        echo "note:build-version:stale-date:VERSION=$version:built=$today — labelled $version+built.$today; VERSION is not written (1238-b825)" >&2
        printf '%s+built.%s\n' "$version" "$today"
    fi
}
