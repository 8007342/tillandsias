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

# ── Gate on CAPABILITY, not on OS IDENTITY (operator direction 2026-08-26) ──
#
# This used to read: `VARIANT_ID != silverblue && ! command -v rpm-ostree` ->
# skip. That is an IDENTITY test, and it excluded the one host in the fleet that
# most needed the toolbox — macuahuitl, mutable Fedora 44, which has `toolbox`
# installed and rootless podman working but is not Silverblue and has no
# rpm-ostree. So the coordinator built bare on the host while every immutable
# sibling built inside a container.
#
# MEASURED CONSEQUENCE, 2026-08-26: that host accumulated 12 GB of a dead agent
# session in tmpfs and 60 GB across 13 abandoned worktrees, wedged its own
# tooling against a tmpfs quota, and needed an operator with a terminal to
# recover. Silverblue siblings reported no comparable accumulation. That is a
# correlation with a mechanism behind it, not proof — see the caveat below.
#
# WHAT CHANGES: a host that CAN run a toolbox now does, regardless of what
# /etc/os-release calls it.
#
# WHAT DELIBERATELY DOES NOT CHANGE, because widening a gate is where this kind
# of edit goes wrong:
#   - A host with NO toolbox still passes straight through, exactly as before.
#     It must, or every plain container and CI runner that reached this line
#     harmlessly would start failing.
#   - On an ostree host a missing toolbox is still a hard ERROR, because there
#     it means a broken install rather than a different kind of machine.
#   - Every earlier skip-guard is untouched: already-inside-toolbox,
#     container=oci/podman, and TILLANDSIAS_SKIP_TOOLBOX=1 all still win. The
#     last of those is the escape hatch if this misbehaves on a host mid-cycle.
#
# THE CAVEAT WORTH KEEPING: .claude/worktrees is created by the Claude Code
# harness, not by this build system, so the 60 GB half of that accumulation may
# follow the WORKLOAD rather than the host variant. This change addresses the
# build-state half, which is the half it can actually reach.
VARIANT_ID="$(grep -oP '^VARIANT_ID=\K.*' /etc/os-release 2>/dev/null || true)"
_TB_OSTREE=0
if [[ "$VARIANT_ID" == "silverblue" ]] || command -v rpm-ostree &>/dev/null; then
    _TB_OSTREE=1
fi

# ── NO SILENT FALLBACK TO A HOST-NATIVE BUILD (operator ruling 2026-08-26) ──
#
# The operator owns every development host and guarantees the invariant: EVERY
# Linux builder has podman and toolbox. Given that, a fallback to building on
# the host is not resilience — it is the failure mode this milestone exists to
# kill. A host-native build that "worked" is indistinguishable from a
# containerised one until something diverges, and then the divergence is
# attributed to the code rather than to the environment it was never built in.
#
# THE RULE: entering the toolbox ALWAYS succeeds, or this FAILS HARD AND
# IMMEDIATELY. On a healthy Silverblue fleet the failure branch never runs; if
# it does, something is wrong that a silent fallback would hide.
#
# THIS REPLACES a pass-through I wrote an hour earlier, on the reasoning that
# "a host that cannot containerise should still be able to compile". That is
# exactly backwards under an owned fleet: the machine that cannot containerise
# is the one whose build you should trust least, and letting it proceed
# converts an environment fault into a silent behavioural difference.
#
# macOS and Windows are the sanctioned exceptions. macOS is handled ABOVE by the
# /etc/os-release guard — it has its own build path (build-macos-tray.sh).
#
# ORDER 922-curm — WINDOWS WAS NOT, AND THIS COMMENT USED TO CLAIM IT WAS.
# The claim was "macOS and Windows ... are handled ABOVE by the /etc/os-release
# guard". Half true: that guard fires where the file is ABSENT, which on Windows
# is only the Git Bash side. `./build.sh --check` there does not stop at Git
# Bash — it re-execs into the tillandsias-build WSL2 distro, and INSIDE that
# distro /etc/os-release exists (Fedora 44 Container Image), so the guard the
# comment pointed at never runs. Measured on yolanda 2026-08-28 while closing
# 889-8tcb: /etc/os-release present, `container` unset, /run/.containerenv
# absent, toolbox absent — the distro is indistinguishable from a bare Fedora
# builder to every guard this script had, and the FATAL below killed EVERY
# Windows gate before a single check ran.
#
# So detect WSL natively instead of asserting an exception that was not there.
# /proc/version carries the marker on every WSL2 kernel (measured in this
# distro: "6.18.33.2-microsoft-standard-WSL2"), it is a property of the KERNEL
# rather than of the asker — the distinction 889-8tcb paid for when a
# capability probe answered differently on each side of the same boundary — and
# it needs no cooperation from the distro's userland, which is a container
# image that ships neither `hostname` (890-t9pu) nor systemd-detect-virt.
#
# THIS DELIBERATELY DOES NOT WIDEN THE RULING. The refusal below is what an
# owned Linux fleet gets, and a bare-metal Linux builder without toolbox still
# fails exactly as hard — pinned by the negative control in
# scripts/test-toolbox-refusal-wsl-exception.sh, not by review. What changes is
# only that a WSL2 distro stops being mistaken for one: it is not a host
# escaping its container, it is the container the Windows lane sanctions, and
# scripts/with-wsl2-builder.sh is the thing that put us inside it.
if grep -qi microsoft /proc/version 2>/dev/null; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    ! declare -F _tb_restore_caller_opts >/dev/null || _tb_restore_caller_opts
    return 0 2>/dev/null || exit 0
fi

# Reaching here means Linux, not under WSL.
if ! command -v toolbox &>/dev/null; then
    echo "[tillandsias-builder] FATAL: 'toolbox' is not installed on this Linux host." >&2
    echo "[tillandsias-builder] Every Linux builder in this fleet is required to have it;" >&2
    echo "[tillandsias-builder] there is deliberately NO host-native fallback, because a" >&2
    echo "[tillandsias-builder] build that silently escapes its container is worse than no" >&2
    echo "[tillandsias-builder] build at all." >&2
    echo "[tillandsias-builder] Install it:" >&2
    echo "    rpm-ostree install toolbox      # immutable hosts" >&2
    echo "    sudo dnf install toolbox        # mutable hosts" >&2
    echo "[tillandsias-builder] To override for a one-off, set TILLANDSIAS_SKIP_TOOLBOX=1" >&2
    echo "[tillandsias-builder] — deliberately explicit, never automatic." >&2
    exit 1
fi

# toolbox(1) is a thin wrapper over podman. Without podman it cannot create or
# enter anything, so this is the same fault one layer down and gets the same
# treatment: fail, do not degrade.
if ! command -v podman &>/dev/null; then
    echo "[tillandsias-builder] FATAL: 'toolbox' is present but podman is not." >&2
    echo "[tillandsias-builder] toolbox is a wrapper over podman and cannot work without it." >&2
    echo "[tillandsias-builder] No host-native fallback by design (see above)." >&2
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
        bash -c 'command -v gcc && command -v musl-gcc && command -v pkg-config && command -v ruby && command -v rustup && command -v jq && command -v yq && command -v rg && command -v openssl && command -v x86_64-w64-mingw32-gcc && command -v podman && command -v nix && command -v node && command -v systemd-run && rustup target list --installed 2>/dev/null | grep -qxF x86_64-unknown-linux-musl && rustup target list --installed 2>/dev/null | grep -qxF x86_64-pc-windows-gnu' \
        &>/dev/null 2>&1
}

# ── Helper: host-escape shims for tools the toolbox cannot carry (934-7jd4) ─
# podman and nix are HOST facilities: rootless podman needs the host's user
# namespace and storage, and nix serves the host-shared chroot store in $HOME.
# Neither exists inside the toolbox image, and their absence was silent — the
# ci-full lane on this host lost its litmus phase (require_podman red) and its
# nix guest-binary lane (blocked:nix-toolbox:image-pull-failed) for three days
# after the capability-gate change routed builds through the toolbox, while
# every interactive probe on the host answered fine (the 2/2-inside vs
# 0/4-outside matrix on packet 934-7jd4).
#
# flatpak-spawn --host is the escape: it forwards stdio, the cwd and the exit
# code EXACTLY (verified on macuahuitl 2026-08-29: `bash -c "exit 7"` -> 7;
# pwd inside == pwd outside; $HOME is the same mount). What it does NOT
# forward is the environment, so the shim re-exports the project's control
# namespaces explicitly — the same boundary lesson the re-exec below already
# records for toolbox run.
_install_host_escape_shims() {
    local shim_src="$HOME/.cache/tillandsias/host-escape-shim.sh"
    mkdir -p "$(dirname "$shim_src")"
    cat > "$shim_src" <<'SHIM'
#!/usr/bin/env bash
# Host-escape shim (934-7jd4): TOOL_NAME does not exist in this toolbox; run
# the HOST's binary via flatpak-spawn, which forwards stdio/cwd/exit code
# exactly. Env does not cross by default — forward the control namespaces.
_fs_args=()
for _v in $(compgen -e); do
    case "$_v" in
        TILLANDSIAS_*|LITMUS_*|FORGE_*|NIX_*|CONTAINER_HOST|DOCKER_HOST)
            _fs_args+=("--env=$_v=${!_v}") ;;
    esac
done
exec flatpak-spawn --host "${_fs_args[@]}" TOOL_NAME "$@"
SHIM
    local tool
    for tool in podman nix; do
        sed "s/TOOL_NAME/$tool/g" "$shim_src" > "$shim_src.$tool"
        toolbox run --container "$TOOLBOX_NAME" \
            sudo install -m 0755 "$shim_src.$tool" "/usr/local/bin/$tool"
        rm -f "$shim_src.$tool"
    done
    rm -f "$shim_src"
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
            nodejs systemd \
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

    _install_host_escape_shims

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
