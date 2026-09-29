#!/usr/bin/env bash
# @trace order:792-7bt5, spec:default-image
#
# test-forge-localization-staged.sh — every localized asset the forge
# DISPATCHES to is STAGED by both image paths (792-7bt5: 440 lines of
# translated help lived outside the build context and were staged by nothing,
# and the nix path staged 2 of 17 locale bundles and no help at all).
#   1 each images/default/help-<xx>.sh is COPYed by the Containerfile and cp'd by flake.nix
#   2 help.sh dispatches to help-${_LOCALE}.sh under the directory both paths stage into
#   3 flake.nix stages EVERY locale bundle (a glob), not a hand list
#   4 no stray copy of the help dispatcher exists outside images/default
# Proof in a built artifact (ls inside the image) was run by hand on yoga
# 2026-09-29; this pins the staging so a new translation cannot ship unstaged.
set -uo pipefail
ROOT="${TILLANDSIAS_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CF="$ROOT/images/default/Containerfile"
FL="$ROOT/flake.nix"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

n=0
miss=0
for f in "$ROOT"/images/default/help-*.sh; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"; n=$((n + 1))
    # b is a word on a COPY line: right after `COPY ` or after whitespace.
    /usr/bin/grep -qE "^COPY( |.*[[:space:]])${b//./\.}([[:space:]]|$)" "$CF" \
        || { bad "1: Containerfile does not COPY $b"; miss=$((miss + 1)); }
    /usr/bin/grep -qF "/usr/local/share/tillandsias/$b" "$FL" \
        || { bad "1: flake.nix does not stage $b"; miss=$((miss + 1)); }
done
if [ "$n" -lt 4 ]; then
    bad "1: found $n translated help files under images/default (want >= 4)"
elif [ "$miss" -eq 0 ]; then
    ok "1: $n translated help files, each staged by both paths"
fi

/usr/bin/grep -qF '/usr/local/share/tillandsias/help-${_LOCALE}.sh' "$ROOT/images/default/help.sh" \
    && ok "2: help.sh dispatches under /usr/local/share/tillandsias" || bad "2: help.sh no longer dispatches where both paths stage"

/usr/bin/grep -qF 'cp ${forgeLocales}/*.sh ./etc/tillandsias/locales/' "$FL" \
    && ok "3: flake.nix stages every locale bundle" || bad "3: flake.nix stages a hand list of locale bundles"

stray="$(ls "$ROOT"/scripts/help*.sh 2>/dev/null)"
[ -z "$stray" ] && ok "4: no stray help dispatcher outside images/default" || bad "4: stray copies: $stray"

[ "$fail" -eq 0 ] || exit 1
echo "PASS: forge-localization-staged"
