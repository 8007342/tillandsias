#!/usr/bin/env bash
set -euo pipefail

# Portable SHA-256 (851-28b5): coreutils sha256sum on Linux/forge/WSL; stock
# macOS before 13 ships only `shasum`. Identical "<hex>  <name>" output.
if command -v sha256sum >/dev/null 2>&1; then
    PORTABLE_SHA256=(sha256sum)
else
    PORTABLE_SHA256=(shasum -a 256)
fi

# @trace spec:user-runtime-lifecycle, spec:init-incremental-builds, spec:nix-builder

[[ $# -ge 2 && $# -le 3 ]] || {
    echo "usage: $0 IMAGE_NAME IMAGE_DIR [REPO_ROOT]" >&2
    exit 2
}

image_name="$1"
image_dir="$2"
root="${3:-$(git rev-parse --show-toplevel)}"
root="$(cd "$root" && pwd -P)"

[[ -d "$image_dir" ]] || {
    echo "no-sources"
    exit 0
}
image_dir="$(cd "$image_dir" && pwd -P)"
image_rel="${image_dir#"$root"/}"

source_rels=("$image_rel")
source_dirs=("$image_dir")
copied_source_rels=()
case "$image_name" in
    forge)
        source_rels+=(skills cheatsheets cheatsheet-sources)
        copied_source_rels+=(skills cheatsheets cheatsheet-sources)
        source_dirs+=("$root/skills" "$root/cheatsheets" "$root/cheatsheet-sources")
        ;;
esac

file_list=()
indexed_entries=()
untracked_rel=()
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # NUL-delimited reads remain compatible with stock macOS Bash 3.2.
    while IFS= read -r -d '' rel; do
        [[ -n "$rel" ]] && untracked_rel+=("$rel")
    done < <(git -C "$root" ls-files --others --exclude-standard -z -- "${source_rels[@]}" 2>/dev/null || true)
    if [[ ${#untracked_rel[@]} -gt 0 ]]; then
        echo "error: untracked image source files:" >&2
        printf '  %s\n' "${untracked_rel[@]}" >&2
        exit 1
    fi
    if [[ ${#copied_source_rels[@]} -gt 0 ]]; then
        while IFS= read -r -d '' rel; do
            [[ -n "$rel" ]] && untracked_rel+=("$rel")
        done < <(git -C "$root" ls-files --others --ignored --exclude-standard -z -- "${copied_source_rels[@]}" 2>/dev/null || true)
        if [[ ${#untracked_rel[@]} -gt 0 ]]; then
            echo "error: ignored files would be copied into the image without a tracked cache key:" >&2
            printf '  %s\n' "${untracked_rel[@]}" >&2
            exit 1
        fi
    fi
    # ORDER 776-cm74 — TRACKED ENTRIES HASH GIT-NORMALIZED CONTENT, NOT
    # WORKING-TREE BYTES. Operator decision, 2026-08-16, attended on the
    # Windows host.
    #
    # `git ls-files -s` yields `<mode> <object> <stage>\t<path>`, where the
    # object id is the blob AFTER clean filters and autocrlf normalization, and
    # the mode is git's own `100644`/`100755`/`120000`. Both are properties of
    # the COMMIT rather than of this checkout, which is the whole point:
    #
    #   * `core.autocrlf=true` gives a CRLF working tree, so hashing bytes made
    #     two clones of the SAME commit disagree — Windows against Linux, and
    #     Windows against Windows with different settings. The fixture's
    #     cross-location comparison could not be truthful there.
    #   * `stat` mode is meaningless where `core.fileMode=false`, which is the
    #     default on both Windows lanes.
    #
    # So the cache key stops depending on where the checkout lives or how git
    # was configured to materialise it. Untracked directories keep the
    # find/stat path below — they have no index entry to read.
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # `<mode> <object> <stage>\t<path>`
        local_meta="${line%%$'\t'*}"
        rel="${line#*$'\t'}"
        set -- $local_meta
        indexed_entries+=("$1:$2:$rel")
    done < <(git -C "$root" ls-files -s -- "${source_rels[@]}" 2>/dev/null || true)
else
    for source_dir in "${source_dirs[@]}"; do
        [[ -d "$source_dir" ]] || continue
        while IFS= read -r -d '' file; do
            [[ -n "$file" ]] && file_list+=("$file")
        done < <(find "$source_dir" \( -type f -o -type l \) -print0 2>/dev/null)
    done
fi

if [[ ${#file_list[@]} -eq 0 && ${#indexed_entries[@]} -eq 0 ]]; then
    echo "no-sources"
    exit 0
fi

# Non-filesystem build inputs must participate in the same cache identity as
# tracked context files. Changing the final image layer policy therefore
# invalidates unsquashed canonical tags exactly once.
manifest=("layer-policy:squash-new")

# Tracked entries: mode and content id come straight from the index, so the
# manifest line is already normalized and no file is read from disk.
for entry in ${indexed_entries[@]+"${indexed_entries[@]}"}; do
    gmode="${entry%%:*}"
    rest="${entry#*:}"
    oid="${rest%%:*}"
    rel="${rest#*:}"
    path_hash="$(printf '%s' "$rel" | "${PORTABLE_SHA256[@]}" | cut -d' ' -f1)"
    case "$gmode" in
        120000) type=symlink ;;
        100755) type=file ;;
        100644) type=file ;;
        *)      echo "error: unsupported tracked image source mode $gmode for $rel" >&2; exit 1 ;;
    esac
    manifest+=("${path_hash}:${type}:${gmode}:${oid}")
done

for file in ${file_list[@]+"${file_list[@]}"}; do
    rel="${file#"$root"/}"
    path_hash="$(printf '%s' "$rel" | "${PORTABLE_SHA256[@]}" | cut -d' ' -f1)"
    if mode="$(stat -c '%a' "$file" 2>/dev/null)"; then
        :
    else
        mode="$(stat -f '%Lp' "$file")"
    fi
    if [[ -L "$file" ]]; then
        type=symlink
        content_hash="$(readlink "$file" | "${PORTABLE_SHA256[@]}" | cut -d' ' -f1)"
    elif [[ -f "$file" ]]; then
        type=file
        content_hash="$("${PORTABLE_SHA256[@]}" <"$file" | cut -d' ' -f1)"
    else
        echo "error: unsupported tracked image source type: $rel" >&2
        exit 1
    fi
    manifest+=("${path_hash}:${type}:${mode}:${content_hash}")
done
printf '%s\n' "${manifest[@]}" | LC_ALL=C sort | "${PORTABLE_SHA256[@]}" | cut -d' ' -f1
