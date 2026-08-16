#!/usr/bin/env bash
# @trace order:756-rfdr, spec:ci-release
set -uo pipefail

# Fixture for scripts/check-release-asset-integrity.sh (order 756-rfdr).
#
# WHAT IT GUARDS. On the published v0.4.260815.1, install-windows.ps1 had no
# cosign bundle and appeared in no SHA256SUMS — the only asset of 29 with no way
# for a downloader to verify it, and the one README.md tells Windows users to
# pipe straight into their shell. It shipped bare for two independent reasons,
# neither of which produced any output: the Windows job's signing loop was an
# ALLOW-LIST, and the step staging the installer ran after it.
#
# WHY THE CHECK IS NOT "COUNT UNSIGNED ASSETS". Four of the five bundle-less
# assets in that release were legitimately covered — named in a signed manifest,
# or themselves a manifest whose every entry is signed. A gate that flagged all
# five would cry wolf four times and get switched off. Scenario 3 is that
# negative control and it is the reason this file exists rather than a one-line
# `ls | grep -c`.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-release-asset-integrity.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/release-asset-integrity-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failures=()
run() {
    local name="$1" want_rc="$2" want="$3" dir="$4"
    local rc=0 out
    out="$("$CHECK" "$dir" 2>&1)" || rc=$?
    if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q "$want"; then
        echo "PASS  $name"
    else
        echo "FAIL  $name: want rc=$want_rc matching [$want], got rc=$rc [$out]"
        failures+=("$name")
    fi
}

mk() { mkdir -p "$1"; }
sig() { : > "$1.cosign.bundle"; }   # presence is what the rule reads

# ── 1. the shipped defect: a standalone script with no bundle and in no manifest
d="$work/bare-installer"; mk "$d"; cd "$d"
printf 'zip\n'   > tillandsias-windows-x64.zip
printf 'script\n' > install-windows.ps1
sha256sum tillandsias-windows-x64.zip > SHA256SUMS-windows
sig SHA256SUMS-windows
cd "$ROOT"
run "1 bare installer is caught" 1 "install-windows.ps1 has no integrity path" "$d"

# ── 2. the fix: the installer is BOTH signed and named in the signed manifest
d="$work/fixed"; mk "$d"; cd "$d"
printf 'zip\n'    > tillandsias-windows-x64.zip
printf 'script\n' > install-windows.ps1
sha256sum tillandsias-windows-x64.zip install-windows.ps1 > SHA256SUMS-windows
sig SHA256SUMS-windows; sig tillandsias-windows-x64.zip; sig install-windows.ps1
cd "$ROOT"
run "2 signed + manifested passes" 0 "ok:release-asset-integrity:3 of 3 checked" "$d"

# ── 3. NEGATIVE CONTROL: transitive coverage must NOT be flagged.
# Neither the zip nor the exe carries its own bundle; both are named in a
# manifest that IS signed. This is four-fifths of the real release and the
# case a naive unsigned-count would fail on.
d="$work/transitive"; mk "$d"; cd "$d"
printf 'zip\n' > tillandsias-windows-x64.zip
printf 'exe\n' > tillandsias-tray.exe
sha256sum tillandsias-windows-x64.zip tillandsias-tray.exe > SHA256SUMS-windows
sig SHA256SUMS-windows
cd "$ROOT"
run "3 transitively covered not flagged" 0 "ok:release-asset-integrity:3 of 3 checked" "$d"

# ── 4. a manifest with NO signature of its own, whose entries are each signed,
# is still trustworthy — that is the real SHA256SUMS on the Linux half.
d="$work/manifest-of-signed"; mk "$d"; cd "$d"
printf 'a\n' > install.sh
printf 'b\n' > tillandsias-linux-x86_64
sha256sum install.sh tillandsias-linux-x86_64 > SHA256SUMS
sig install.sh; sig tillandsias-linux-x86_64
cd "$ROOT"
run "4 manifest of signed files is covered" 0 "ok:release-asset-integrity:3 of 3 checked" "$d"

# ── 5. an UNSIGNED manifest naming UNSIGNED files vouches for nothing.
# Without this the check could be satisfied by adding a plain checksum file,
# which is a claim rather than evidence.
d="$work/unsigned-manifest"; mk "$d"; cd "$d"
printf 'a\n' > install-windows.ps1
sha256sum install-windows.ps1 > SHA256SUMS-windows
cd "$ROOT"
run "5 unsigned manifest vouches for nothing" 1 "install-windows.ps1 has no integrity path" "$d"

# ── 6. a newly-added script must be caught, which is the regression this is for:
# the old workflow's allow-list meant anything added later was unsigned silently.
d="$work/new-script"; mk "$d"; cd "$d"
printf 'zip\n' > tillandsias-windows-x64.zip
sha256sum tillandsias-windows-x64.zip > SHA256SUMS-windows
sig SHA256SUMS-windows
printf 'brand new\n' > setup-extras.ps1
cd "$ROOT"
run "6 newly added asset is caught" 1 "setup-extras.ps1 has no integrity path" "$d"

if [ "${#failures[@]}" -gt 0 ]; then
    echo "FAIL: ${#failures[@]} scenario(s): ${failures[*]}"
    exit 1
fi
echo "ok:release-asset-integrity-fixture:6"
exit 0
