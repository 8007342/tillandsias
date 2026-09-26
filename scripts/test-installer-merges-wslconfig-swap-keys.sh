#!/usr/bin/env bash
# @trace order:1339-r9xv
#
# Fixture for the .wslconfig swap-key merge in scripts/install-windows.ps1.
# It RUNS the installer's own Get-WslConfigMerge through PowerShell against
# concrete files; it does not read the function's source for idioms. The
# first fixture on this row only read source, and its seven green arms never
# noticed that the shipped advice recommended the configuration already in
# force (plan census, 2026-09-22). This one feeds the function a file and
# reads the file it hands back.
#
#   0  the function can be cut out: each marker exactly once, and the cut
#      defines Get-WslConfigMerge (could-not-run otherwise, never a verdict)
#   1  empty file: adds exactly the four keys, in their sections, each under
#      a "# tillandsias:" comment
#   2  a file with memory/processors/autoMemoryReclaim: adds swap, swapFile,
#      sparseVhd, and leaves every existing line byte-identical and in order
#   3  a present swap=4GB is NOT overwritten and is reported as a difference
#   4  idempotent: the function's own output, fed back, adds nothing and
#      returns identical lines
#   5  autoMemoryReclaim under [wsl2] (where WSL ignores it) does not count as
#      present: the [experimental] key is still added
#   6  swapFile is written with doubled backslashes (.wslconfig expands nothing)
#
# Where no PowerShell exists (a Linux gate host) the RUN is a named skip and
# arm 0 still runs, so the cut itself is always checked.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/scripts/install-windows.ps1"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wslconfig-merge-fixture.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0
ran=0
skipped=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# ARM 0: the cut.
ran=$((ran + 1))
nb="$(grep -cx '# BEGIN-WSLCONFIG-MERGE' "$SRC")" || true
ne="$(grep -cx '# END-WSLCONFIG-MERGE' "$SRC")" || true
if [ "$nb" != "1" ] || [ "$ne" != "1" ]; then
    echo "could-not-run:wslconfig-merge-fixture:markers:begin=$nb:end=$ne"
    echo "why: the fixture cuts Get-WslConfigMerge out between two marker lines, and each must occur exactly once" >&2
    echo "fix: restore the BEGIN-WSLCONFIG-MERGE / END-WSLCONFIG-MERGE lines around the function" >&2
    exit 3
fi
sed -n '/^# BEGIN-WSLCONFIG-MERGE$/,/^# END-WSLCONFIG-MERGE$/p' "$SRC" > "$TMP/merge.ps1"
if ! grep -q '^function Get-WslConfigMerge' "$TMP/merge.ps1"; then
    echo "could-not-run:wslconfig-merge-fixture:cut-has-no-function"
    echo "why: the markers were found but the text between them does not define Get-WslConfigMerge" >&2
    echo "fix: keep the function between the two marker lines" >&2
    exit 3
fi

PWSH="$(command -v pwsh || command -v powershell || true)"
if [ -z "$PWSH" ]; then
    echo "skip:wslconfig-merge-fixture:run:no-powershell-on-this-host" >&2
    skipped=$((skipped + 1))
    echo "ok:wslconfig-merge-fixture:ran=$ran skipped=$skipped"
    exit 0
fi

winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# The harness: dot-source the cut, run one case, print the verdict fields and
# the merged file between markers so bash can compare it byte for byte.
cat > "$TMP/run.ps1" <<'PS'
param([string]$Merge, [string]$In)
. $Merge
$lines = @()
if ((Test-Path $In) -and (Get-Item $In).Length -gt 0) { $lines = @(Get-Content $In) }
$r = Get-WslConfigMerge -Lines $lines -SwapFile 'C:\Users\u\AppData\Local\tillandsias\wsl-swap.vhdx'
foreach ($a in $r.Added) { "added:$a" }
foreach ($d in $r.Differs) { "differs:$d" }
"---begin---"
foreach ($l in $r.Lines) { $l }
"---end---"
PS

run_case() {   # run_case <name> <input-file>  -> $TMP/<name>.out, $TMP/<name>.merged
    local name="$1" in="$2"
    "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$TMP/run.ps1")" \
        -Merge "$(winpath "$TMP/merge.ps1")" -In "$(winpath "$in")" 2>&1 | tr -d '\r' > "$TMP/$name.out"
    sed -n '/^---begin---$/,/^---end---$/p' "$TMP/$name.out" | sed '1d;$d' > "$TMP/$name.merged"
}
count() { grep -c -- "$1" "$2" || true; }

# ARM 1: empty file.
: > "$TMP/empty.ini"
run_case empty "$TMP/empty.ini"
ran=$((ran + 1))
[ "$(count '^added:' "$TMP/empty.out")" = "4" ] || fail "1 empty file — added $(count '^added:' "$TMP/empty.out") keys, want 4: $(cat "$TMP/empty.out")"
[ "$(count '^# tillandsias:' "$TMP/empty.merged")" = "4" ] || fail "1 each added key needs its own # tillandsias: comment"
awk '/^\[wsl2\]$/{s="w"} /^\[experimental\]$/{s="e"} /^swap=8GB$/{print "swap:" s} /^sparseVhd=true$/{print "sparse:" s} /^autoMemoryReclaim=gradual$/{print "reclaim:" s}' \
    "$TMP/empty.merged" > "$TMP/empty.sections"
[ "$(tr '\n' ' ' < "$TMP/empty.sections")" = "swap:w sparse:e reclaim:e " ] \
    || fail "1 keys landed in the wrong sections: $(tr '\n' ' ' < "$TMP/empty.sections")"

# ARM 2: an existing tuned file keeps every line, in order.
printf '%s\n' '[wsl2]' 'memory=8GB' 'processors=16' '' '[experimental]' 'autoMemoryReclaim=gradual' > "$TMP/tuned.ini"
run_case tuned "$TMP/tuned.ini"
ran=$((ran + 1))
[ "$(grep '^added:' "$TMP/tuned.out" | sed 's/=.*//' | tr '\n' ' ')" = "added:[wsl2] swap added:[wsl2] swapFile added:[experimental] sparseVhd " ] \
    || fail "2 tuned file — added: $(grep '^added:' "$TMP/tuned.out" | tr '\n' ' ')"
grep -v '^# tillandsias:' "$TMP/tuned.merged" | grep -vE '^(swap|swapFile|sparseVhd)=' > "$TMP/tuned.kept"
cmp -s "$TMP/tuned.ini" "$TMP/tuned.kept" || fail "2 an existing line was changed, dropped or reordered"

# ARM 3: a present swap is never overwritten.
printf '%s\n' '[wsl2]' 'memory=8GB' 'swap=4GB' > "$TMP/swap4.ini"
run_case swap4 "$TMP/swap4.ini"
ran=$((ran + 1))
[ "$(count '^swap=' "$TMP/swap4.merged")" = "1" ] && grep -qx 'swap=4GB' "$TMP/swap4.merged" \
    || fail "3 the user's swap=4GB was overwritten or duplicated: $(grep '^swap=' "$TMP/swap4.merged" | tr '\n' ' ')"
grep -q '^differs:\[wsl2\] swap=4GB' "$TMP/swap4.out" || fail "3 the differing swap was not reported"
grep -q '^added:\[wsl2\] swap=' "$TMP/swap4.out" && fail "3 swap was reported as added although present"

# ARM 4: idempotent.
cp "$TMP/empty.merged" "$TMP/again.ini"
run_case again "$TMP/again.ini"
ran=$((ran + 1))
[ "$(count '^added:' "$TMP/again.out")" = "0" ] || fail "4 a second run added keys: $(grep '^added:' "$TMP/again.out" | tr '\n' ' ')"
cmp -s "$TMP/again.ini" "$TMP/again.merged" || fail "4 a second run changed the file"

# ARM 5: autoMemoryReclaim in [wsl2] is inert, so [experimental] still gets it.
printf '%s\n' '[wsl2]' 'autoMemoryReclaim=gradual' > "$TMP/misplaced.ini"
run_case misplaced "$TMP/misplaced.ini"
ran=$((ran + 1))
grep -q '^added:\[experimental\] autoMemoryReclaim=gradual' "$TMP/misplaced.out" \
    || fail "5 autoMemoryReclaim under [wsl2] was treated as present"

# ARM 6: the swap file path is escaped for .wslconfig.
ran=$((ran + 1))
grep -qxF 'swapFile=C:\\Users\\u\\AppData\\Local\\tillandsias\\wsl-swap.vhdx' "$TMP/empty.merged" \
    || fail "6 swapFile is not written with doubled backslashes: $(grep '^swapFile=' "$TMP/empty.merged")"

if [ "$fails" -ne 0 ]; then
    echo "refused:wslconfig-merge-fixture:failed=$fails ran=$ran skipped=$skipped"
    exit 1
fi
echo "ok:wslconfig-merge-fixture:ran=$ran skipped=$skipped"
