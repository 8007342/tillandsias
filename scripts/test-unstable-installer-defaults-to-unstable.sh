#!/usr/bin/env bash
# @trace order:1369-sjbc, spec:ci-release
#
# Fixture for 1369-sjbc: an installer fetched from the UNSTABLE release must
# install unstable with TILLANDSIAS_CHANNEL unset, and the stable copy must not.
#
# Builds a fake artifact directory from the REAL installers in scripts/, stages
# it through scripts/stage-unstable-installers.sh exactly as the release jobs do,
# then RUNS each installer with TILLANDSIAS_INSTALL_RESOLVE_ONLY=1 (it prints its
# resolved-channel line and exits before any host step) and reads the base URL.
#
#   A  the unstable copy of install.sh / install-macos.sh resolves
#      /releases/download/unstable with the channel unset
#   B  CONTROL: the untouched (stable) copies still resolve /releases/latest/download,
#      so the fix cannot be "always unstable"
#   C  an explicit TILLANDSIAS_CHANNEL=stable on the unstable copy still wins
#   D  install-windows.ps1: run through pwsh where one exists; otherwise the
#      rewritten default line is asserted and the RUN is a named skip
#   E  the rewritten SHA256SUMS-windows verifies; a CRLF .ps1 keeps its CRs
#   F  exactly the files that were signed in the source are listed for re-signing
#   G  refusals: a missing default line, and a directory with no installer
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$REPO_ROOT/scripts/stage-unstable-installers.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/unstable-installer-fixture.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
UNSTABLE_BASE="https://github.com/8007342/tillandsias/releases/download/unstable"
STABLE_BASE="https://github.com/8007342/tillandsias/releases/latest/download"
fails=0
ran=0
skipped=0

fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# resolved <installer> [env...]: the installer's resolved-channel line.
resolved() {
    local inst="$1"; shift
    env -u TILLANDSIAS_CHANNEL -u TILLANDSIAS_RELEASE_BASE -u TILLANDSIAS_VERSION \
        "$@" TILLANDSIAS_INSTALL_RESOLVE_ONLY=1 bash "$inst" 2>&1
}

expect_base() {
    # expect_base <name> <want-base> <want-source> <installer> [env...]
    local name="$1" want="$2" src="$3" inst="$4"; shift 4
    local got
    got="$(resolved "$inst" "$@")"
    ran=$((ran + 1))
    case "$got" in
        *"resolved-channel: "*"($src) base: $want") ;;
        *) fail "$name — got '$got', want base $want from '$src'" ;;
    esac
}

src="$TMP/release-artifacts"
mkdir -p "$src"
cp "$REPO_ROOT/scripts/install.sh" "$REPO_ROOT/scripts/install-macos.sh" \
    "$REPO_ROOT/scripts/install-windows.ps1" "$src/"
printf 'tray\n' > "$src/tillandsias-tray.exe"
( cd "$src" && sha256sum install-windows.ps1 tillandsias-tray.exe > SHA256SUMS-windows )
for b in install.sh install-macos.sh install-windows.ps1 SHA256SUMS-windows tillandsias-tray.exe; do
    : > "$src/$b.cosign.bundle"
done

out="$(bash "$STAGE" "$src" "$TMP/unstable" 2>&1)"
rc=$?
ran=$((ran + 1))
case "$out" in
    *"ok:stage-unstable-installers:rewritten=3 resign=4"*) [ "$rc" -eq 0 ] || fail "stage exited $rc on ok" ;;
    *) fail "stage — got '$out' (rc=$rc)" ;;
esac

# F: the four signed files that changed, and nothing else.
ran=$((ran + 1))
want_resign="$(printf 'resign:%s\n' install.sh install-macos.sh install-windows.ps1 SHA256SUMS-windows | LC_ALL=C sort)"
got_resign="$(grep '^resign:' <<<"$out" | LC_ALL=C sort)"
[ "$got_resign" = "$want_resign" ] || fail "F resign list — got '$got_resign'"
[ -e "$TMP/unstable/tillandsias-tray.exe.cosign.bundle" ] || fail "F an unchanged file lost its bundle"
[ ! -e "$TMP/unstable/install.sh.cosign.bundle" ] || fail "F a stale bundle was left beside a rewritten installer"

# A and B, both POSIX installers.
for inst in install.sh install-macos.sh; do
    expect_base "A $inst unstable copy, channel unset" "$UNSTABLE_BASE" \
        "default of this installer copy" "$TMP/unstable/$inst"
    expect_base "B $inst stable copy, channel unset (control)" "$STABLE_BASE" \
        "default of this installer copy" "$src/$inst"
    expect_base "C $inst unstable copy, explicit stable wins" "$STABLE_BASE" \
        "TILLANDSIAS_CHANNEL" "$TMP/unstable/$inst" TILLANDSIAS_CHANNEL=stable
done

# D: the Windows installer.
ran=$((ran + 1))
n="$(tr -d '\r' < "$TMP/unstable/install-windows.ps1" | grep -cx "\$DefaultChannel = 'unstable'")" || true
[ "$n" = "1" ] || fail "D install-windows.ps1 unstable default line count $n, want 1"
PWSH="$(command -v pwsh || command -v powershell || true)"
if [ -n "$PWSH" ]; then
    for pair in "unstable:$UNSTABLE_BASE:$TMP/unstable" "stable:$STABLE_BASE:$src"; do
        dir="${pair##*:}"
        rest="${pair%:*}"
        want="${rest#*:}"
        ps1="$dir/install-windows.ps1"
        command -v cygpath >/dev/null 2>&1 && ps1="$(cygpath -w "$ps1")"
        got="$(env -u TILLANDSIAS_CHANNEL -u TILLANDSIAS_VERSION TILLANDSIAS_INSTALL_RESOLVE_ONLY=1 \
            "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$ps1" 2>&1 | tr -d '\r')"
        ran=$((ran + 1))
        case "$got" in
            *"resolved-channel: "*"(default of this installer copy) base: $want"*) ;;
            *) fail "D install-windows.ps1 ${pair%%:*} copy — got '$got'" ;;
        esac
    done
else
    echo "skip:unstable-installer-fixture:D-run:no-pwsh-on-this-host" >&2
    skipped=$((skipped + 1))
fi

# E: the manifest verifies, and a CRLF .ps1 is rewritten with its CRs kept.
ran=$((ran + 1))
( cd "$TMP/unstable" && sha256sum -c --quiet SHA256SUMS-windows ) >/dev/null 2>&1 \
    || fail "E the rewritten SHA256SUMS-windows does not verify"
crlf="$TMP/crlf-src"
mkdir -p "$crlf"
sed 's/$/\r/' "$REPO_ROOT/scripts/install-windows.ps1" > "$crlf/install-windows.ps1"
( cd "$crlf" && sha256sum -b install-windows.ps1 > SHA256SUMS-windows )
bash "$STAGE" "$crlf" "$TMP/crlf-dst" >/dev/null 2>&1 || fail "E CRLF staging refused"
ran=$((ran + 1))
cr_before="$(tr -cd '\r' < "$crlf/install-windows.ps1" | wc -c)"
cr_after="$(tr -cd '\r' < "$TMP/crlf-dst/install-windows.ps1" | wc -c)"
[ "$cr_before" -eq "$cr_after" ] || fail "E CRLF — $cr_before CRs before, $cr_after after"
( cd "$TMP/crlf-dst" && sha256sum -c --quiet SHA256SUMS-windows ) >/dev/null 2>&1 \
    || fail "E the binary-form (*name) manifest does not verify after the rewrite"

# G: refusals.
broken="$TMP/broken-src"
mkdir -p "$broken"
sed 's/^DEFAULT_CHANNEL="stable"$/DEFAULT_CHANNEL=stable/' "$REPO_ROOT/scripts/install.sh" > "$broken/install.sh"
if grep -qx 'DEFAULT_CHANNEL="stable"' "$broken/install.sh"; then
    fail "G the sabotage did not land: the default line is still present"
fi
ran=$((ran + 1))
got="$(bash "$STAGE" "$broken" "$TMP/broken-dst" 2>/dev/null)"
[ "$got" = "refused:stage-unstable-installers:default-line-count:install.sh:0" ] \
    || fail "G a missing default line — got '$got'"
empty="$TMP/empty-src"
mkdir -p "$empty"
printf 'x\n' > "$empty/tillandsias-linux-x86_64"
ran=$((ran + 1))
got="$(bash "$STAGE" "$empty" "$TMP/empty-dst" 2>/dev/null)"
[ "$got" = "refused:stage-unstable-installers:no-installer-in:$empty" ] \
    || fail "G no installer — got '$got'"

if [ "$fails" -ne 0 ]; then
    echo "refused:unstable-installer-fixture:failed=$fails ran=$ran skipped=$skipped"
    exit 1
fi
echo "ok:unstable-installer-fixture:ran=$ran skipped=$skipped"
