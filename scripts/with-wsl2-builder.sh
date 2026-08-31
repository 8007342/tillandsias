#!/usr/bin/env bash
# =============================================================================
# with-wsl2-builder.sh — Transparent WSL2 re-exec for Windows hosts
#
# The Windows sibling of with-tillandsias-builder.sh (Silverblue toolbox
# re-exec): detects a Windows Git-Bash/MSYS host, ensures a DEDICATED
# `tillandsias-build` WSL2 distro exists and carries the build toolchain
# (idempotent), and re-execs the calling command inside it — so ./build.sh,
# local-ci, ruby YAML validation, shellcheck, and other Linux-shaped build
# work run transparently on Windows (operator directive 2026-07-15).
#
# PLEASE REVIEW: linux — shared-scope build-entry wrapper added from the
# windows lane; mirrors the toolbox wrapper's structure and guards.
#
# Source this at the very top of any build/CI entry point (after the toolbox
# wrapper — each is a no-op off its platform):
#
#   source "$(dirname "$0")/scripts/with-wsl2-builder.sh"
#
# Or run standalone:
#
#   scripts/with-wsl2-builder.sh ./build.sh --check
#
# Non-Windows hosts pass through with zero overhead.
#
# DELIBERATELY NOT the runtime `tillandsias` distro: destructive smoke e2e
# unregisters that distro on every run — coupling the build environment to
# the smoke substrate would wipe toolchains mid-cycle. The build distro is
# imported once from the same cached Fedora rootfs the tray provisions from.
#
# Environment:
#   TILLANDSIAS_SKIP_WSL2=1          — force skip, run bare on host
#   TILLANDSIAS_BUILD_DISTRO=<name>  — distro name (default tillandsias-build)
#   TILLANDSIAS_WSL2_ROOTFS=<tar>    — rootfs tarball for first import
#                                      (default: newest *.rootfs.tar in the
#                                      tray cache %LOCALAPPDATA%\tillandsias\
#                                      cache\rootfs)
#   TILLANDSIAS_WSL2_TARGET_IN_TREE=1 — keep cargo target/ in the checkout
#                                      (default: distro-native CARGO_TARGET_DIR;
#                                      9p-backed target/ makes cargo crawl)
# =============================================================================

# `source` runs in the CALLER's shell, so these options would otherwise rewrite
# the sourcer's error handling permanently — the 731-pc5r shape, of which this
# file is the WSL2 sibling (order 764-sunk). local-ci.sh deliberately omits -e
# (run-every-check, report-at-end design), and an unconditional `set -e` here
# silently re-arms errexit there, killing the suite at its own advisory step on
# the happy path. The helper body still runs under its own strict options; the
# restore hands a sourcer back exactly the option state it entered with.
#
# Capture must NOT use a $(...) subshell: command substitution clears errexit
# (shopt inherit_errexit is off), so `$(set +o)` records -e as absent even when
# the caller had it. Read $- and [[ -o pipefail ]] in the current shell, and
# restore by REMOVING only what the caller lacked — the helper only ever adds.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    _W2_CALLER_FLAGS="$-"
    _W2_CALLER_PIPEFAIL=0
    [[ -o pipefail ]] && _W2_CALLER_PIPEFAIL=1
    # Idempotent; invoked EXPLICITLY at every sourced return site below. NOT a
    # RETURN trap: `trap - RETURN` issued inside the running handler does not
    # reliably clear across sourced-file boundaries — observed 2026-08-16 in the
    # sibling, where the trap re-fired at the NEXT sourced file's return with the
    # handler already unset, an instant command-not-found under the caller's
    # errexit. The re-exec paths below are `exec`, where caller options are moot.
    _w2_restore_caller_opts() {
        [[ -n "${_W2_CALLER_FLAGS:-}" ]] || return 0
        [[ "$_W2_CALLER_FLAGS" == *e* ]] || set +e
        [[ "$_W2_CALLER_FLAGS" == *u* ]] || set +u
        [[ "$_W2_CALLER_PIPEFAIL" == 1 ]] || set +o pipefail
        unset _W2_CALLER_FLAGS _W2_CALLER_PIPEFAIL
        return 0
    }
fi
set -euo pipefail

WSL2_SELF="${BASH_SOURCE[0]}"
BUILD_DISTRO="${TILLANDSIAS_BUILD_DISTRO:-tillandsias-build}"

_W2_DIRECT=0
[[ "${BASH_SOURCE[0]}" == "$0" ]] && _W2_DIRECT=1

# ── Guard: only trigger on Windows Git-Bash/MSYS hosts ────────────────────
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
        [[ "$_W2_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
        ! declare -F _w2_restore_caller_opts >/dev/null || _w2_restore_caller_opts
        return 0 2>/dev/null || exit 0
        ;;
esac

# ── Guard: explicit skip ──────────────────────────────────────────────────
if [[ "${TILLANDSIAS_SKIP_WSL2:-}" == "1" ]]; then
    [[ "$_W2_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    ! declare -F _w2_restore_caller_opts >/dev/null || _w2_restore_caller_opts
    return 0 2>/dev/null || exit 0
fi

# ── Guard: wsl.exe must be available ──────────────────────────────────────
if ! command -v wsl.exe &>/dev/null; then
    echo "[wsl2-builder] ERROR: wsl.exe not found — install WSL2 first:" >&2
    echo "    wsl --install --no-distribution   (then restart Windows)" >&2
    exit 1
fi

# wsl.exe pipe output is UTF-16LE — NUL-strip before any parse (same
# discipline as the tray's wsl_list_quiet).
_wsl_clean() { tr -d '\0' | tr -d '\r'; }

_build_distro_registered() {
    wsl.exe --list --quiet 2>/dev/null | _wsl_clean | grep -qxF "$BUILD_DISTRO"
}

# ── Ensure the build distro exists (import from the tray's cached rootfs) ─
if ! _build_distro_registered; then
    ROOTFS="${TILLANDSIAS_WSL2_ROOTFS:-}"
    if [[ -z "$ROOTFS" ]]; then
        CACHE_DIR="$(cygpath -u "${LOCALAPPDATA}")/tillandsias/cache/rootfs"
        ROOTFS="$(ls -t "$CACHE_DIR"/*.rootfs.tar 2>/dev/null | head -1 || true)"
    fi
    if [[ -z "$ROOTFS" || ! -f "$ROOTFS" ]]; then
        echo "[wsl2-builder] ERROR: no rootfs tarball for the first import." >&2
        echo "[wsl2-builder] Launch the Tillandsias tray once (it caches the Fedora" >&2
        echo "[wsl2-builder] rootfs under %LOCALAPPDATA%\\tillandsias\\cache\\rootfs)," >&2
        echo "[wsl2-builder] or point TILLANDSIAS_WSL2_ROOTFS at a Fedora rootfs tar." >&2
        exit 1
    fi
    INSTALL_DIR_WIN="${LOCALAPPDATA}\\tillandsias\\wsl-build"
    echo "[wsl2-builder] Importing '$BUILD_DISTRO' from $(basename "$ROOTFS") (first run)..."
    wsl.exe --import "$BUILD_DISTRO" "$INSTALL_DIR_WIN" "$(cygpath -w "$ROOTFS")" --version 2 \
        2>&1 | _wsl_clean
    _build_distro_registered || {
        echo "[wsl2-builder] ERROR: import did not register '$BUILD_DISTRO'." >&2
        exit 1
    }
fi

# ── Ensure the toolchain is initialized (idempotent, marker-gated) ────────
# Marker probe goes via STDIN: Git Bash (MSYS) rewrites leading-slash
# ARGUMENTS into C:/Program Files/Git/... paths, so `-- test -f /root/...`
# can never match; stdin bytes are never converted.
#
# ORDER 703-sjuk: the marker records WHICH init produced this distro, not
# merely that some init once ran. A bare existence marker cannot see that the
# package list changed, so every already-initialized host silently keeps the
# old toolchain forever — the jq/yq omission above would have been fixed for
# new hosts only, and this host, which found it, would never have picked it up.
# That is the same "a staleness check that cannot see what changed" shape as
# 695-r7k8 (staging skipped on a VERSION match) and 689-gipe (the tray embedded
# whatever was staged); the fix is the same in kind — stamp the marker with a
# digest of the thing that can change, and re-run when it differs.
init_digest="$(
    sed -n '/^# WSL2_INIT_BEGIN$/,/^WSL2_INIT$/p' "${BASH_SOURCE[0]}" \
        | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } \
        | cut -c1-16
)"
marker="/root/.cache/tillandsias/wsl2-builder-initialized"
if ! printf 'test "$(cat %s 2>/dev/null)" = "%s"\n' "$marker" "$init_digest" \
        | wsl.exe -d "$BUILD_DISTRO" -u root -- sh 2>/dev/null; then
    echo "[wsl2-builder] Initializing '$BUILD_DISTRO' with build tools (init digest ${init_digest})..."
    # Same package set as the Silverblue toolbox init, plus curl for rustup
    # and shellcheck/git for the CI helpers. stdin-delivered script: wsl
    # arg-joined multi-line scripts get re-parsed by the guest login shell
    # and arrive shredded (order-326 live repro, 2026-07-15).
    # The digest above is computed over the region between WSL2_INIT_BEGIN and
    # the heredoc terminator, so editing ANY line of the init below invalidates
    # every host's marker on the next run. Keep the marker write last.
    wsl.exe -d "$BUILD_DISTRO" -u root -- sh <<'WSL2_INIT'
# WSL2_INIT_BEGIN
set -eu
# musl-gcc/musl-devel/musl-libc-static: the cargo fallback in
# scripts/build-guest-binaries.sh cross-compiles the musl guest binary, and
# ring's build script hard-requires x86_64-linux-musl-gcc (first hit on the
# Esmeralda Windows host, 2026-08-08).
# jq/yq (order 703-sjuk): this distro is where ./build.sh re-execs and where
# the litmus corpus runs, and it had NEITHER. Two consequences went unnoticed
# for as long as the distro has existed:
#   - run-litmus-test.sh warns "yq/jq not found; using fallback grep-based
#     parsing - reduced functionality" and silently grades the corpus with a
#     weaker parser;
#   - check-stranded-in-progress.sh took its jq-absent branch, which until
#     702-68zj printed `in_progress=0 stranded=0` — a clean all-clear, on every
#     run, in the one environment where checks actually execute.
# Both tools are packaged in Fedora, so the absence was an omission, not a
# constraint.
dnf install -y \
    gcc pkg-config file cmake make \
    musl-gcc musl-devel musl-libc-static \
    openssl-devel systemd-devel \
    ruby perl-FindBin \
    procps-ng findutils diffutils \
    git curl tar xz ShellCheck awk \
    jq yq \
    2>&1 | sed 's/^/  [dnf] /'
if ! command -v rustup >/dev/null 2>&1 && [ ! -x /root/.cargo/bin/rustup ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh
    sh /tmp/rustup-init.sh -y 2>&1 | sed 's/^/  [rustup] /'
    rm -f /tmp/rustup-init.sh
fi
. /root/.cargo/env
rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl \
    2>&1 | sed 's/^/  [rustup] /'
mkdir -p /root/.cache/tillandsias
echo "[wsl2-builder] init complete"
WSL2_INIT
    # Stamp the marker with the digest ONLY after the init returned zero, and
    # from the host, which is the side that knows the digest. A marker written
    # inside the init could not name the version it came from, and a marker
    # written unconditionally would record success for a failed dnf run — the
    # distro would then be permanently, silently under-provisioned, which is
    # the failure this whole change is about.
    printf 'mkdir -p /root/.cache/tillandsias && printf %%s "%s" > %s\n' \
        "$init_digest" "$marker" \
        | wsl.exe -d "$BUILD_DISTRO" -u root -- sh
fi

# ── Re-exec inside the build distro ───────────────────────────────────────
# `wsl --cd` accepts the Windows path and translates it (the checkout lands
# at /mnt/c/... via automount, which the build distro keeps enabled —
# unlike the runtime distro). Cargo's target dir defaults to a
# distro-NATIVE path: metadata-heavy cargo I/O over 9p is unusably slow,
# and check/clippy/test consumers don't need in-tree artifacts.
PWD_WIN="$(pwd -W 2>/dev/null || cygpath -w "$(pwd)")"
REPO_BASENAME="$(basename "$(pwd)")"

ARGS_QUOTED=""
for arg in "$@"; do
    ARGS_QUOTED="$ARGS_QUOTED$(printf '%q ' "$arg")"
done

# ORDER 889-8tcb — `wsl.exe` does NOT forward the caller's environment, so
# every TILLANDSIAS_* control flag died silently at this boundary. The one
# that mattered: TILLANDSIAS_FORCE_CHECK=1, the documented escape hatch for a
# stale gate memo, was inert on Windows — measured on yolanda while the
# exec-bit deadlock made it the only lever left. Setting WSLENV by hand did
# work, which is the proof the value simply never crossed.
#
# This is the same fix scripts/with-tillandsias-builder.sh:299 already carries
# for the toolbox boundary, with the same precedent in its comment. The Windows
# dispatch was the outlier, and a control flag that works on one platform's
# dispatch and not the other's is worse than one that works on neither, because
# only one of those gets noticed.
#
# TILLANDSIAS_SKIP_WSL2 is exported AFTER this string, so the recursion guard
# always wins over anything forwarded here.
_ENV_FORWARD=""
while IFS= read -r _w2_var; do
    _ENV_FORWARD="${_ENV_FORWARD}export $(printf '%q' "$_w2_var")=$(printf '%q' "${!_w2_var}"); "
done < <(compgen -v | grep '^TILLANDSIAS_' || true)

# ORDER 922-curm — the TILLANDSIAS_SKIP_TOOLBOX=1 that stood here is GONE, and
# its removal is the point rather than a tidy-up. 889-8tcb set it at this
# boundary as a same-hour mitigation for a total Windows blocker: the toolbox
# script's FATAL fired inside the distro because its "Windows is handled by the
# /etc/os-release guard" claim was false. 922-curm fixed that at the source —
# with-tillandsias-builder.sh now detects WSL from /proc/version — so keeping
# the flag here would leave TWO mechanisms for one fact, and the second would
# be unexercised on every host that could notice it breaking. That is the
# objection lenovinha raised against a core.fileMode conditional on 889-8tcb,
# and it applies to my own mitigation. Verified live before removal: with the
# flag cleared, with-tillandsias-builder.sh passes straight through inside the
# tillandsias-build distro.
_ENV_PREFIX="${_ENV_FORWARD}export TILLANDSIAS_SKIP_WSL2=1; . /root/.cargo/env 2>/dev/null || true;"
if [[ "${TILLANDSIAS_WSL2_TARGET_IN_TREE:-}" != "1" ]]; then
    _ENV_PREFIX="$_ENV_PREFIX export CARGO_TARGET_DIR=\"/root/.cache/tillandsias-wsl2-target/$REPO_BASENAME\";"
fi

echo "[wsl2-builder] Re-execing inside '$BUILD_DISTRO' WSL2 distro..."

if [[ "$_W2_DIRECT" == 1 ]]; then
    if [[ $# -eq 0 ]]; then
        echo "usage: $WSL2_SELF <command> [args...]" >&2
        exit 2
    fi
    exec wsl.exe -d "$BUILD_DISTRO" -u root --cd "$PWD_WIN" -- \
        bash -c "$_ENV_PREFIX exec $ARGS_QUOTED"
fi

# Sourced from a build script: $0/$@ are the calling script and its args.
# Re-exec it via a path RELATIVE to the checkout (the absolute Git-Bash
# /c/... form does not exist inside the distro).
SCRIPT_REL="$(realpath --relative-to="$(pwd)" "$0")"
exec wsl.exe -d "$BUILD_DISTRO" -u root --cd "$PWD_WIN" -- \
    bash -c "$_ENV_PREFIX exec bash $(printf '%q' "./$SCRIPT_REL") $ARGS_QUOTED"
