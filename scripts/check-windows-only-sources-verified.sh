#!/usr/bin/env bash
# @trace spec:windows-native-tray, spec:methodology-accountability
#
# Order 716-f5kc. Say out loud when a Windows-only source has changed since the
# last time a Windows toolchain actually compiled it.
#
# THE SILENCE THIS REPLACES
#
# `crates/tillandsias-windows-tray/src/main.rs` declares, for every
# Windows-only module, a `#[cfg(not(target_os = "windows"))] #[path =
# "stubs/X.rs"] mod X;` substitute. That is correct and deliberate — it lets the
# portable code paths and their tests compile on Linux. What it also does is
# make `cargo check -p tillandsias-windows-tray` on a Linux host compile the
# STUB and report success WITHOUT PARSING the file the agent just edited.
#
# So the failure mode is a green that means nothing, and it is silent in the
# direction that matters. It happened twice in one session (2026-08-13): once
# caught by a deliberate second look on order 648-772y, once unavoidable on
# order 664-frz0 when Smart App Control blocked the native toolchain
# (`os error 4551`) and left this host with no way to compile the file at all.
#
# This does not fix that. It makes it VISIBLE: a cycle can no longer edit
# wsl_lifecycle.rs, watch a Linux build go green, and be unaware that nothing
# read the change.
#
# WHY IT IS NOT A HARD GATE (yet)
#
# Refusing the push when the toolchain is blocked would strand finished work on
# a host that cannot verify — which the meta-orchestration exit contract forbids
# more strongly than it forbids an unverified commit. So this reports, and the
# report is what a cycle must carry into its handoff. Promoting it to a refusal
# is a decision for the operator, and the natural moment is when dev binaries
# are signed and SAC stops being a coin flip.
#
# GRAMMAR (exactly one line on stdout)
#   ok:windows-sources-verified:<n>            all n sources match the stamp
#   stale:windows-sources-unverified:<n>:<f>   n changed since the stamp, first is f
#   stale:windows-sources-never-verified:<n>   no stamp on this host yet
#   skip:no-windows-only-sources               nothing to check (crate moved?)
#
# Exit 0 always: this is a report, not a refusal. Branch on the verdict, and
# never on the exit code, which is the mistake that would let it be ignored.
#
# SUBCOMMANDS
#   check   (default) print the verdict
#   stamp   record the current contents as verified — call ONLY after a native
#           `cargo test -p tillandsias-windows-tray` has actually passed

set -uo pipefail

ROOT="${WINDOWS_ONLY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GIT_DIR="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || echo "$ROOT/.git")"
STAMP_FILE="${WINDOWS_ONLY_STAMP:-$GIT_DIR/tillandsias-windows-only-verified}"
TRAY_SRC="$ROOT/crates/tillandsias-windows-tray/src"
MAIN_RS="$TRAY_SRC/main.rs"

# The Windows-only set is DERIVED from main.rs rather than listed here, so a new
# Windows-only module cannot forget to join the check. It reads the
# `#[cfg(target_os = "windows")] mod X;` declarations — NOT the `#[path =
# "stubs/…"]` lines, which was the first attempt and quietly missed `hvsocket`:
# that module is Windows-only and has no stub, so it is equally invisible to a
# Linux build and equally needs saying so.
windows_only_sources() {
    [ -f "$MAIN_RS" ] || return 0
    # `grep -A 1` over the cfg attribute, keep the `mod X;` line, strip to X.
    grep -A 1 -F '#[cfg(target_os = "windows")]' "$MAIN_RS" 2>/dev/null |
        grep -oE '^mod [a-z_]+;' |
        cut -d' ' -f2 |
        tr -d ';' |
        sort -u |
        while IFS= read -r m; do
            [ -n "$m" ] && [ -f "$TRAY_SRC/$m.rs" ] && echo "$TRAY_SRC/$m.rs"
        done
}

digest_of() {
    # Path + content, so a rename is a change too.
    while IFS= read -r f; do
        printf '%s\0' "${f#"$ROOT"/}"
        sha256sum "$f" | cut -d' ' -f1
    done | sha256sum | cut -d' ' -f1
}

mapfile -t SOURCES < <(windows_only_sources)
if [ "${#SOURCES[@]}" -eq 0 ]; then
    echo "skip:no-windows-only-sources"
    exit 0
fi

current="$(printf '%s\n' "${SOURCES[@]}" | digest_of)"

case "${1:-check}" in
    stamp)
        printf '%s\n' "$current" > "$STAMP_FILE"
        # Per-file records too, so `check` can NAME the file that moved rather
        # than reporting the aggregate and picking whichever source sorts first
        # as the culprit. That first version gave a confident wrong answer,
        # which is the failure this whole check exists to prevent.
        rm -rf "$STAMP_FILE.d"
        mkdir -p "$STAMP_FILE.d"
        for f in "${SOURCES[@]}"; do
            rel="${f#"$ROOT"/}"
            printf '%s\n' "$f" | digest_of \
                > "$STAMP_FILE.d/$(printf '%s' "$rel" | tr '/' '_')"
        done
        echo "ok:windows-sources-verified:${#SOURCES[@]}"
        ;;
    check)
        if [ ! -f "$STAMP_FILE" ]; then
            echo "stale:windows-sources-never-verified:${#SOURCES[@]}"
            exit 0
        fi
        recorded="$(cat "$STAMP_FILE" 2>/dev/null)"
        if [ "$recorded" = "$current" ]; then
            echo "ok:windows-sources-verified:${#SOURCES[@]}"
            exit 0
        fi
        # Name the first changed file. "Something changed" sends the next agent
        # diffing the whole crate; naming it is the difference between a report
        # and a rumour.
        changed=0
        first=""
        for f in "${SOURCES[@]}"; do
            rel="${f#"$ROOT"/}"
            per_file="$(printf '%s\n' "$f" | digest_of)"
            prev_file="$STAMP_FILE.d/$(printf '%s' "$rel" | tr '/' '_')"
            if [ -f "$prev_file" ] && [ "$(cat "$prev_file")" = "$per_file" ]; then
                continue
            fi
            changed=$((changed + 1))
            [ -z "$first" ] && first="$rel"
        done
        # If per-file records are absent (a stamp written by an older version),
        # say the whole set is unverified rather than inventing a culprit.
        if [ "$changed" -eq 0 ]; then
            changed="${#SOURCES[@]}"
            first="all(no-per-file-records)"
        fi
        echo "stale:windows-sources-unverified:$changed:$first"
        ;;
    *)
        echo "usage: check-windows-only-sources-verified.sh [check|stamp]" >&2
        exit 2
        ;;
esac
exit 0
