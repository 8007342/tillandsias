#!/usr/bin/env bash
# @trace spec:opencode-web-session-otp
# Build tillandsias-router-sidecar as a static musl binary and stage it
# into images/router/ so the (single-stage) router Containerfile can COPY
# it into the image, AND the tray's embedded.rs can include_bytes!() it
# for runtime extraction in deployed binaries.
#
# Run by:
#   - build.sh (staged before EVERY compiling dispatch — check/test/build/
#     install/ci/release — via _stage_router_sidecar; the binary is a gitignored
#     build artifact that tillandsias-headless build.rs include_bytes!()s, so it
#     MUST exist before any cargo invocation)
#   - build-osx.sh (before `cargo tauri build`)
#   - .github/workflows/release.yml (built + published as a version-matched,
#     cosign-signed release asset alongside the linux/macos/windows binaries)
#   - manually for first-time setup or when sidecar source changes
#
# DO NOT run from `src-tauri/build.rs`: the nested `cargo build` here
# deadlocks on the workspace target-dir lock held by the parent cargo
# invocation. Verified in v0.1.170.245 when an AppImage build wedged
# during the tillandsias compilation step.
#
# Cross-compile via Rust's `x86_64-unknown-linux-musl` target. NO musl-gcc
# or external toolchain required — the target ships its own static linker
# strategy. Verified on Fedora 43 toolbox 2026-04-26: 2.5 MB stripped
# static-pie binary, no host musl install needed.
#
# The staged binary lives under `images/router/tillandsias-router-sidecar`
# (gitignored).
#
# THIN-LTO DEV PROFILE: CONSIDERED AND DECLINED (order 765-5efu, 2026-08-17).
# The packet offered an optional `[profile.release-sidecar]` (lto=thin,
# codegen-units=16) for the local dev lane. Measured first, then declined on
# two grounds. (1) It buys little now: with the evaluation stamp below, an
# unchanged tree costs 0.07s instead of 8-12s, so the rebuild it would speed
# up is the RARE path — a genuine source change — and paying for that in
# divergence is a bad trade. (2) It buys a real risk: this binary is
# include_bytes!'d into tillandsias-headless, so a thin-LTO dev profile means
# every local build embeds DIFFERENT bytes than the fat-LTO artifact release
# ships and cosign signs, which is precisely the version-matched-artifact
# property order 710-w9kc exists to protect. Do not add it without first
# answering how a dev-tested sidecar and a released one stay the same binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# TARGET IS DERIVED FROM THE MACHINE, no longer pinned (order 723-ji4v).
# The sidecar's only consumers run inside the LINUX GUEST, whose CPU is the
# host's: podman/WSL2 guests are native, and the Apple-Silicon VZ guest is
# aarch64 Linux. The old unconditional x86_64 pin staged an x86-64 ELF on
# Apple Silicon — measured on this checkout 2026-08-23: file(1) said x86-64
# while the guest is aarch64, a deterministic ENOEXEC at exec time that
# degrades to the silent 502 the packet describes. Release CI (ubuntu
# x86_64) derives exactly the triple it used to pin. The stamp already
# carries `target:` as an input, so this change self-invalidates every
# previously staged wrong-arch artifact. TILLANDSIAS_SIDECAR_TARGET
# overrides for cross builds; an unknown machine fails LOUD — a guessed
# triple stages bytes that fail only at exec time in a container.
if [[ -n "${TILLANDSIAS_SIDECAR_TARGET:-}" ]]; then
    TARGET="$TILLANDSIAS_SIDECAR_TARGET"
else
    case "$(uname -m)" in
        x86_64|amd64)  TARGET="x86_64-unknown-linux-musl" ;;
        arm64|aarch64) TARGET="aarch64-unknown-linux-musl" ;;
        *)
            echo "[build-sidecar] ERROR: unsupported machine '$(uname -m)' for the sidecar's Linux guest consumers." >&2
            echo "[build-sidecar]   Set TILLANDSIAS_SIDECAR_TARGET=<triple> explicitly." >&2
            exit 2
            ;;
    esac
fi
# Fixture seam (order 723-ji4v): print the derived triple and stop, so the
# derivation is testable without a 12s cargo build.
if [[ "${1:-}" == "--print-target" ]]; then
    echo "$TARGET"
    exit 0
fi
SIDECAR_DEST="$ROOT/images/router/tillandsias-router-sidecar"
# Use a SEPARATE target dir so a nested invocation (e.g. build.rs calling
# this script while the parent cargo holds target/'s lock) cannot deadlock.
# The nested build still benefits from cargo's incremental compilation
# under target-musl/.
SIDECAR_TARGET_DIR="$ROOT/target-musl"
# Evaluation stamp (order 765-5efu), gitignored beside the staged binary.
SIDECAR_STAMP="$ROOT/images/router/.sidecar.stamp"

# Portable SHA-256 over stdin. `sha256sum` is coreutils (Linux/forge/WSL);
# stock macOS ships `shasum` instead, and build-osx.sh runs this script.
_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

# CONTENT digest of everything that determines the staged binary's bytes
# (order 765-5efu). The input FILE set is deliberately unchanged from the
# mtime probe this replaces — 3 crates + Cargo.toml + Cargo.lock + VERSION,
# VERSION still present per 710-w9kc so a bump forces a version-matched
# re-evaluation. Two non-file inputs are added because they change the output
# from identical sources and the old probe was blind to both: the effective
# target triple and the toolchain. Widening the digest can only cause MORE
# rebuilds, never fewer, so it cannot introduce a stale artifact.
#
# Manifest shape (path, type, mode, content) then sort-then-hash mirrors
# scripts/hash-image-sources.sh, the repo's existing source-digest idiom, so a
# rename, a mode flip, or an added/removed file all move the digest.
sidecar_input_digest() {
    local manifest=() f rel mode content musl_installed
    musl_installed=no
    if command -v rustup >/dev/null 2>&1 &&
        rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
        musl_installed=yes
    fi
    manifest+=("target:${TARGET}")
    manifest+=("musl-target-installed:${musl_installed}")
    manifest+=("rustc:$(rustc -V 2>/dev/null || echo unknown)")
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        rel="${f#"$ROOT"/}"
        if ! mode="$(stat -c '%a' "$f" 2>/dev/null)"; then
            mode="$(stat -f '%Lp' "$f" 2>/dev/null || echo 0)"
        fi
        content="$(_sha256 <"$f")"
        manifest+=("${rel}:file:${mode}:${content}")
    done < <(find \
        "$ROOT/crates/tillandsias-router-sidecar" \
        "$ROOT/crates/tillandsias-otp" \
        "$ROOT/crates/tillandsias-control-wire" \
        "$ROOT/Cargo.toml" \
        "$ROOT/Cargo.lock" \
        "$ROOT/VERSION" \
        -type f -print 2>/dev/null)
    printf '%s\n' "${manifest[@]}" | LC_ALL=C sort | _sha256
}

# Staleness, content-addressed (order 765-5efu; replaces a `find -newer`
# probe). The mtime probe rebuilt whenever an input's TIMESTAMP moved, which a
# `git merge`/`checkout` does to byte-identical files — measured on this
# checkout: touching one sidecar source cost a 12.3s rebuild that produced a
# byte-identical binary. It was also foolable in the dangerous direction: the
# 723-b9cn note below worried that "a wrong binary left in place would be
# served to every later build as up-to-date", because mtime says nothing about
# WHICH bytes are staged.
#
# The stamp records both halves of the decision — the digest of the inputs and
# the digest of the artifact those inputs produced — so the build is skipped
# only when the inputs are unchanged AND the exact bytes previously built from
# them are still staged. Every other state rebuilds:
#   no staged binary / no stamp / unreadable stamp  -> build (fresh checkout, CI, release)
#   any input content, mode, path, or set change    -> build
#   toolchain or effective target change            -> build
#   staged bytes differ from what the stamp recorded-> build (tamper/corruption/wrong artifact)
# TILLANDSIAS_SIDECAR_FORCE_REBUILD=1 bypasses the stamp entirely.
is_stale() {
    [[ -f "$SIDECAR_DEST" ]] || return 0
    [[ "${TILLANDSIAS_SIDECAR_FORCE_REBUILD:-0}" == 1 ]] && return 0
    [[ -f "$SIDECAR_STAMP" ]] || return 0
    local want_inputs want_output
    want_inputs="$(sed -n 's/^inputs=//p' "$SIDECAR_STAMP" 2>/dev/null | head -1)"
    want_output="$(sed -n 's/^output=//p' "$SIDECAR_STAMP" 2>/dev/null | head -1)"
    [[ -n "$want_inputs" && -n "$want_output" ]] || return 0
    [[ "$(_sha256 <"$SIDECAR_DEST")" == "$want_output" ]] || return 0
    [[ "$(sidecar_input_digest)" == "$want_inputs" ]] || return 0
    return 1
}

# Record the evaluation that produced the currently staged bytes. Written
# ATOMICALLY (temp + mv) so a concurrent build.sh cannot read a half-written
# stamp — an unreadable stamp is handled above by rebuilding, but a TORN one
# that happened to parse would be worse than none.
write_sidecar_stamp() {
    local tmp
    tmp="$(mktemp "${SIDECAR_STAMP}.XXXXXX")" || return 0
    {
        printf '# tillandsias router-sidecar evaluation stamp (order 765-5efu).\n'
        printf '# Gitignored build artifact. Delete it to force a rebuild.\n'
        printf 'inputs=%s\n' "$(sidecar_input_digest)"
        printf 'output=%s\n' "$(_sha256 <"$SIDECAR_DEST")"
    } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    mv -f "$tmp" "$SIDECAR_STAMP" 2>/dev/null || rm -f "$tmp"
}

if ! is_stale; then
    echo "[build-sidecar] up-to-date: ${SIDECAR_DEST}"
    exit 0
fi

# Ensure the rustup target is installed if rustup is present.
# If rustup is missing or target addition fails (e.g. in containerized forge environments),
# fall back to compiling for the default host target so cargo build/check/test can proceed.
USE_TARGET=true
if ! command -v rustup >/dev/null 2>&1; then
    USE_TARGET=false
elif ! rustup target list --installed | grep -q "^${TARGET}\$"; then
    if ! rustup target add "${TARGET}" 2>/dev/null; then
        USE_TARGET=false
    fi
fi

if [[ "$USE_TARGET" == true ]]; then
    # @trace spec:cross-platform
    # Hosts whose system `cc` cannot drive an ELF link need rust-lld pinned.
    #
    # Windows (Git Bash / MSYS) has no `cc` in PATH at all, so the linker probe
    # fails with "linker `cc` not found".
    #
    # macOS (702-griq, measured 2026-08-12) has a `cc`, which is why it was
    # originally grouped with Linux here — but it is Apple clang driving ld64,
    # which cannot emit ELF and rejects the GNU linker flags rustc passes:
    #   ld: unknown options: --as-needed -Bstatic -Bdynamic --eh-frame-hdr
    #       -z --gc-sections --strip-all
    #   clang: error: linker command failed with exit code 1
    # Since 710-w9kc made this sidecar a REQUIRED build asset
    # (tillandsias-headless/build.rs include_bytes!s it), that link failure
    # means `cargo build` for the whole workspace fails on macOS — not just
    # this crate. Having a `cc` is not the same as having one that can link
    # for the target.
    #
    # Linux keeps the system cc resolution it has always used.
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32*|darwin*)
            # Var names are TARGET-derived (order 723-ji4v): the old literal
            # X86_64 spelling silently stopped applying the moment TARGET
            # became derivable, leaving aarch64 links to a cc that cannot
            # emit ELF.
            _triple_env="$(printf '%s' "$TARGET" | tr 'a-z-' 'A-Z_')"
            export "CARGO_TARGET_${_triple_env}_LINKER=rust-lld"
            export "CARGO_TARGET_${_triple_env}_RUSTFLAGS=-C link-self-contained=yes"
            ;;
    esac

    echo "[build-sidecar] cargo build --release --target ${TARGET} --bin tillandsias-router-sidecar --features unix-only"
    ( cd "$ROOT" && CARGO_TARGET_DIR="${SIDECAR_TARGET_DIR}" \
        cargo build --release --target "${TARGET}" --bin tillandsias-router-sidecar --features unix-only )
    SRC="${SIDECAR_TARGET_DIR}/${TARGET}/release/tillandsias-router-sidecar"
else
    echo "[build-sidecar] rustup/musl target not present — building sidecar with host target"
    echo "[build-sidecar] cargo build --release --bin tillandsias-router-sidecar --features unix-only"
    ( cd "$ROOT" && CARGO_TARGET_DIR="${SIDECAR_TARGET_DIR}" \
        cargo build --release --bin tillandsias-router-sidecar --features unix-only )
    SRC="${SIDECAR_TARGET_DIR}/release/tillandsias-router-sidecar"
fi

if [[ ! -f "$SRC" ]]; then
    echo "[build-sidecar] ERROR: build succeeded but binary not found at $SRC" >&2
    exit 3
fi

# Strip debug symbols — we ship the binary embedded in the tray and
# extracted into a container; a few MB matters.
strip "$SRC" 2>/dev/null || true

# ASSERT THE FORMAT BEFORE STAGING (order 723-b9cn).
#
# This binary has exactly two consumers and both are Linux: the router
# Containerfile COPYs it into the image, and tillandsias-headless/build.rs
# include_bytes!s it as a runtime asset extracted inside the guest. The
# host-target fallback above drops --target entirely, so on macOS it produces a
# Mach-O and stages it under a name that says "Linux musl router sidecar".
# Nothing downstream checks: `cargo check` goes green, `build.sh --check` goes
# green, and the failure surfaces only at exec time in a container, where
# images/router/entrypoint.sh gives up after ~5s and Caddy's forward_auth
# degrades to a 502 — so the tray reports a healthy router while web-session
# OTP gating is silently dead.
#
# scripts/build-guest-binaries.sh already verifies its own output this way; the
# sidecar did not. Removing the bad artifact matters as much as refusing: a bad
# binary left in place would be served to every later build as "up-to-date".
# (Since 765-5efu the staleness check hashes the STAGED BYTES against the
# stamp, so an unrecorded artifact is rebuilt rather than trusted — but this
# assert still runs against every fresh build, and removing the bad output is
# still what stops it reaching the stamp in the first place.)
if ! file "$SRC" | grep -q 'ELF'; then
    echo "[build-sidecar] ERROR: built sidecar is not a Linux ELF: $(file -b "$SRC")" >&2
    echo "[build-sidecar]   Its consumers are a Linux container image and the guest" >&2
    echo "[build-sidecar]   runtime asset, so a host-target build cannot be staged." >&2
    echo "[build-sidecar]   Install the cross target: rustup target add ${TARGET}" >&2
    rm -f "$SRC"
    exit 4
fi
# ...and the RIGHT ELF (order 723-ji4v): 723-b9cn's format assert accepted
# any ELF, so an x86-64 sidecar staged happily on an Apple-Silicon host whose
# guest is aarch64 — exactly the wrong-arch artifact this packet is about.
case "$TARGET" in
    x86_64-*)  WANT_ARCH_RE='x86-64' ;;
    aarch64-*) WANT_ARCH_RE='aarch64' ;;
    *)         WANT_ARCH_RE='' ;;
esac
if [[ -n "$WANT_ARCH_RE" ]] && ! file "$SRC" | grep -Eqi "$WANT_ARCH_RE"; then
    echo "[build-sidecar] ERROR: built sidecar is '$(file -b "$SRC")' but the target is ${TARGET} — wrong-arch artifact refused, not staged." >&2
    rm -f "$SRC"
    exit 4
fi

mkdir -p "$(dirname "$SIDECAR_DEST")"
# 765-uti9 quick win (velocity audit F6.3): the unconditional cp bumped the
# staged file's mtime even when the rebuild produced BYTE-IDENTICAL output
# (the common case after a VERSION-only bump — the binary embeds WIRE_VERSION,
# not VERSION), tripping tillandsias-headless's rerun-if-changed asset
# tracking and recompiling the workspace's largest crate across every
# compilation variant. Skipping the copy when bytes match is truthful: the
# staged artifact IS a fresh build's output; only the redundant mtime bump is
# elided. A real byte change always copies, and the ELF-format assert above
# ran against the fresh build either way. `touch` the dest so the is_stale
# find -newer probe stops re-offering the same no-op rebuild.
if [[ -f "$SIDECAR_DEST" ]] && cmp -s "$SRC" "$SIDECAR_DEST"; then
    touch "$SIDECAR_DEST"
    echo "[build-sidecar] staged copy already byte-identical to fresh build: ${SIDECAR_DEST} (mtime refreshed, no restage)"
else
    cp "$SRC" "$SIDECAR_DEST"
    chmod 0755 "$SIDECAR_DEST"
    SIZE="$(du -h "$SIDECAR_DEST" | cut -f1)"
    echo "[build-sidecar] staged: ${SIDECAR_DEST} (${SIZE})"
fi

# Record the evaluation LAST, and only on a path that reached a verified,
# staged artifact — the ELF assert and the staging above both precede it, so a
# refused build (exit 3/4) leaves the previous stamp untouched and the next
# invocation re-evaluates from scratch rather than trusting a failed run.
write_sidecar_stamp
