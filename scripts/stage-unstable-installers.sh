#!/usr/bin/env bash
# @trace order:1369-sjbc, spec:ci-release
#
# stage-unstable-installers.sh — stage the copy of a release artifact directory
# that is uploaded to the rolling `unstable` release, with every installer in it
# defaulting to the UNSTABLE channel.
#
# THE DEFECT THIS CLOSES (1369-sjbc). Each installer defaulted to stable unless
# TILLANDSIAS_CHANNEL / --channel was given. The release jobs uploaded the SAME
# bytes to v<VERSION> and to `unstable`, so
#   irm https://github.com/8007342/tillandsias/releases/download/unstable/install-windows.ps1 | iex
# with no variable set installed STABLE (56.9.21.1 while 56.9.23.1 was current),
# and it still ran the destructive reset. The user chose the URL; the URL did not
# decide what they got. A script cannot see the URL it was fetched from, so the
# default has to be baked into the copy published at that URL.
#
# WHY A SEPARATE COPY and not a rewrite in place: the v<VERSION> release is the
# one scripts/promote-stable.sh later marks latest, so its installers must keep
# the stable default. Only the copy uploaded to `unstable` changes.
#
# WHAT IT DOES, in <dst-dir> (which must not exist or must be empty):
#   1. copies every file of <src-dir>;
#   2. rewrites the one default line in each installer present
#        install.sh, install-macos.sh      DEFAULT_CHANNEL="stable"
#        install-windows.ps1               $DefaultChannel = 'stable'
#      and REFUSES unless that line matched exactly once before and the
#      unstable form matches exactly once after;
#   3. rewrites that installer's line in any SHA256SUMS* manifest that lists
#      it, then runs `sha256sum -c` on the lines for files present;
#   4. deletes the now-stale .cosign.bundle of each rewritten file and prints
#      `resign:<file>` for each. The caller signs those; this script never
#      signs, so the fixture can run without cosign.
#
# GRAMMAR (stdout)
#   resign:<file>                                  zero or more
#   ok:stage-unstable-installers:rewritten=<n> resign=<m>
#   refused:stage-unstable-installers:<reason>     why: and fix: on stderr
# Exit 0 on ok, 1 on refusal, 2 on usage.

set -euo pipefail

refuse() {
    # refuse <reason> <why> <fix> [exit]
    echo "refused:stage-unstable-installers:$1"
    echo "why: $2" >&2
    echo "fix: $3" >&2
    exit "${4:-1}"
}

[ "$#" -eq 2 ] || refuse usage "expected <src-dir> <dst-dir>" \
    "run: scripts/stage-unstable-installers.sh release-artifacts unstable-artifacts" 2
src="$1"
dst="$2"
[ -d "$src" ] || refuse "no-src:$src" "the source artifact directory does not exist" \
    "stage the release artifacts first, then call this with that directory" 2
if [ -e "$dst" ] && [ -n "$(ls -A "$dst")" ]; then
    refuse "dst-not-empty:$dst" "a leftover copy could carry a previous run's installer" \
        "remove $dst or pass a fresh directory"
fi
mkdir -p "$dst"
cp -p "$src"/* "$dst"/

# count_lines <file> <fixed-string>: whole-line matches, CR tolerated.
count_lines() {
    local n
    n="$(tr -d '\r' < "$1" | grep -cxF -- "$2")" || true
    printf '%s' "${n:-0}"
}

rewritten=()
for inst in install.sh install-macos.sh install-windows.ps1; do
    f="$dst/$inst"
    [ -f "$f" ] || continue
    case "$inst" in
        *.ps1) from="\$DefaultChannel = 'stable'"; to="\$DefaultChannel = 'unstable'" ;;
        *)     from='DEFAULT_CHANNEL="stable"';    to='DEFAULT_CHANNEL="unstable"' ;;
    esac
    before="$(count_lines "$f" "$from")"
    [ "$before" = "1" ] || refuse "default-line-count:$inst:$before" \
        "$inst must contain the line '$from' exactly once; found $before, so the rewrite cannot be trusted" \
        "restore that line in scripts/$inst (see its order 1369-sjbc comment)"
    tmp="$f.stage.tmp"
    # BINMODE=3: gawk on MSYS / Git-for-Windows (the Windows release job)
    # reads in text mode and silently drops every CR; other awks ignore it.
    awk -v BINMODE=3 -v from="$from" -v to="$to" '{
        line = $0; cr = ""
        if (sub(/\r$/, "", line)) cr = "\r"
        if (line == from) line = to
        print line cr
    }' "$f" > "$tmp"
    # Write back through the existing inode so the mode survives on GNU and
    # BSD alike (the macOS job runs this on the runner's bash 3.2).
    cat "$tmp" > "$f"
    rm -f "$tmp"
    after="$(count_lines "$f" "$to")"
    left="$(count_lines "$f" "$from")"
    [ "$after" = "1" ] && [ "$left" = "0" ] || refuse "rewrite-did-not-land:$inst" \
        "after the rewrite '$to' matched $after time(s) and '$from' $left" \
        "inspect $f; the awk rewrite must change exactly one line"
    rewritten+=("$inst")
done

[ "${#rewritten[@]}" -gt 0 ] || refuse "no-installer-in:$src" \
    "none of install.sh, install-macos.sh, install-windows.ps1 is in $src, so nothing would default to unstable" \
    "call this from the job that stages an installer, after staging it"

resign=("${rewritten[@]}")
for sums in "$dst"/SHA256SUMS*; do
    [ -f "$sums" ] || continue
    case "$sums" in *.cosign.bundle) continue ;; esac
    touched=0
    for inst in "${rewritten[@]}"; do
        # Both coreutils forms: `<hash>  <name>` (text) and `<hash> *<name>`
        # (binary; MSYS and Git-for-Windows sha256sum emit it). The form is
        # kept as found. A line that names the installer in any OTHER shape is
        # a refusal, not a skip: a skipped line would publish a manifest that
        # fails for the one file this script changed.
        mentions="$(awk -v n="$inst" '{ x = $NF; sub(/^\*/, "", x); if (x == n) c++ } END { print c + 0 }' "$sums")"
        [ "$mentions" = "0" ] && continue
        parsed="$(awk -v n="$inst" '$1 ~ /^[0-9a-f]+$/ && length($1) == 64 && NF == 2 && ($2 == n || $2 == "*" n) { c++ } END { print c + 0 }' "$sums")"
        [ "$parsed" = "1" ] && [ "$mentions" = "1" ] || refuse "manifest-line-unrecognised:$(basename "$sums"):$inst" \
            "$(basename "$sums") names $inst $mentions time(s) but only $parsed line(s) are in a checksum form this script rewrites" \
            "make the manifest one '<sha256>  $inst' or '<sha256> *$inst' line"
        new_hash="$(sha256sum "$dst/$inst" | cut -d' ' -f1)"
        awk -v n="$inst" -v h="$new_hash" '{
            if ($2 == n) print h "  " n
            else if ($2 == "*" n) print h " *" n
            else print
        }' "$sums" > "$sums.stage.tmp"
        cat "$sums.stage.tmp" > "$sums"
        rm -f "$sums.stage.tmp"
        touched=1
    done
    if [ "$touched" = "1" ]; then
        # Verify only the lines for files present here: a platform manifest can
        # list files another job publishes.
        checklist="$dst/.stage-check.tmp"
        awk -v d="$dst" '{ x = $2; sub(/^\*/, "", x); if ((getline _ < (d "/" x)) >= 0) print; close(d "/" x) }' \
            "$sums" > "$checklist"
        ( cd "$dst" && sha256sum -c --quiet .stage-check.tmp ) >&2 \
            || refuse "manifest-does-not-verify:$(basename "$sums")" \
                "after the rewrite, $(basename "$sums") does not verify against the staged files" \
                "inspect $dst; the manifest line for the rewritten installer was not updated"
        rm -f "$checklist"
        resign+=("$(basename "$sums")")
    fi
done

# Re-sign exactly what was signed in the source: a file that shipped with a
# bundle must ship with a fresh one, and a file that shipped without one (the
# Linux SHA256SUMS) stays as the versioned release has it.
nresign=0
for r in "${resign[@]}"; do
    [ -f "$src/$r.cosign.bundle" ] || continue
    rm -f "$dst/$r.cosign.bundle"
    echo "resign:$r"
    nresign=$((nresign + 1))
done
echo "ok:stage-unstable-installers:rewritten=${#rewritten[@]} resign=$nresign"
