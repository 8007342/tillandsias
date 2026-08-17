#!/usr/bin/env bash
# @trace spec:ci-release
#
# Build both guest binaries (x86_64 and aarch64) using Nix (since the flake
# is hermetic and release.yml uses it) and stage them into target-guest/
# for consumption by tray builders.
#
# Usage:
#   ./scripts/build-guest-binaries.sh           # Build and stage binaries
#   ./scripts/build-guest-binaries.sh --verify  # Verify staged binaries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_VAL="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TARGET_DIR="$ROOT/target-guest"

X86_64_NAME="tillandsias-headless-x86_64-unknown-linux-musl"
AARCH64_NAME="tillandsias-headless-aarch64-unknown-linux-musl"

X86_64_DEST="$TARGET_DIR/$X86_64_NAME"
AARCH64_DEST="$TARGET_DIR/$AARCH64_NAME"

verify_binaries() {
    echo "[build-guest-binaries] Verifying staged binaries in $TARGET_DIR..."
    
    # 1. Existence and executability
    if [[ ! -f "$X86_64_DEST" ]]; then
        echo "[build-guest-binaries] ERROR: Missing x86_64 binary at $X86_64_DEST" >&2
        return 1
    fi
    if [[ ! -f "$AARCH64_DEST" ]]; then
        echo "[build-guest-binaries] ERROR: Missing aarch64 binary at $AARCH64_DEST" >&2
        return 1
    fi
    
    if [[ ! -x "$X86_64_DEST" ]]; then
        echo "[build-guest-binaries] ERROR: $X86_64_DEST is not executable" >&2
        return 1
    fi
    if [[ ! -x "$AARCH64_DEST" ]]; then
        echo "[build-guest-binaries] ERROR: $AARCH64_DEST is not executable" >&2
        return 1
    fi

    # 2. File static + arch check
    local x86_file_info
    x86_file_info="$(file "$X86_64_DEST")"
    if [[ ! "$x86_file_info" =~ "x86-64" || ! "$x86_file_info" =~ "statically linked" ]]; then
        echo "[build-guest-binaries] ERROR: $X86_64_DEST is not a statically linked x86-64 ELF" >&2
        echo "File info: $x86_file_info" >&2
        return 1
    fi

    local arm_file_info
    arm_file_info="$(file "$AARCH64_DEST")"
    if [[ ! "$arm_file_info" =~ "aarch64" || ! "$arm_file_info" =~ "statically linked" ]]; then
        echo "[build-guest-binaries] ERROR: $AARCH64_DEST is not a statically linked aarch64 ELF" >&2
        echo "File info: $arm_file_info" >&2
        return 1
    fi

    # 3. Version stamp check
    # For x86_64, if running on x86_64 architecture, we can execute it directly to check version
    if [[ "$(uname -m)" == "x86_64" ]]; then
        local x86_version
        x86_version="$("$X86_64_DEST" --version)"
        if [[ "$x86_version" != "Tillandsias v$VERSION_VAL" ]]; then
            echo "[build-guest-binaries] ERROR: $X86_64_DEST version '$x86_version' does not match VERSION 'Tillandsias v$VERSION_VAL'" >&2
            return 1
        fi
        echo "[build-guest-binaries] ✓ x86_64 version check passed: $x86_version"
    else
        # Fallback to strings check if not on x86_64
        if ! strings "$X86_64_DEST" | grep -F "$VERSION_VAL" >/dev/null; then
            echo "[build-guest-binaries] ERROR: $X86_64_DEST does not contain version string '$VERSION_VAL'" >&2
            return 1
        fi
        echo "[build-guest-binaries] ✓ x86_64 strings version check passed"
    fi

    # For aarch64, we can do strings check as we cannot run aarch64 on x86_64 natively
    if ! strings "$AARCH64_DEST" | grep -F "$VERSION_VAL" >/dev/null; then
        echo "[build-guest-binaries] ERROR: $AARCH64_DEST does not contain version string '$VERSION_VAL'" >&2
        return 1
    fi
    echo "[build-guest-binaries] ✓ aarch64 strings version check passed"

    echo "[build-guest-binaries] ✓ Verification SUCCESS: both binaries are correct and match VERSION $VERSION_VAL."
    return 0
}

# Order 447: staleness is HOST STAGING STATE, not a code regression. In CI
# the guest binaries are always built fresh so a version mismatch there is
# impossible-by-construction; on a dev host, target-guest/ routinely predates
# the current VERSION (any --install bump leaves it behind). --verify must
# therefore SKIP CLEANLY on stale/absent staging (rebuilding inside an
# instant litmus is not viable) and fail loud ONLY on a genuine integrity
# defect of a current-stamped binary (wrong arch, not static, not
# executable, corrupted stamp). Falsifiable grammar on the last line:
#   verify:ok | verify:skip-stale-staging | (non-zero exit on real defect)
staging_is_current() {
    [[ -f "$X86_64_DEST" && -f "$AARCH64_DEST" ]] || return 1
    strings "$X86_64_DEST" | grep -F "$VERSION_VAL" >/dev/null || return 1
    strings "$AARCH64_DEST" | grep -F "$VERSION_VAL" >/dev/null || return 1
    return 0
}

# Parse argument
VERIFY_ONLY=false
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--verify" ]]; then
        VERIFY_ONLY=true
    else
        echo "Usage: $0 [--verify]" >&2
        exit 3
    fi
fi

if [[ "$VERIFY_ONLY" == true ]]; then
    if ! staging_is_current; then
        echo "[build-guest-binaries] SKIP: staged guest binaries are stale or absent (host staging predates VERSION $VERSION_VAL)."
        echo "[build-guest-binaries] This is host staging state, not a code regression (order 447); run scripts/build-guest-binaries.sh to restage."
        echo "verify:skip-stale-staging"
        exit 0
    fi
    verify_binaries
    echo "verify:ok"
    exit 0
fi

# Order 695-r7k8: is any Rust source newer than the staged binaries?
#
# `verify_binaries` alone is NOT a currency check. It tests existence, arch,
# staticness and the VERSION *string* — and a VERSION stamp only rolls on
# release, so every source change between releases satisfies all of it while
# leaving the staged binary stale. The script then printed "up-to-date" and
# verified SUCCESS, and the old code shipped: into the tray's embedded asset,
# and from there into fresh guests. (That was the first link of the chain
# 689-gipe and 620-duta walked back from; see the deliverable.)
#
# mtime, not a content hash: the failure to kill is "silently skipped", and a
# timestamp comparison kills it for a fraction of the complexity. Prefer
# rebuilding a touched-but-unchanged tree over skipping a changed one — cargo
# makes the false positive cheap, while the false negative ships stale code.
sources_newer_than_staging() {
    # Absent staging is trivially out of date; verify_binaries also catches
    # this, but returning early keeps `find -newer` from running without a
    # reference file (where it would error and be read as "no hits").
    [[ -f "$X86_64_DEST" && -f "$AARCH64_DEST" ]] || return 0

    # Compare against the OLDER of the two staged binaries, so a source edit
    # between the two builds cannot hide behind the newer one.
    local reference="$X86_64_DEST"
    [[ "$AARCH64_DEST" -ot "$reference" ]] && reference="$AARCH64_DEST"

    local root_file
    for root_file in "$ROOT/Cargo.toml" "$ROOT/Cargo.lock"; do
        [[ -f "$root_file" && "$root_file" -nt "$reference" ]] && return 0
    done

    # -quit on the first hit: this runs on every tray build and the answer is
    # boolean, so there is no reason to walk the rest of the tree.
    local hit
    hit="$(find "$ROOT/crates" \
        \( -type d -name target -prune \) -o \
        -type f \( -name '*.rs' -o -name 'Cargo.toml' \) -newer "$reference" -print -quit \
        2>/dev/null)"
    [[ -n "$hit" ]]
}

# Build path
# First check if current staged files are already present, valid, AND at least
# as new as every source they are built from. If so, skip the build to keep dev
# fast.
if verify_binaries >/dev/null 2>&1; then
    if sources_newer_than_staging; then
        echo "[build-guest-binaries] Staged binaries carry VERSION $VERSION_VAL but a source file is newer — rebuilding (order 695-r7k8; a VERSION match is not a currency check)."
    else
        echo "[build-guest-binaries] Staged binaries are up-to-date. Skipping build."
        verify_binaries
        exit 0
    fi
fi

# Order 790-mbk9. Turn a nix out-link into a path that actually holds the
# built bytes, and print it. MEASURED on macuahuitl 2026-08-17, because this is
# the exact risk the packet was filed with as INFERRED and it turned out to be
# real: with `--store <dir>`, `nix build --out-link L` writes a symlink to the
# LOGICAL store path (`/nix/store/<hash>-name`), not to where the bytes live.
# On a host whose store is elsewhere that link dangles —
#
#     .nix-probe-hx -> /nix/store/a2qmpfw70…-tillandsias-headless-x86_64-0.0.0
#     test -f .nix-probe-hx/bin/tillandsias            -> rc=1   (dangles)
#     <store>/nix/store/a2qmpfw70…/bin/tillandsias     -> 13849840 bytes
#
# — so the pre-existing `install .nix-output/result-hx/bin/tillandsias` line
# could never have worked on the chroot rung. Routing alone would have turned
# a silent cargo degradation into a loud failure, which is better but still
# broken; the physical path is the store root prefixed onto the logical one.
# Prefer the link when it resolves (the daemon rung, where logical == physical)
# so the daemon path is untouched.
resolve_out_link() { # <out-link> <store-root-or-empty> ; prints a binary path
    local link="$1" store_root="$2" target
    if [[ -f "$link/bin/tillandsias" ]]; then
        printf '%s\n' "$link/bin/tillandsias"
        return 0
    fi
    target="$(readlink "$link" 2>/dev/null)" || return 1
    [[ -n "$target" && -n "$store_root" ]] || return 1
    if [[ -f "$store_root$target/bin/tillandsias" ]]; then
        printf '%s\n' "$store_root$target/bin/tillandsias"
        return 0
    fi
    return 1
}

# The gate used to be `command -v nix`, which is a claim that a
# BINARY EXISTS, not evidence that it can BUILD. On a daemonless host — the
# operator's standing configuration, not an accident (777-amku: "we agreed to
# use toolboxes for everything; never require a host daemon when a toolbox can
# carry the tool") — nix is installed, the gate passed, and then BOTH builds
# died with `cannot connect to socket at '/nix/var/nix/daemon-socket/socket'`.
# The caller caught the non-zero return and degraded to cargo, so the lane was
# dead code that looked available: every `--ci-full --install` paid a failed
# attempt and never reached the chroot rung that works here.
#
# Same principle as the plan-binary probe's `capabilities` test (721-nyev): ask
# scripts/nix-toolbox.sh which rung ACTUALLY works and take its flags, rather
# than inferring capability from presence. nix-toolbox.sh itself learned this
# the hard way — its own header records that `nix eval` answers fine with the
# daemon dead, so it probes `store ping` instead.
build_with_nix() {
    local nix_tb="$ROOT/scripts/nix-toolbox.sh"
    if [[ ! -x "$nix_tb" ]]; then
        echo "[build-guest-binaries] nix lane SKIPPED: $nix_tb missing or not executable." >&2
        return 1
    fi

    local verdict
    if ! verdict="$("$nix_tb" ensure 2>&1)"; then
        echo "[build-guest-binaries] nix lane UNAVAILABLE: $verdict" >&2
        return 1
    fi

    # `nix-args` serves the daemon and chroot rungs. The toolbox rung runs nix
    # INSIDE a container, where this script's paths ($ROOT, $TARGET_DIR) are not
    # the paths nix would write to — staging from here would be wrong in a way
    # that only shows up as a stale or missing binary later. Refuse it by name
    # instead of guessing; the cargo fallback is the correct answer on such a
    # host until someone verifies the container path mapping.
    local nix_args=()
    local arg
    local nix_store_dir=""
    local want_store=0
    while IFS= read -r arg; do
        [[ -n "$arg" ]] || continue
        nix_args+=("$arg")
        # Remember the store root: on the chroot rung it is where the built
        # bytes physically live, which the out-link does NOT point at (see
        # stage_out_link below).
        if [[ "$want_store" == 1 ]]; then
            nix_store_dir="$arg"
            want_store=0
        elif [[ "$arg" == "--store" ]]; then
            want_store=1
        fi
    done < <("$nix_tb" nix-args 2>/dev/null)
    if [[ ${#nix_args[@]} -eq 0 ]]; then
        echo "[build-guest-binaries] nix lane UNAVAILABLE: $verdict serves no host-side store arguments (the toolbox rung runs nix in a container whose paths are not this checkout's; staging from here is unverified)." >&2
        return 1
    fi

    echo "[build-guest-binaries] Building guest binaries using Nix ($verdict)..."
    mkdir -p "$ROOT/.nix-output"
    nix "${nix_args[@]}" build -L .#tillandsias-headless-x86_64-musl   --out-link "$ROOT/.nix-output/result-hx" || return 1
    nix "${nix_args[@]}" build -L .#tillandsias-headless-aarch64-musl  --out-link "$ROOT/.nix-output/result-ha" || return 1

    local hx ha
    hx="$(resolve_out_link "$ROOT/.nix-output/result-hx" "$nix_store_dir")" || {
        echo "[build-guest-binaries] ERROR: the x86_64 out-link does not resolve to a binary ($verdict). Store root: ${nix_store_dir:-<host>}" >&2
        return 1
    }
    ha="$(resolve_out_link "$ROOT/.nix-output/result-ha" "$nix_store_dir")" || {
        echo "[build-guest-binaries] ERROR: the aarch64 out-link does not resolve to a binary ($verdict). Store root: ${nix_store_dir:-<host>}" >&2
        return 1
    }

    mkdir -p "$TARGET_DIR"
    install -m 0755 "$hx" "$X86_64_DEST" || return 1
    install -m 0755 "$ha" "$AARCH64_DEST" || return 1

    # Remove symlinks to keep directory clean
    rm -rf "$ROOT/.nix-output/result-hx" "$ROOT/.nix-output/result-ha"
}

build_with_cargo() {
    command -v cargo >/dev/null 2>&1 || return 1

    echo "[build-guest-binaries] Building guest binaries using local Cargo fallback..."
    # Features MUST match the Nix packages (flake.nix tillandsias-headless-*-musl:
    # `--features listen-vsock`). `--features tray` does NOT enable the vsock
    # listener, producing a guest that boots but never binds the control wire
    # (handshake timeout on a pristine provision — order 282 e2e, 2026-07-11).
    cargo build --package tillandsias-headless --bin tillandsias \
        --release --target x86_64-unknown-linux-musl --features listen-vsock \
        --manifest-path "$ROOT/Cargo.toml" || return 1
    if command -v aarch64-linux-musl-gcc >/dev/null 2>&1; then
        cargo build --package tillandsias-headless --bin tillandsias \
            --release --target aarch64-unknown-linux-musl --features listen-vsock \
            --manifest-path "$ROOT/Cargo.toml" || return 1
    elif command -v clang >/dev/null 2>&1; then
        CC_aarch64_unknown_linux_musl=clang \
        CFLAGS_aarch64_unknown_linux_musl='--target=aarch64-linux-musl' \
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
            cargo build --package tillandsias-headless --bin tillandsias \
                --release --target aarch64-unknown-linux-musl --features listen-vsock \
                --manifest-path "$ROOT/Cargo.toml" || return 1
    else
        echo "[build-guest-binaries] ERROR: missing aarch64 musl linker." >&2
        echo "[build-guest-binaries] Install aarch64-linux-musl-gcc or clang + rust-lld." >&2
        return 1
    fi

    # Stage from the same target root cargo wrote to: CARGO_TARGET_DIR (set by
    # scripts/with-wsl2-builder.sh, among others) redirects the build away from
    # $ROOT/target, and staging from a hardcoded $ROOT/target picks up whatever
    # stale artifact last landed there (staged v0.3.260715.6 as v0.4.260802.1
    # on 2026-08-03; only verify_binaries' version check caught it).
    local cargo_target_root="${CARGO_TARGET_DIR:-$ROOT/target}"
    mkdir -p "$TARGET_DIR"
    install -m 0755 "$cargo_target_root/x86_64-unknown-linux-musl/release/tillandsias" "$X86_64_DEST" || return 1
    install -m 0755 "$cargo_target_root/aarch64-unknown-linux-musl/release/tillandsias" "$AARCH64_DEST" || return 1
}

if ! build_with_nix; then
    # Order 790-mbk9: the fallback is legitimate, but it must never be reached
    # silently — the reason is printed by build_with_nix immediately above, and
    # naming the DEGRADATION here (rather than the vague "Nix build
    # unavailable") is what makes a host-fixable cause visible in a CI log.
    echo "[build-guest-binaries] DEGRADED to the local Cargo fallback (reason above). The release lane builds guest binaries with Nix; a host that cannot is building them differently." >&2
    if ! build_with_cargo; then
        echo "[build-guest-binaries] ERROR: failed to build guest binaries with Nix or local Cargo." >&2
        exit 1
    fi
fi

verify_binaries
