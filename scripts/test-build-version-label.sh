#!/usr/bin/env bash
# @trace order:1238-b825, spec:ci-release
#
# Fixture for scripts/lib-build-version.sh and the three local build paths
# (order 1238-b825). Each path is asked, BEHAVIOURALLY, what it would stamp:
# `<script> --print-version`, run from a scratch copy whose VERSION is the
# measured case, under a stub clock (TILLANDSIAS_BUILD_DATE_OVERRIDE).
#
#   1. the measured case: VERSION 56.9.13.1 built on 56.9.17 — all THREE paths
#      (build-macos-tray, build-image, build-guest-binaries) print
#      56.9.13.1+built.56.9.17, and each says so on stderr;
#   2. same day: VERSION 56.9.17.3 built on 56.9.17 is unchanged, and silent;
#   3. two UTC days give two labels, hence two tray tarball names;
#   4. VERSION is never written: its bytes are identical afterwards;
#   5. the real clock: with no override, today's epoch CalVer is computed
#      from `date -u` (years since 1970), so a same-day VERSION is unchanged;
#   7. a RELEASE build (TILLANDSIAS_RELEASE_BUILD=1) stamps VERSION verbatim on
#      a later day, since the artifact is named by its release version, and
#      the release workflow's tray step sets it;
#   6. REPRESENTATION CHECKS (source, named as such — these outputs exist only
#      in a full build): the tray tarball name uses the label, and Info.plist
#      keeps VERSION, since Apple's CFBundleVersion must be numeric-dotted.
#
# PRE-FIX RESULT: FAILS — no path had --print-version or any date check, and
# a 2026-09-17 build shipped as 56.9.13.1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=7
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

PATHS="build-macos-tray.sh build-image.sh build-guest-binaries.sh"
for s in lib-build-version.sh $PATHS; do
    [ -f "$ROOT/scripts/$s" ] || { echo "fail:build-version-label-fixture:0/$total ($s missing)"; exit 1; }
done

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/build-version.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

scratch() { # scratch <name> <VERSION> -> a root holding the scripts and VERSION
    local r="$W/$1"
    mkdir -p "$r/scripts"
    for s in lib-build-version.sh $PATHS; do cp "$ROOT/scripts/$s" "$r/scripts/"; done
    printf '%s\n' "$2" > "$r/VERSION"
    echo "$r"
}
# ask <root> <script> <date> -> "stdout|stderr"
ask() {
    local out err
    err="$W/err.$$"
    out="$(cd / && TILLANDSIAS_BUILD_DATE_OVERRIDE="$3" bash "$1/scripts/$2" --print-version 2>"$err")"
    printf '%s|%s' "$out" "$(cat "$err")"
}

# 1 — the measured case, on all three paths.
R="$(scratch one 56.9.13.1)"; good=0; detail=""
for s in $PATHS; do
    a="$(ask "$R" "$s" 56.9.17)"
    if [ "${a%%|*}" = "56.9.13.1+built.56.9.17" ] && grep -q 'note:build-version:stale-date:VERSION=56.9.13.1:built=56.9.17' <<<"${a#*|}"; then
        good=$((good+1))
    else
        detail="$detail $s=[${a%%|*}]"
    fi
done
[ "$good" -eq 3 ] && ok "arm 1: all 3 build paths print 56.9.13.1+built.56.9.17 for the measured case, and note it" \
    || bad "arm 1: $good/3 —$detail"

# 2 — same day: unchanged and silent.
R="$(scratch two 56.9.17.3)"; good=0; detail=""
for s in $PATHS; do
    a="$(ask "$R" "$s" 56.9.17)"
    if [ "$a" = "56.9.17.3|" ]; then good=$((good+1)); else detail="$detail $s=[$a]"; fi
done
[ "$good" -eq 3 ] && ok "arm 2: a same-day VERSION is printed unchanged, with no note, on all 3 paths" \
    || bad "arm 2: $good/3 —$detail"

# 3 — two UTC days, two labels, two tarball names.
R="$(scratch three 56.9.13.1)"
l1="$(ask "$R" build-macos-tray.sh 56.9.17)"; l1="${l1%%|*}"
l2="$(ask "$R" build-macos-tray.sh 56.9.18)"; l2="${l2%%|*}"
t1="tillandsias-tray-${l1}-macos-arm64.tar.gz"; t2="tillandsias-tray-${l2}-macos-arm64.tar.gz"
[ -n "$l1" ] && [ "$t1" != "$t2" ] && ok "arm 3: builds on 56.9.17 and 56.9.18 name $t1 and $t2" \
    || bad "arm 3: [$t1] vs [$t2]"

# 4 — VERSION is never written.
R="$(scratch four 56.9.13.1)"
before="$(cksum < "$R/VERSION")"
for s in $PATHS; do ask "$R" "$s" 56.9.17 >/dev/null; done
after="$(cksum < "$R/VERSION")"
[ "$before" = "$after" ] && ok "arm 4: VERSION's bytes are identical after all 3 paths ran (never written)" \
    || bad "arm 4: VERSION changed: $before -> $after"

# 5 — the real clock.
y="$(date -u +%Y)"; m="$(date -u +%m)"; d="$(date -u +%d)"
today="$((10#$y - 1970)).$((10#$m)).$((10#$d))"
R="$(scratch five "$today.1")"
a="$(cd / && env -u TILLANDSIAS_BUILD_DATE_OVERRIDE bash "$R/scripts/build-macos-tray.sh" --print-version 2>/dev/null)"
[ "$a" = "$today.1" ] && ok "arm 5: with the real clock, today's VERSION ($today.1) is unchanged" \
    || bad "arm 5: expected $today.1, got [$a]"

# 6 — representation checks (source): only a full build produces these.
T="$ROOT/scripts/build-macos-tray.sh"
tar_line="$(grep -E '^TAR_NAME=' "$T")"
plist_line="$(grep -E 's/@VERSION@/' "$T")"
if grep -q 'BUILD_LABEL' <<<"$tar_line" && grep -q '\${VERSION}' <<<"$plist_line" && ! grep -q 'LABEL' <<<"$plist_line"; then
    ok "arm 6 (representation): the tarball name uses BUILD_LABEL; Info.plist keeps \${VERSION}"
else
    bad "arm 6 (representation): tar=[$tar_line] plist=[$plist_line]"
fi

# 7 — a release build is exempt, and the release workflow says it is one.
R="$(scratch seven 56.9.13.1)"
a="$(cd / && TILLANDSIAS_RELEASE_BUILD=1 TILLANDSIAS_BUILD_DATE_OVERRIDE=56.9.17 bash "$R/scripts/build-macos-tray.sh" --print-version 2>/dev/null)"
wf="$ROOT/.github/workflows/release.yml"
step="$(awk '/name: Build Tillandsias.app \+ tarball/{f=1} f{print} f&&/run: scripts\/build-macos-tray.sh/{exit}' "$wf" 2>/dev/null)"
if [ "$a" = "56.9.13.1" ] && grep -q 'TILLANDSIAS_RELEASE_BUILD: "1"' <<<"$step"; then
    ok "arm 7: a release build stamps 56.9.13.1 verbatim on 56.9.17, and release.yml's tray step sets it"
else
    bad "arm 7: release label=[$a]; release.yml step=[$step]"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:build-version-label-fixture:$pass/$total"
    exit 0
fi
echo "fail:build-version-label-fixture:$pass/$total"
exit 1
