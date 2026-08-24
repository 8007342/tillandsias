#!/usr/bin/env bash
# =============================================================================
# with-tillandsias-builder.sh — Transparent toolbox re-exec for Silverblue
#
# Detects whether this host is Fedora Silverblue (immutable). If so, checks
# whether the current process is already inside the `tillandsias-builder`
# toolbox. If not, creates the toolbox (idempotent), initializes it with
# required build tools (idempotent), and re-execs the calling command inside
# the toolbox — all transparently.
#
# Source this at the very top of any build/CI entry point that needs
# Rust/gcc/ruby etc:
#
#   source "$(dirname "$0")/scripts/with-tillandsias-builder.sh"
#
# Or run standalone:
#
#   scripts/with-tillandsias-builder.sh ./build.sh --check
#
# Non-Silverblue hosts (Workstation, macOS, Windows) pass through with zero
# overhead.
#
# Environment:
#   TILLANDSIAS_SKIP_TOOLBOX=1  — force skip, run bare on host
# =============================================================================

# `source` runs in the CALLER's shell, so these options would otherwise rewrite
# the sourcer's error handling permanently — the 731-pc5r leak: local-ci.sh
# deliberately omits -e (run-every-check, report-at-end design), and this line
# silently re-armed errexit there, killing the suite at its own advisory step on
# the happy path. The helper body still runs under its own strict options; the
# RETURN trap hands a sourcer back exactly the option state it entered with
# (every guard's `return` and the end-of-file return all pass through it; the
# re-exec paths replace the process, where caller options are moot).
# Capture must NOT use a $(...) subshell: command substitution clears errexit
# (shopt inherit_errexit is off), so `$(set +o)` records -e as absent even when
# the caller had it. Read $- and [[ -o pipefail ]] in the current shell, and
# restore by REMOVING only what the caller lacked — the helper only ever adds.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    _TB_CALLER_FLAGS="$-"
    _TB_CALLER_PIPEFAIL=0
    [[ -o pipefail ]] && _TB_CALLER_PIPEFAIL=1
    # Idempotent; invoked EXPLICITLY at every sourced return site below (the
    # two terminal paths are `exec`, where caller options are moot). NOT a
    # RETURN trap: `trap - RETURN` issued inside the running handler does not
    # reliably clear across sourced-file boundaries — observed 2026-08-16: the
    # trap re-fired at the NEXT sourced file's return in build.sh (line 39,
    # with-wsl2-builder.sh) with the handler already unset, an instant
    # command-not-found under the caller's errexit.
    _tb_restore_caller_opts() {
        [[ -n "${_TB_CALLER_FLAGS:-}" ]] || return 0
        [[ "$_TB_CALLER_FLAGS" == *e* ]] || set +e
        [[ "$_TB_CALLER_FLAGS" == *u* ]] || set +u
        [[ "$_TB_CALLER_PIPEFAIL" == 1 ]] || set +o pipefail
        unset _TB_CALLER_FLAGS _TB_CALLER_PIPEFAIL
        return 0
    }
fi
set -euo pipefail

SELF="${BASH_SOURCE[0]}"
TOOLBOX_NAME="${TILLANDSIAS_BUILDER_TOOLBOX:-tillandsias-builder}"
MARKER_FILE="$HOME/.cache/tillandsias/builder-toolbox-initialized"

# Direct invocation (`scripts/with-tillandsias-builder.sh <cmd> [args...]`)
# runs <cmd> in the build environment; sourced invocation re-execs the calling
# script inside the toolbox. Every skip-guard below must therefore run the
# command for the direct case instead of silently returning — a bare
# `return 0 || exit 0` turns a direct call into a no-op that lies with exit 0.
_TB_DIRECT=0
[[ "${BASH_SOURCE[0]}" == "$0" ]] && _TB_DIRECT=1

# ── Guard: skip if already inside the builder toolbox ─────────────────────
if [[ -n "${TOOLBOX_PATH:-}" ]]; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    ! declare -F _tb_restore_caller_opts >/dev/null || _tb_restore_caller_opts
    return 0 2>/dev/null || exit 0
fi

# ── Guard: skip inside any OCI/container runtime ──────────────────────────
if [[ "${container:-}" == "oci" ]] || [[ "${container:-}" == "podman" ]]; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    ! declare -F _tb_restore_caller_opts >/dev/null || _tb_restore_caller_opts
    return 0 2>/dev/null || exit 0
fi

# ── Guard: explicit skip ─────────────────────────────────────────────────
if [[ "${TILLANDSIAS_SKIP_TOOLBOX:-}" == "1" ]]; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    ! declare -F _tb_restore_caller_opts >/dev/null || _tb_restore_caller_opts
    return 0 2>/dev/null || exit 0
fi

# ── Guard: only trigger on Silverblue / rpm-ostree hosts ──────────────────
if [[ ! -f /etc/os-release ]]; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    ! declare -F _tb_restore_caller_opts >/dev/null || _tb_restore_caller_opts
    return 0 2>/dev/null || exit 0
fi

VARIANT_ID="$(grep -oP '^VARIANT_ID=\K.*' /etc/os-release 2>/dev/null || true)"
if [[ "$VARIANT_ID" != "silverblue" ]] && ! command -v rpm-ostree &>/dev/null; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    ! declare -F _tb_restore_caller_opts >/dev/null || _tb_restore_caller_opts
    return 0 2>/dev/null || exit 0
fi

# ── Guard: toolbox binary must be installed ──────────────────────────────
if ! command -v toolbox &>/dev/null; then
    echo "[tillandsias-builder] ERROR: 'toolbox' not found on Silverblue." >&2
    echo "[tillandsias-builder] Install it:" >&2
    echo "    rpm-ostree install toolbox" >&2
    echo "    (or: sudo dnf install --skip-broken toolbox)" >&2
    echo "[tillandsias-builder] Then reboot and retry." >&2
    exit 1
fi

# ── Neutralize enclave-only proxy env for host podman operations ─────────
# tillandsias --init writes an enclave-only proxy (http://proxy:3128) into
# ~/.config/containers/containers.conf [engine] env; podman injects those vars
# into its own image pulls and every container it launches. That hostname only
# resolves inside enclave pod networks, so on the host it poisons the
# `toolbox create` image pull and dnf/rustup/cargo inside the builder toolbox
# (plan/issues/podman-proxy-reset-chicken-and-egg-2026-07-08.md). An empty
# value set in the spawning environment overrides [engine] env — the same
# pattern as BUILD_PROXY_NEUTRALIZE_VARS in tillandsias-headless. A proxy var
# the operator really set stays untouched. The loop lived here by hand since
# order 116; it is now the SHARED neutralizer (order 653-zzkb) so the next
# call site cannot re-diverge from this one.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/podman-neutralize-proxy.sh"

# ── Helper: exact-match the CONTAINER NAME column (list output is columned,
#    so a whole-line grep -x can never match) ──────────────────────────────
_toolbox_exists() {
    toolbox list --containers 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -qxF "$TOOLBOX_NAME"
}

# ── Helper: full build toolchain initialized inside the toolbox ──────────
# Gates the (idempotent) init block on the ACTUAL tool set ./build.sh needs
# (gcc, pkg-config, ruby, rustup + the musl targets), not merely on rustup.
# A toolbox with only rustup present but missing gcc/pkg-config must re-run
# init so `./build.sh --check` does not fail with "Missing host build tools".
_toolbox_initialized() {
    toolbox run --container "$TOOLBOX_NAME" \
        bash -c 'command -v gcc && command -v musl-gcc && command -v pkg-config && command -v ruby && command -v rustup && command -v jq && command -v yq && command -v rg && command -v openssl && command -v x86_64-w64-mingw32-gcc && rustup target list --installed 2>/dev/null | grep -qxF x86_64-unknown-linux-musl && rustup target list --installed 2>/dev/null | grep -qxF x86_64-pc-windows-gnu' \
        &>/dev/null 2>&1
}

# ── Ensure toolbox exists and is initialized ──────────────────────────────
if ! _toolbox_exists; then
    echo "[tillandsias-builder] Creating '$TOOLBOX_NAME' toolbox (first run)..."
    # --assumeyes: a pristine host has no fedora-toolbox image cached, and a
    # non-interactive `toolbox create` refuses to download it without consent.
    toolbox create --assumeyes --container "$TOOLBOX_NAME"
fi

if ! _toolbox_initialized; then
    echo "[tillandsias-builder] Initializing '$TOOLBOX_NAME' with build tools..."

    # musl-gcc: the rustup musl TARGET alone is not enough — the musl-static
    # portable launcher pulls `ring`, whose cc-rs build script needs a musl C
    # cross-compiler. A toolbox without it fails `--install` at ring with
    # "failed to find tool x86_64-linux-musl-gcc" (yoga, 2026-08-23). The
    # _toolbox_initialized probe above requires it so pre-existing toolboxes
    # re-run this init and pick it up.
    # mingw64-gcc + the x86_64-pc-windows-gnu rustup target: what
    # scripts/check-cross-target-build.sh (656-spux) needs to build the
    # workspace for a NON-HOST target. Without them that gate prints
    # `skip:cross-target:...` and every host keeps compiling only for itself,
    # which is the blind spot the packet exists to close — a cfg-gated defect is
    # invisible from the host most likely to introduce it, and the gate's first
    # run found exactly such a break sitting on trunk.
    #
    # THE COST IS SMALLER THAN IT LOOKS, and I got this wrong once. 115 MiB
    # installed reads as a lot until it is set against the 2.8 GB /usr and 1.9 GB
    # rustup this toolbox already carries — roughly 2% of an environment whose
    # entire purpose is compiling. The RECURRING cost is 0.3s per gate run
    # (profiled), not the ~37s I first recorded: that figure was the one-off
    # first build of every dependency for the new target, not steady state.
    #
    # jq/yq/ripgrep/openssl: the toolbox-first dispatch pattern
    # (methodology multi_host_development.toolbox_first_scripts) is only valid
    # for tools the toolbox HAS, and it had none of these — so the ~50 scripts
    # that call bare `jq`/`rg`/`openssl` could not be converted (799-tb7q).
    # openssl-devel above is the headers, not the CLI; the CLI ships in the base
    # image today, but naming it here makes that a guarantee rather than an
    # accident. Fedora's `yq` is mikefarah v4, whose `yq . <file>` is the syntax
    # the finalization YAML-validation step names.
    toolbox run --container "$TOOLBOX_NAME" \
        sudo dnf install -y \
            gcc musl-gcc pkg-config file cmake make \
            openssl-devel systemd-devel \
            ruby perl-FindBin \
            procps-ng findutils diffutils \
            jq yq ripgrep openssl \
            mingw64-gcc \
        2>&1 | while IFS= read -r line; do printf '  [dnf] %s\n' "$line"; done

    RUSTUP_INIT="$HOME/.cache/tillandsias/rustup-init.sh"
    mkdir -p "$(dirname "$RUSTUP_INIT")"
    if [[ ! -f "$RUSTUP_INIT" ]]; then
        curl --proto '=https' --tlsv1.2 -sSf \
            https://sh.rustup.rs -o "$RUSTUP_INIT"
        chmod +x "$RUSTUP_INIT"
    fi

    toolbox run --container "$TOOLBOX_NAME" \
        bash "$RUSTUP_INIT" -y 2>&1 | while IFS= read -r line; do printf '  [rustup] %s\n' "$line"; done

    toolbox run --container "$TOOLBOX_NAME" \
        bash -l -c "rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-pc-windows-gnu" \
        2>&1 | while IFS= read -r line; do printf '  [rustup] %s\n' "$line"; done

    toolbox run --container "$TOOLBOX_NAME" \
        bash -c "mkdir -p '$(dirname "$MARKER_FILE")' && touch '$MARKER_FILE'"

    echo "[tillandsias-builder] Initialization complete."
fi

# ── Re-exec inside the toolbox ────────────────────────────────────────────
# At this point we are on the host (not in toolbox). Re-exec the current
# command inside the toolbox.

# Escape arguments for safe insertion into bash -c string
ARGS_QUOTED=""
for arg in "$@"; do
    ARGS_QUOTED="$ARGS_QUOTED$(printf '%q ' "$arg")"
done
PWD_QUOTED="$(printf '%q' "$(pwd)")"

# `toolbox run` does NOT forward the caller's environment, so every
# TILLANDSIAS_* control flag silently died at this boundary: on Silverblue,
# TILLANDSIAS_FORCE_CHECK=1 could not bypass the gate memo (caught by
# test-gate-stamp-memoization case 12 on yoga, 2026-08-23) and
# TILLANDSIAS_SKIP_VERSION_BUMP=1 could not stop the version bump. Re-export
# the whole namespace inside the toolbox. TILLANDSIAS_SKIP_TOOLBOX is
# exported AFTER this string in both exec lines, so the recursion guard
# always wins over anything forwarded here.
ENV_FORWARD=""
while IFS= read -r _tb_var; do
    ENV_FORWARD="${ENV_FORWARD}export $(printf '%q' "$_tb_var")=$(printf '%q' "${!_tb_var}") ; "
done < <(compgen -v | grep '^TILLANDSIAS_' || true)

echo "[tillandsias-builder] Re-execing inside '$TOOLBOX_NAME' toolbox..."

if [[ "$_TB_DIRECT" == 1 ]]; then
    # Direct execution: `scripts/with-tillandsias-builder.sh <cmd> [args...]`
    # runs <cmd> itself inside the toolbox. (The previous BASH_SOURCE walk
    # could only ever find this file, fell back to build.sh, and re-ran it
    # with the command line as bogus arguments.)
    if [[ $# -eq 0 ]]; then
        echo "usage: $SELF <command> [args...]" >&2
        exit 2
    fi
    exec toolbox run --container "$TOOLBOX_NAME" \
        bash -l -c "${ENV_FORWARD}export TILLANDSIAS_SKIP_TOOLBOX=1 ; cd $PWD_QUOTED && exec $ARGS_QUOTED"
fi

# Sourced from a build script: when `source`d, $0 and $@ are the calling
# script and its original arguments — re-exec that script inside the toolbox.
SCRIPT="$0"
if [[ "$SCRIPT" != /* ]]; then
    SCRIPT="$(pwd)/$SCRIPT"
fi
exec toolbox run --container "$TOOLBOX_NAME" \
    bash -l -c "${ENV_FORWARD}export TILLANDSIAS_SKIP_TOOLBOX=1 ; cd $PWD_QUOTED && exec bash $(printf '%q' "$SCRIPT") $ARGS_QUOTED"
