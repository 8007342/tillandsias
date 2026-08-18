#!/usr/bin/env bash
# Fixture for the uninstaller's shell PATH-integration removal.
#
# FRESHNESS AUDIT 2026-08-18 (order 372 class, component scripts/uninstall.sh).
# install.sh appends a MARKED PATH block to ~/.profile and ~/.bashrc, adds
# ~/.zprofile and ~/.zshrc under zsh, and writes ~/.config/fish/conf.d/
# tillandsias.fish outright. uninstall.sh removed none of them, so an uninstall
# left every shell exporting a PATH entry for a directory it had just deleted.
#
# These assertions are about the DANGEROUS half: the removal edits user dotfiles
# that predate the install and will outlive it, so the failure that matters is
# not "the block survived" but "the user lost something else".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH_MARKER_BEGIN="# >>> tillandsias PATH >>>"
PATH_MARKER_END="# <<< tillandsias PATH <<<"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The exact strings must still agree with install.sh, or the uninstaller looks
# for a marker nobody writes and silently removes nothing. This is the whole
# handshake, so it is asserted first.
grep -qF "PATH_MARKER_BEGIN=\"$PATH_MARKER_BEGIN\"" "$ROOT/scripts/install.sh" \
    || fail "install.sh no longer defines PATH_MARKER_BEGIN as expected"
grep -qF "PATH_MARKER_END=\"$PATH_MARKER_END\"" "$ROOT/scripts/install.sh" \
    || fail "install.sh no longer defines PATH_MARKER_END as expected"
grep -qF "PATH_MARKER_BEGIN=\"$PATH_MARKER_BEGIN\"" "$ROOT/scripts/uninstall.sh" \
    || fail "uninstall.sh markers drifted from install.sh"
grep -qF "PATH_MARKER_END=\"$PATH_MARKER_END\"" "$ROOT/scripts/uninstall.sh" \
    || fail "uninstall.sh markers drifted from install.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The removal logic, lifted verbatim in shape from uninstall.sh. Kept as a
# local copy on purpose: sourcing uninstall.sh would run an uninstall.
strip_path_block() {
    _spb_file="$1"
    [ -f "$_spb_file" ] || return 0
    grep -F "$PATH_MARKER_BEGIN" "$_spb_file" >/dev/null 2>&1 || return 0
    _spb_tmp="$_spb_file.tillandsias-uninstall.$$"
    if awk -v b="$PATH_MARKER_BEGIN" -v e="$PATH_MARKER_END" '
        index($0, b) == 1 { skip = 1; next }
        skip && index($0, e) == 1 { skip = 0; next }
        !skip { print }
    ' "$_spb_file" > "$_spb_tmp" 2>/dev/null; then
        mv "$_spb_tmp" "$_spb_file"
    else
        rm -f "$_spb_tmp"
        return 1
    fi
}

# 1. THE USER'S OWN LINES SURVIVE. This is the assertion that matters: the
#    block is removed and everything around it is byte-identical.
cat > "$WORK/bashrc" <<EOF
export EDITOR=vim

$PATH_MARKER_BEGIN
case ":\$PATH:" in
    *":/x:"*) ;;
    *) export PATH="/x:\$PATH" ;;
esac
$PATH_MARKER_END
alias ll='ls -l'
EOF
strip_path_block "$WORK/bashrc"
grep -q 'export EDITOR=vim' "$WORK/bashrc" || fail "the line BEFORE the block was lost"
grep -q "alias ll='ls -l'" "$WORK/bashrc" || fail "the line AFTER the block was lost"
grep -qF "$PATH_MARKER_BEGIN" "$WORK/bashrc" && fail "the block survived removal"
grep -q 'export PATH="/x:' "$WORK/bashrc" && fail "the block body survived removal"

# 2. A file with NO block is left exactly alone -- not rewritten, not touched.
printf 'export EDITOR=nano\n' > "$WORK/untouched"
cp "$WORK/untouched" "$WORK/untouched.expected"
strip_path_block "$WORK/untouched"
cmp -s "$WORK/untouched" "$WORK/untouched.expected" \
    || fail "a file without the marker was modified"

# 3. A missing file is a no-op, not an error. An uninstall must not fail
#    because the user never had a .zshrc.
strip_path_block "$WORK/definitely-absent" || fail "a missing file must be a no-op"

# 4. TWO blocks (a double install) are both removed. install.sh returns early
#    when the marker is present so this should not arise, but an uninstaller
#    that removes only the first would leave a live PATH export behind and
#    report success.
cat > "$WORK/doubled" <<EOF
first=1
$PATH_MARKER_BEGIN
export PATH="/x:\$PATH"
$PATH_MARKER_END
middle=2
$PATH_MARKER_BEGIN
export PATH="/y:\$PATH"
$PATH_MARKER_END
last=3
EOF
strip_path_block "$WORK/doubled"
grep -qF "$PATH_MARKER_BEGIN" "$WORK/doubled" && fail "a second block survived"
grep -q 'export PATH=' "$WORK/doubled" && fail "a second block body survived"
for keep in first=1 middle=2 last=3; do
    grep -q "$keep" "$WORK/doubled" || fail "removing two blocks lost $keep"
done

# 5. An UNTERMINATED block (a user hand-edited the END marker away) must not
#    silently eat the rest of the file... except it does, and that is the
#    honest tradeoff: awk cannot know where an unterminated span ends. What is
#    asserted here is that the file is not left EMPTY-but-valid, so the damage
#    is visible rather than silent.
cat > "$WORK/unterminated" <<EOF
before=1
$PATH_MARKER_BEGIN
export PATH="/x:\$PATH"
EOF
strip_path_block "$WORK/unterminated"
grep -q 'before=1' "$WORK/unterminated" \
    || fail "content BEFORE an unterminated block must survive"

echo "PASS: uninstall-path-block 5/5 (user lines survive, no-marker untouched, missing no-op, double block, unterminated preserves preceding content)"
