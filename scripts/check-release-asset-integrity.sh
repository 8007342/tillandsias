#!/usr/bin/env bash
# @trace order:756-rfdr, spec:ci-release
#
# Every published release asset must be verifiable by someone who downloaded
# it. This checks that, over a directory of staged artifacts or a live release.
#
# WHY COUNTING UNSIGNED ASSETS IS THE WRONG CHECK. On v0.4.260815.1 five of the
# 29 assets had no `.cosign.bundle`, and four of those five were fine: a file is
# also covered when it is NAMED in a SHA256SUMS manifest that is itself signed,
# or when it IS such a manifest and every entry in it is individually signed.
# A gate that flagged all five would have cried wolf four times and been turned
# off. So this follows the transitive path instead of counting.
#
# THE ONE THAT WAS NOT FINE: install-windows.ps1 — no bundle, and named in none
# of SHA256SUMS, SHA256SUMS-macos or SHA256SUMS-windows. It is also the asset
# with the most privilege in the Windows path (it writes PATH, registers a WSL2
# distro, installs a startup tray) and README.md tells users to pipe it into
# their shell. It shipped bare because the Windows job's signing loop was an
# ALLOW-LIST and the step that staged the installer ran after it — two
# independent reasons, neither of which produced any output.
#
# COVERAGE RULES. An asset is covered when any of:
#   1. `<asset>.cosign.bundle` exists                       -> signed
#   2. it is named in some SHA256SUMS* that is itself signed -> manifested
#   3. it IS a SHA256SUMS* and every entry it names is signed -> manifest-of-signed
# `.cosign.bundle` files are not themselves assets to check.
#
# GRAMMAR (exactly one line on stdout)
#   ok:release-asset-integrity:<covered> of <checked> checked
#   violation:release-asset-integrity:<n>
#
# Exit 0 on ok, 1 on violation, 2 on usage error.
#
# Usage:
#   scripts/check-release-asset-integrity.sh <dir>       # staged artifacts
#   scripts/check-release-asset-integrity.sh --tag <tag> # a published release

set -uo pipefail

DIR=""
TAG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag) TAG="${2:-}"; shift 2 ;;
        --tag=*) TAG="${1#--tag=}"; shift ;;
        -*) echo "usage: check-release-asset-integrity.sh <dir> | --tag <tag>" >&2; exit 2 ;;
        *) DIR="$1"; shift ;;
    esac
done

names=""
if [ -n "$TAG" ]; then
    command -v gh >/dev/null 2>&1 || { echo "violation:release-asset-integrity:0"; echo "  gh is required for --tag" >&2; exit 2; }
    names="$(gh release view "$TAG" --json assets -q '.assets[].name' 2>/dev/null | sort)"
    [ -n "$names" ] || { echo "violation:release-asset-integrity:0"; echo "  no assets found for $TAG" >&2; exit 2; }
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    # Only the manifests need their CONTENT; rule 2 reads their entries.
    for m in $(printf '%s\n' "$names" | grep '^SHA256SUMS' | grep -v '\.cosign\.bundle$'); do
        gh release download "$TAG" -p "$m" -D "$work" --clobber >/dev/null 2>&1 || true
    done
    DIR="$work"
elif [ -n "$DIR" ] && [ -d "$DIR" ]; then
    names="$(cd "$DIR" && ls -1 2>/dev/null | sort)"
else
    echo "usage: check-release-asset-integrity.sh <dir> | --tag <tag>" >&2
    exit 2
fi

has() { printf '%s\n' "$names" | grep -qxF "$1"; }

# Entries named by a manifest, read from the manifest file when present.
manifest_entries() {
    local m="$DIR/$1"
    [ -f "$m" ] || return 0
    # `sha256  name` or `sha256 *name`
    awk '{ n=$2; sub(/^\*/,"",n); if (n != "") print n }' "$m"
}

# A manifest is trustworthy if it is signed OR every file it names is signed.
manifest_is_trustworthy() {
    local m="$1" e any=0
    has "${m}.cosign.bundle" && return 0
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        any=1
        has "${e}.cosign.bundle" || return 1
    done < <(manifest_entries "$m")
    [ "$any" -eq 1 ]
}

violations=()
checked=0
covered=0

for a in $names; do
    case "$a" in *.cosign.bundle) continue ;; esac
    checked=$((checked + 1))

    if has "${a}.cosign.bundle"; then
        covered=$((covered + 1)); continue
    fi

    # Rule 3: the asset is itself a manifest whose entries are all signed.
    case "$a" in
        SHA256SUMS*)
            if manifest_is_trustworthy "$a"; then
                covered=$((covered + 1)); continue
            fi
            ;;
    esac

    # Rule 2: some trustworthy manifest names it.
    found=0
    for m in $(printf '%s\n' "$names" | grep '^SHA256SUMS' | grep -v '\.cosign\.bundle$'); do
        if manifest_entries "$m" | grep -qxF "$a" && manifest_is_trustworthy "$m"; then
            found=1; break
        fi
    done
    if [ "$found" -eq 1 ]; then
        covered=$((covered + 1)); continue
    fi

    violations+=("$a")
done

if [ "${#violations[@]}" -gt 0 ]; then
    echo "violation:release-asset-integrity:${#violations[@]}"
    for v in ${violations[@]+"${violations[@]}"}; do
        echo "  $v has no integrity path: no ${v}.cosign.bundle, and no signed SHA256SUMS names it" >&2
    done
    echo "  A downloader cannot verify these. Sign them in the release workflow" >&2
    echo "  (the loop must be \`for artifact in *\`, not an allow-list) or name them" >&2
    echo "  in a SHA256SUMS that is itself signed (756-rfdr)." >&2
    exit 1
fi

echo "ok:release-asset-integrity:${covered} of ${checked} checked"
exit 0
