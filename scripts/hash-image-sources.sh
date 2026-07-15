#!/usr/bin/env bash
set -euo pipefail

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
    nanoclawv2)
        source_rels+=(skills)
        copied_source_rels+=(skills)
        source_dirs+=("$root/skills")
        ;;
esac

file_list=()
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
    while IFS= read -r -d '' rel; do
        [[ -n "$rel" ]] && file_list+=("$root/$rel")
    done < <(git -C "$root" ls-files -z -- "${source_rels[@]}" 2>/dev/null || true)
else
    for source_dir in "${source_dirs[@]}"; do
        [[ -d "$source_dir" ]] || continue
        while IFS= read -r -d '' file; do
            [[ -n "$file" ]] && file_list+=("$file")
        done < <(find "$source_dir" \( -type f -o -type l \) -print0 2>/dev/null)
    done
fi

if [[ ${#file_list[@]} -eq 0 ]]; then
    echo "no-sources"
    exit 0
fi

manifest=()
for file in "${file_list[@]}"; do
    rel="${file#"$root"/}"
    path_hash="$(printf '%s' "$rel" | sha256sum | cut -d' ' -f1)"
    if mode="$(stat -c '%a' "$file" 2>/dev/null)"; then
        :
    else
        mode="$(stat -f '%Lp' "$file")"
    fi
    if [[ -L "$file" ]]; then
        type=symlink
        content_hash="$(readlink "$file" | sha256sum | cut -d' ' -f1)"
    elif [[ -f "$file" ]]; then
        type=file
        content_hash="$(sha256sum <"$file" | cut -d' ' -f1)"
    else
        echo "error: unsupported tracked image source type: $rel" >&2
        exit 1
    fi
    manifest+=("${path_hash}:${type}:${mode}:${content_hash}")
done
printf '%s\n' "${manifest[@]}" | LC_ALL=C sort | sha256sum | cut -d' ' -f1
