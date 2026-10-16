#!/usr/bin/env bash
# @trace order:1750-a4re, spec:command-policies
# Build tillandsias-plan as a static musl binary and stage it at
# images/default/policy-bin/tillandsias-plan, the forge image's Bash command-policy
# decider (/usr/local/lib/tillandsias/policy-bin/tillandsias-plan, run by
# images/default/bash-policy-hook). tillandsias-headless/build.rs embeds it with
# the rest of images/, so every guest builds a forge that ships it.
#
# Called by scripts/build-sidecar.sh, so every lane that stages the router
# sidecar before compiling (build.sh, build-image.sh, build-macos-tray.sh,
# local-ci.sh, ...) stages this too. It mirrors that script: the target is
# derived from the machine (TILLANDSIAS_SIDECAR_TARGET overrides), a separate
# target dir avoids the parent cargo's lock, a content stamp skips an unchanged
# tree, and the output must be a Linux ELF of the target's arch before it is
# staged. The C toolchain is chosen below: mlua compiles Lua
# from C, which needs a musl C compiler (see THE C TOOLCHAIN).
#
# Exit: 0 staged or up to date; 2 unsupported machine; 3/4 no/wrong artifact.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$(bash "$SCRIPT_DIR/build-sidecar.sh" --print-target)"
DEST="$ROOT/images/default/policy-bin/tillandsias-plan"
STAMP="$ROOT/images/default/policy-bin/.stamp"
if [ -n "${TILLANDSIAS_SIDECAR_TARGET_DIR:-}" ]; then
    TDIR="$TILLANDSIAS_SIDECAR_TARGET_DIR"
elif [ -n "${CARGO_TARGET_DIR:-}" ]; then
    case "$CARGO_TARGET_DIR" in
        /* | [A-Za-z]:[/\\]*) TDIR="${CARGO_TARGET_DIR%/}-musl" ;;
        *) TDIR="$ROOT/${CARGO_TARGET_DIR%/}-musl" ;;
    esac
else
    TDIR="$ROOT/target-musl"
fi

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

# Every input that decides the bytes: tillandsias-plan's path-dependency
# closure, the one script it include_str!s from outside its crate, the
# workspace manifest and lock, VERSION, the target and the toolchain.
input_digest() {
    local f rel mode
    {
        printf 'target:%s\n' "$TARGET"
        printf 'rustc:%s\n' "$(rustc -V 2>/dev/null || echo unknown)"
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            rel="${f#"$ROOT"/}"
            mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo 0)"
            printf '%s:%s:%s\n' "$rel" "$mode" "$(_sha256 <"$f")"
        done < <(find "$ROOT/crates/tillandsias-plan" "$ROOT/crates/tillandsias-podman" \
            "$ROOT/crates/tillandsias-msg" "$ROOT/crates/tillandsias-exec" \
            "$ROOT/scripts/fleet-activity.sh" "$ROOT/Cargo.toml" "$ROOT/Cargo.lock" "$ROOT/VERSION" \
            -type f -print 2>/dev/null)
    } | LC_ALL=C sort | _sha256
}

if [ -f "$DEST" ] && [ -f "$STAMP" ] && [ "${TILLANDSIAS_SIDECAR_FORCE_REBUILD:-0}" != 1 ]; then
    want_in="$(sed -n 's/^inputs=//p' "$STAMP")"
    want_out="$(sed -n 's/^output=//p' "$STAMP")"
    if [ -n "$want_in" ] && [ "$(_sha256 <"$DEST")" = "$want_out" ] && [ "$(input_digest)" = "$want_in" ]; then
        echo "[build-forge-plan-bin] up-to-date: ${DEST}"
        exit 0
    fi
fi

# THE C TOOLCHAIN. mlua vendors Lua as C, and a glibc gcc cannot build it for
# musl: its headers rename fopen/fseeko/... to the *64 symbols musl does not
# export, so the link fails (measured on lenovinha, Fedora gcc, 2026-10-16).
# In order: a CC_<triple> the caller set; a musl gcc on PATH; cargo zigbuild
# (darwin, where build-macos-tray.sh already needs it); a pinned Debian rust
# container with musl-tools (podman hosts). With none, nothing is staged and a
# named warning says what the forge will do: refuse every Claude Bash command.
cc_var="CC_$(printf '%s' "$TARGET" | tr '-' '_')"
arch="${TARGET%%-*}"
mode=""
if [ -n "${!cc_var:-}" ]; then
    mode=cargo
elif command -v "${arch}-linux-musl-gcc" >/dev/null 2>&1 || command -v musl-gcc >/dev/null 2>&1; then
    mode=cargo
elif command -v cargo-zigbuild >/dev/null 2>&1; then
    mode=zigbuild
elif command -v podman >/dev/null 2>&1 && [ "${TILLANDSIAS_FORGE_PLAN_NO_CONTAINER:-0}" != 1 ]; then
    mode=container
fi
SRC="$TDIR/$TARGET/release/tillandsias-plan"
case "$mode" in
    cargo | zigbuild)
        if command -v rustup >/dev/null 2>&1; then
            rustup target list --installed | grep -qx "$TARGET" || rustup target add "$TARGET" # sigpipe-ok: safe pipeline
        fi
        sub=build
        [ "$mode" = zigbuild ] && sub=zigbuild
        echo "[build-forge-plan-bin] cargo $sub --release --target ${TARGET} -p tillandsias-plan"
        (cd "$ROOT" && CARGO_TARGET_DIR="$TDIR" cargo "$sub" --release --target "$TARGET" -p tillandsias-plan --bin tillandsias-plan)
        ;;
    container)
        # The toolchain inside is the one rust-toolchain.toml pins (rustup reads
        # it from the mounted tree). The target dir persists under $TDIR.
        image="docker.io/library/rust:$(sed -n 's/^channel = "\(.*\)"/\1/p' "$ROOT/rust-toolchain.toml")-slim"
        # The registry lives in the user cache, never in the checkout: crates
        # carry their own .py helpers, and check-no-python-scripts scans the tree.
        registry="${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias/forge-plan-cargo-registry"
        mkdir -p "$registry"
        echo "[build-forge-plan-bin] no musl C toolchain on this host: building in ${image} (musl-tools)"
        podman run --rm --security-opt label=disable \
            -v "$ROOT:/src" -v "$TDIR:/musl-target" -v "$registry:/usr/local/cargo/registry" \
            -w /src -e CARGO_TARGET_DIR=/musl-target "$image" sh -c \
            "apt-get -qq update >/dev/null && apt-get -qq install -y musl-tools >/dev/null 2>&1 \
             && rustup target add ${TARGET} >/dev/null 2>&1 \
             && cargo build --release --target ${TARGET} -p tillandsias-plan --bin tillandsias-plan"
        ;;
    *)
        echo "warn:forge-plan-bin:no-musl-c-toolchain — ${DEST} not staged; a forge image built from this tree refuses every Claude Bash command (1750-a4re)" >&2
        echo "  remedy: install musl-gcc (Fedora: musl-gcc, Debian: musl-tools) or cargo-zigbuild, or run on a podman host; release builds stage it through nix" >&2
        exit 0
        ;;
esac
[ -f "$SRC" ] || { echo "[build-forge-plan-bin] ERROR: build succeeded but no binary at $SRC" >&2; exit 3; }
strip "$SRC" 2>/dev/null || true

case "$TARGET" in
    x86_64-*) want_arch='x86-64' ;;
    aarch64-*) want_arch='aarch64' ;;
    *) want_arch='' ;;
esac
desc="$(file -b "$SRC")"
case "$desc" in
    ELF*) ;;
    *) echo "[build-forge-plan-bin] ERROR: not a Linux ELF, not staged: $desc" >&2; exit 4 ;;
esac
if [ -n "$want_arch" ] && ! printf '%s' "$desc" | grep -qi -- "$want_arch"; then # sigpipe-ok: safe pipeline
    echo "[build-forge-plan-bin] ERROR: '$desc' is not ${TARGET}: wrong-arch artifact, not staged" >&2
    exit 4
fi

if [ -f "$DEST" ] && cmp -s "$SRC" "$DEST"; then
    echo "[build-forge-plan-bin] staged copy already byte-identical: ${DEST}"
else
    install -m 0755 "$SRC" "$DEST"
    echo "[build-forge-plan-bin] staged: ${DEST} ($(du -h "$DEST" | cut -f1))"
fi
tmp="$(mktemp "${STAMP}.XXXXXX")"
printf '# forge tillandsias-plan evaluation stamp (1750-a4re). Gitignored; delete to rebuild.\ninputs=%s\noutput=%s\n' \
    "$(input_digest)" "$(_sha256 <"$DEST")" >"$tmp"
mv -f "$tmp" "$STAMP"
