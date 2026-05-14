#!/usr/bin/env bash
# lib-common.sh — Shared setup for all Tillandsias entrypoints.
#
# This file is SOURCED (not executed) by per-type entrypoint scripts.
# It must NOT contain `exit` or `exec` statements.
#
# Location in image: /usr/local/lib/tillandsias/lib-common.sh

set -euo pipefail

# ── Certificate Authority injection ──────────────────────────
# @trace spec:transparent-https-caching
# If the enclave CA cert is mounted at /etc/tillandsias/ca.crt (from orchestrate-enclave.sh),
# inject it into the system trust store. This allows cargo, npm, rustup, curl, and all other
# tools to transparently trust the tillandsias-proxy's generated certificates for HTTPS caching.
# This runs silently if no cert is present (e.g., in dev builds without enclave).
if [ -f /etc/tillandsias/ca.crt ]; then
    mkdir -p /usr/local/share/ca-certificates/
    cp /etc/tillandsias/ca.crt /usr/local/share/ca-certificates/tillandsias.crt 2>/dev/null || true
    update-ca-certificates 2>/dev/null || true
fi

# Ensure all files created by this script and any process it execs are
# user-writable. Without this, tools running inside the container may
# create files on bind-mounted directories with restrictive modes.
umask 0022

# Kill background jobs (spinners) on signal, but do NOT call exit —
# this file is sourced by entrypoints that end with `exec`, and an
# `exit` in the EXIT trap would prevent the exec from replacing the shell.
_cleanup() { jobs -p | xargs -r kill 2>/dev/null || true; }
trap '_cleanup' SIGTERM SIGINT
trap '_cleanup' EXIT

# ── Locale detection ─────────────────────────────────────────
# Extract the 2-letter language code from the OS locale environment.
# Priority: LC_ALL > LC_MESSAGES > LANG > LANGUAGE (POSIX standard).
_LOCALE_RAW="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
_LOCALE="${_LOCALE_RAW%%_*}"  # Strip region: "es_MX.UTF-8" -> "es_MX"
_LOCALE="${_LOCALE%%.*}"      # Strip encoding: "es.UTF-8" -> "es"
_LOCALE_FILE="/etc/tillandsias/locales/${_LOCALE}.sh"
[ -f "$_LOCALE_FILE" ] || _LOCALE_FILE="/etc/tillandsias/locales/en.sh"
# shellcheck source=/dev/null
[ -f "$_LOCALE_FILE" ] && source "$_LOCALE_FILE"
unset _LOCALE_RAW _LOCALE _LOCALE_FILE

# ── Secrets directories ─────────────────────────────────────
# Forge containers carry ZERO credentials. Git identity is the only
# artifact the forge needs on disk; the gh CLI is not wired to a token
# here — authenticated git traffic flows through the git mirror service,
# which bridges to the host OS keyring via D-Bus.
# @trace spec:secrets-management
touch ~/.gitconfig 2>/dev/null || true

# ── Shell configs ───────────────────────────────────────────
# Deploy configs from /etc/skel/ to $HOME if not already present.
for f in .bashrc .zshrc; do
    [ -f "$HOME/$f" ] || cp "/etc/skel/$f" "$HOME/$f" 2>/dev/null || true
done
mkdir -p "$HOME/.config/fish"
[ -f "$HOME/.config/fish/config.fish" ] || \
    cp "/etc/skel/.config/fish/config.fish" "$HOME/.config/fish/config.fish" 2>/dev/null || true

# ── Common PATH setup ───────────────────────────────────────
# @trace spec:cross-platform, spec:windows-wsl-runtime, spec:forge-shell-tools
# Pin /usr/bin and /usr/sbin at the front so rustc/cargo/git/python are
# discoverable even when child processes (opencode, agent CLIs, build tools)
# inherit a sanitized $PATH that drops standard system dirs. On Fedora-based
# forges, rustc lives at /usr/bin/rustc and cargo at /usr/bin/cargo — both
# packaged by `microdnf install rust cargo`. WSL2 inherits a long Windows
# $PATH by default (every C:\ tool); without explicit prefixing, $PATH walk
# order can land on a Windows tool of the same name first.
CACHE="$HOME/.cache/tillandsias"
export PATH="$CACHE/openspec/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ── External-logs consumer path ─────────────────────────────
# @trace spec:external-logs-layer
# Canonical path where external logs from enclave service containers are
# mounted RO inside forge/maintenance containers. Tools (tillandsias-logs,
# agent scripts) that want the path without shelling out to the CLI can
# reference this env var directly.
# Producer containers see their own role subdir here (RW); consumers see
# the full parent dir (RO). The var is always exported for consistency —
# on non-consumer containers the directory may not be mounted.
export TILLANDSIAS_EXTERNAL_LOGS="/var/log/tillandsias/external"

# ── Pull-on-demand cheatsheet cache root ────────────────────
# @trace spec:cheatsheets-license-tiered
# @cheatsheet runtime/cheatsheet-pull-on-demand.md
# Per-project cache root for materialized pull-on-demand cheatsheet sources.
# The agent reads this env var instead of hardcoding the path; the layout
# under it mirrors URL host structure so downstream tooling can map any
# `https://<host>/<path>` cited in a `### Source` block onto a deterministic
# disk location.
#
# Layout: ~/.cache/tillandsias/cheatsheets-pulled/<project>/<host>/<path>
#
# Project name resolution chain (mirrors populate_hot_paths()):
#   1. $PROJECT_ROOT — set by entrypoints AFTER find_project_dir(); empty
#      when this function runs early.
#   2. $TILLANDSIAS_PROJECT — set by the tray launcher; names the directory
#      under /home/forge/src/.
#   3. First /home/forge/src/*/ entry (filesystem fallback).
#
# Idempotent: re-exporting on each entrypoint invocation is harmless.
# Per-project isolation is preserved BY CONSTRUCTION — the cache root is
# already per-project, so cross-project reads/writes are impossible without
# explicitly overriding TILLANDSIAS_PULL_CACHE.

# ── Lifecycle tracing (forward declaration) ─────────────────────
# trace_lifecycle MUST be defined before export_pull_cache_path() runs
# because the latter calls it. With `set -euo pipefail` at the top of
# this file, an undefined-function call exits with code 127 — observed
# on Windows/WSL where the entrypoint died with:
#   "lib-common.sh: line 116: trace_lifecycle: command not found"
# (Linux/podman tolerated it before because of slightly different sourcing
# order; WSL exec surfaces the dispatch-time bug.)
# Format: [lifecycle] <phase> | <detail>
# Mirrors output to /tmp/forge-lifecycle.log so runtime-diagnostics-stream
# can surface lifecycle events back to the calling terminal.
# @trace spec:cross-platform, spec:windows-wsl-runtime, spec:runtime-diagnostics-stream
trace_lifecycle() {
    # Only emit lifecycle traces when TILLANDSIAS_DEBUG is set.
    # In production, these clutter the terminal (stderr shares the display).
    [ -n "${TILLANDSIAS_DEBUG:-}" ] || return 0
    local phase="$1"
    shift
    local line="[lifecycle] $phase | $*"
    echo "$line" >&2
    echo "$line" >> /tmp/forge-lifecycle.log 2>/dev/null || true
}

export_pull_cache_path() {
    local project_root="${PROJECT_ROOT:-}"
    local project_name=""

    if [ -z "$project_root" ] && [ -n "${TILLANDSIAS_PROJECT:-}" ]; then
        if [ -d "/home/forge/src/${TILLANDSIAS_PROJECT}" ]; then
            project_root="/home/forge/src/${TILLANDSIAS_PROJECT}"
        fi
    fi
    if [ -z "$project_root" ]; then
        for _d in /home/forge/src/*/; do
            [ -d "$_d" ] && project_root="${_d%/}" && break
        done
    fi

    if [ -n "$project_root" ]; then
        project_name="$(basename "$project_root")"
    elif [ -n "${TILLANDSIAS_PROJECT:-}" ]; then
        project_name="${TILLANDSIAS_PROJECT}"
    else
        project_name="unknown"
    fi

    local cache_root="${HOME}/.cache/tillandsias/cheatsheets-pulled/${project_name}"
    mkdir -p "$cache_root" 2>/dev/null || true
    chmod 0755 "$cache_root" 2>/dev/null || true
    export TILLANDSIAS_PULL_CACHE="$cache_root"
    trace_lifecycle "pull-cache" "TILLANDSIAS_PULL_CACHE=$cache_root"
}

# Run the export early — agents may consult $TILLANDSIAS_PULL_CACHE before
# populate_hot_paths() lands. Failures are non-fatal (mkdir under $HOME
# is virtually always permitted).
export_pull_cache_path

# Lifecycle tracing — function defined earlier in this file. See the forward
# declaration block above.

# @trace spec:cross-platform, spec:windows-wsl-runtime, spec:git-mirror-service, spec:forge-offline
# Shared clone-from-mirror routine for ALL forge entrypoints (opencode,
# claude, opencode-web, terminal). Two transports:
#   - filesystem  : TILLANDSIAS_GIT_MIRROR_PATH=/path/to/bare/mirror (Windows/WSL)
#   - git daemon  : TILLANDSIAS_GIT_SERVICE=host:port (Linux/podman)
#
# Idempotent: if /home/forge/src/<project> already exists with a valid clone,
# wipe it first so re-attaches don't fail with "destination already exists".
# This matches the ephemeral-working-tree contract — on Linux/podman the dir
# is tmpfs and wiped per launch; on WSL the distro fs persists, so we wipe
# explicitly here.
#
# Returns 0 on successful clone, exits 1 on hard failure.
clone_project_from_mirror() {
    local clone_dir
    if [[ -z "${TILLANDSIAS_PROJECT:-}" ]]; then
        return 0  # nothing to clone — non-project session
    fi
    clone_dir="/home/forge/src/${TILLANDSIAS_PROJECT}"

    # Wipe stale working tree (ephemeral-tree contract).
    if [[ -d "$clone_dir" ]]; then
        trace_lifecycle "git-mirror" "wiping stale working tree ${clone_dir}"
        rm -rf "$clone_dir"
    fi

    # Filesystem transport (Windows/WSL).
    if [[ -n "${TILLANDSIAS_GIT_MIRROR_PATH:-}" ]]; then
        local src="${TILLANDSIAS_GIT_MIRROR_PATH}"
        trace_lifecycle "git-mirror" "cloning from filesystem ${src}"
        # /mnt/c/... reports root ownership via 9p; whitelist this specific
        # path so git won't refuse with "dubious ownership".
        git config --global --add safe.directory "${src}" 2>/dev/null || true
        if git clone "${src}" "$clone_dir" 2>&1; then
            trace_lifecycle "git-mirror" "clone successful (filesystem)"
            cd "$clone_dir" || return 1
            # @trace spec:cross-platform, spec:windows-wsl-runtime, spec:git-mirror-service
            # UX-friendly remote alignment: present the GitHub URL as `origin`
            # so `git remote -v` shows what users expect, while operations
            # still flow through the credential-isolated local mirror.
            #
            #   - read GitHub URL from the bare mirror (it has the token-in-URL)
            #   - strip the token before exposing it inside the forge
            #   - set forge's origin to the clean GitHub URL (cosmetic)
            #   - use git config `url.<local>.insteadOf <github>` so any push
            #     or fetch the user runs against the GitHub URL silently
            #     redirects to the local bare mirror (which has the token
            #     and runs the post-receive hook to GitHub).
            #
            # Forge therefore stays credential-free (no token in its env or
            # config) and the user sees the canonical GitHub remote.
            local mirror_origin
            mirror_origin="$(GIT_DIR="${src}" git config remote.origin.url 2>/dev/null || true)"
            local github_url=""
            if [[ -n "$mirror_origin" ]]; then
                # Strip user[:password]@ prefix if present.
                github_url="$(echo "$mirror_origin" | sed -E 's#https://[^@/]+@#https://#')"
            fi
            if [[ -n "$github_url" ]] && [[ "$github_url" != "$src" ]]; then
                git remote set-url origin "$github_url" 2>/dev/null || true
                git config --local "url.${src}.insteadOf" "$github_url" 2>/dev/null || true
                trace_lifecycle "git-mirror" "origin presented as ${github_url}; routes to ${src}"
            else
                # No real GitHub remote on the mirror — keep the local path.
                git remote set-url --push origin "${src}" 2>/dev/null || true
            fi
            [[ -n "${GIT_AUTHOR_NAME:-}" ]] && git config user.name "$GIT_AUTHOR_NAME"
            [[ -n "${GIT_AUTHOR_EMAIL:-}" ]] && git config user.email "$GIT_AUTHOR_EMAIL"
            echo "[forge] All changes must be committed to persist. Uncommitted work is lost on stop."
            return 0
        else
            echo "[forge] FATAL: filesystem clone failed from ${src}" >&2
            echo "[forge] Mirror path not visible inside distro? Check /mnt/c/... mount." >&2
            exit 1
        fi
    fi

    # Network transport (Linux/podman).
    if [[ -n "${TILLANDSIAS_GIT_SERVICE:-}" ]]; then
        trace_lifecycle "git-mirror" "cloning from ${TILLANDSIAS_GIT_SERVICE}"
        local max_retries=5
        for i in $(seq 1 $max_retries); do
            if git clone "git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}" "$clone_dir" 2>&1; then
                trace_lifecycle "git-mirror" "clone successful"
                cd "$clone_dir" || return 1
                git remote set-url --push origin "git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}" 2>/dev/null || \
                    echo "[entrypoint] WARNING: Failed to set push URL — git push may not work" >&2
                [[ -n "${GIT_AUTHOR_NAME:-}" ]] && git config user.name "$GIT_AUTHOR_NAME"
                [[ -n "${GIT_AUTHOR_EMAIL:-}" ]] && git config user.email "$GIT_AUTHOR_EMAIL"
                echo "[forge] All changes must be committed to persist. Uncommitted work is lost on stop."
                return 0
            fi
            if [[ $i -lt $max_retries ]]; then
                trace_lifecycle "git-mirror" "git service not ready, retrying ($i/$max_retries)..."
                sleep 1
            else
                trace_lifecycle "git-mirror" "clone failed after $max_retries attempts"
            fi
        done
        echo "[forge] FATAL: git clone failed from git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}" >&2
        echo "[forge] The git mirror service is unreachable or has not finished initialising." >&2
        exit 1
    fi
    return 0
}

# ── Package manager cache strategy (dual-cache architecture) ──────
# @trace spec:forge-cache-dual, spec:forge-shell-tools
# @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
#
# Per-project cache lives at /home/forge/.cache/tillandsias-project/
# (RW bind-mount from the host's per-project cache directory). Built
# artifacts that are expensive to rebuild for THIS project go here.
# Project A's container CANNOT see project B's cache.
#
# Shared cache lives at /nix/store/ (RO bind-mount from the host's
# nix store). Single entry point: nix flakes only — other tools never
# write here. See runtime/forge-shared-cache-via-nix.md for why.
#
# Project workspace (/home/forge/src/<project>/) is for SOURCE only —
# build artifacts redirect via the env vars below to the per-project
# cache. Treat /tmp/ and unmounted ~/.<dotdirs> as ephemeral scratch.
PROJECT_CACHE="/home/forge/.cache/tillandsias-project"

# @tombstone superseded:forge-cache-architecture — kept for three releases
# (until 0.1.169.232). Old paths pointed at $CACHE/<lang>/ which was the
# cheatsheets-cache mount, NOT bind-mounted to the host. Every container
# restart re-downloaded everything for every language. Verified pre-fix
# in the planner's PLAN-from-java-audits.md cache discipline audit.
#
# OLD (removed in this change):
# export NPM_CONFIG_PREFIX="$CACHE/npm-global"
# export CARGO_HOME="$CACHE/cargo"
# export GOPATH="$CACHE/go"
# export PIP_USER=1
# export PYTHONUSERBASE="$CACHE/pip"

# Cargo
export CARGO_HOME="$PROJECT_CACHE/cargo"
export CARGO_TARGET_DIR="$PROJECT_CACHE/cargo/target"

# Go
export GOPATH="$PROJECT_CACHE/go"
export GOMODCACHE="$PROJECT_CACHE/go/pkg/mod"

# Maven (note: MAVEN_OPTS is the standard knob; -Dmaven.repo.local is the property name)
export MAVEN_OPTS="-Dmaven.repo.local=$PROJECT_CACHE/maven ${MAVEN_OPTS:-}"

# Gradle
export GRADLE_USER_HOME="$PROJECT_CACHE/gradle"

# Flutter / Dart pub cache (overrides the image-baked /opt/flutter/.pub-cache
# which is read-only image-state for shared Flutter SDK files; per-project
# packages flow through here instead)
export PUB_CACHE="$PROJECT_CACHE/pub"

# npm — note the unusual env var name (npm uses lowercase with underscores)
export npm_config_cache="$PROJECT_CACHE/npm"
export NPM_CONFIG_PREFIX="$PROJECT_CACHE/npm/global"

# Yarn (classic and berry both honor this)
export YARN_CACHE_FOLDER="$PROJECT_CACHE/yarn"

# pnpm
export PNPM_HOME="$PROJECT_CACHE/pnpm"

# uv (Astral's pip replacement)
export UV_CACHE_DIR="$PROJECT_CACHE/uv"

# pip (per-project; pipx tools live in /opt/pipx, image-state)
export PIP_CACHE_DIR="$PROJECT_CACHE/pip"

# PATH augmentation for per-project binaries (cargo install, go install,
# npm -g into PROJECT_CACHE/npm/global)
export PATH="$NPM_CONFIG_PREFIX/bin:$CARGO_HOME/bin:$GOPATH/bin:$PNPM_HOME:$PATH"

# ── Update-check rate-limiting ──────────────────────────────
# Returns 0 (true) if the last check was more than 24 hours ago or never ran.
needs_update_check() {
    local stamp_file="$1"
    if [ ! -f "$stamp_file" ]; then
        return 0
    fi
    local now last_check age
    now="$(date +%s)"
    last_check="$(cat "$stamp_file" 2>/dev/null || echo 0)"
    age=$(( now - last_check ))
    # 86400 seconds = 24 hours
    [ "$age" -ge 86400 ]
}

record_update_check() {
    local stamp_file="$1"
    mkdir -p "$(dirname "$stamp_file")" 2>/dev/null || true
    date +%s > "$stamp_file"
}

# ── Find project directory ──────────────────────────────────
# Sets PROJECT_DIR to the first directory found in ~/src/.
# Entrypoints can cd into it after sourcing this library.
find_project_dir() {
    PROJECT_DIR=""
    # @trace spec:cross-platform, spec:windows-wsl-runtime
    # Priority: $TILLANDSIAS_PROJECT match wins. On Linux/podman this loop
    # only ever sees one entry (the freshly-cloned project — tmpfs is
    # wiped per launch). On Windows/WSL the distro fs persists between
    # attaches, so leftover working-tree dirs from prior projects can
    # exist alongside the current one. Without this preference, the for
    # loop picks alphabetically (e.g. test1 wins over visual-chess) and
    # the entrypoint logs/operates on the WRONG project.
    if [ -n "${TILLANDSIAS_PROJECT:-}" ] \
        && [ -d "$HOME/src/${TILLANDSIAS_PROJECT}" ]; then
        PROJECT_DIR="$HOME/src/${TILLANDSIAS_PROJECT}/"
        return 0
    fi
    for dir in "$HOME/src"/*/; do
        [ -d "$dir" ] && PROJECT_DIR="$dir" && break
    done
    # The for-loop's exit code is the last body command's exit code.
    # When the glob matches nothing, [ -d "$dir" ] fails (exit 1) and
    # the function would propagate that to the caller — fatal under set -e.
    return 0
}

# ── Coding agents (hard-installed in image) ─────────────────
# @trace spec:default-image, spec:forge-shell-tools
# OpenCode, Claude Code, and OpenSpec are baked into /opt/agents/ at image
# build time and symlinked into /usr/local/bin/ — see images/default/Containerfile.
# These helpers verify presence and export the canonical bin path each
# entrypoint needs. Failure here means the image is corrupt; bail loudly.
require_opencode() {
    OC_BIN="/usr/local/bin/opencode"
    if [ ! -x "$OC_BIN" ]; then
        echo "[entrypoint] FATAL: OpenCode missing at $OC_BIN — forge image is corrupt" >&2
        exit 1
    fi
    trace_lifecycle "install" "opencode: hard-installed ($OC_BIN)"
}

require_claude() {
    CC_BIN="/usr/local/bin/claude"
    if [ ! -x "$CC_BIN" ]; then
        echo "[entrypoint] FATAL: Claude Code missing at $CC_BIN — forge image is corrupt" >&2
        exit 1
    fi
    trace_lifecycle "install" "claude-code: hard-installed ($CC_BIN)"
}

require_openspec() {
    OS_BIN="/usr/local/bin/openspec"
    if [ ! -x "$OS_BIN" ]; then
        echo "[entrypoint] FATAL: OpenSpec missing at $OS_BIN — forge image is corrupt" >&2
        exit 1
    fi
    trace_lifecycle "install" "openspec: hard-installed ($OS_BIN)"
}

# ── OpenCode config overlay ─────────────────────────────────
# @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp, spec:layered-tools-overlay
# The Containerfile bakes a minimal stub at ~/.config/opencode/config.json
# (just `{ "autoupdate": false }`). Replace it with the host-mounted overlay
# so MCPs, instructions, dark theme, and the enclave-local ollama baseURL
# all take effect. Without this step the stub wins and OpenCode reports
# "Model not found" because the provider list is empty. Idempotent.
apply_opencode_config_overlay() {
    local overlay_cfg="/home/forge/.config-overlay/opencode/config.json"
    local overlay_tui="/home/forge/.config-overlay/opencode/tui.json"
    local user_cfg="/home/forge/.config/opencode/config.json"
    local user_tui="/home/forge/.config/opencode/tui.json"
    mkdir -p "$(dirname "$user_cfg")"
    if [ -f "$overlay_cfg" ]; then
        cp -f "$overlay_cfg" "$user_cfg"
        trace_lifecycle "config" "opencode config overlay applied"
    fi
    if [ -f "$overlay_tui" ]; then
        cp -f "$overlay_tui" "$user_tui"
    fi
}

# ── Hot-path population ─────────────────────────────────────
# @trace spec:forge-hot-cold-split, spec:agent-cheatsheets, spec:cheatsheets-license-tiered
# @cheatsheet runtime/cheatsheet-crdt-overrides.md
# Called once at container start, AFTER the podman --tmpfs mounts are in
# place (those are established by the kernel before the entrypoint runs).
# Copies /opt/cheatsheets-image/ (RO image lower layer baked at build time)
# into /opt/cheatsheets/ (tmpfs hot mount, 8MB cap) so every agent read is
# RAM-served rather than overlayfs-backed.
#
# Then merges <project>/.tillandsias/cheatsheets/ on top — project-committed
# cheatsheets shadow forge defaults at the same relative path. Each shadow
# emits a banner line and the renderer injects a `> [!OVERRIDE]` callout
# block at the top of the body so the override is reasoned, never silent.
#
# Idempotent: re-running on an already-populated tmpfs is harmless.
# Silent failure: 2>/dev/null || true means a missing source or mount point
# doesn't abort the entrypoint.
populate_hot_paths() {
    if [ -d /opt/cheatsheets-image ] && [ -d /opt/cheatsheets ]; then
        cp -a /opt/cheatsheets-image/. /opt/cheatsheets/ 2>/dev/null || true
        trace_lifecycle "hot-paths" "cheatsheets copied to tmpfs (/opt/cheatsheets)"
    else
        trace_lifecycle "hot-paths" "skipped: /opt/cheatsheets-image or /opt/cheatsheets not found"
        return 0
    fi

    # @trace spec:cheatsheets-license-tiered (task 6.1, 6.2, 6.4)
    # Resolve project root. The entrypoint runs BEFORE find_project_dir(),
    # so PROJECT_ROOT may not be set; prefer the env hint from the tray
    # (TILLANDSIAS_PROJECT names the dir under /home/forge/src/), fall back
    # to scanning /home/forge/src/ for the first directory.
    local project_root="${PROJECT_ROOT:-}"
    if [ -z "$project_root" ] && [ -n "${TILLANDSIAS_PROJECT:-}" ]; then
        if [ -d "/home/forge/src/${TILLANDSIAS_PROJECT}" ]; then
            project_root="/home/forge/src/${TILLANDSIAS_PROJECT}"
        fi
    fi
    if [ -z "$project_root" ]; then
        for _d in /home/forge/src/*/; do
            [ -d "$_d" ] && project_root="${_d%/}" && break
        done
    fi

    local project_cs="${project_root}/.tillandsias/cheatsheets"
    if [ -z "$project_root" ] || [ ! -d "$project_cs" ]; then
        trace_lifecycle "hot-paths" "no project-committed cheatsheets to merge (project_root=${project_root:-<none>})"
        return 0
    fi

    # Walk every project-committed cheatsheet. For each .md:
    #  1. Detect shadow (same relative path exists under /opt/cheatsheets-image/).
    #  2. Validate shadows_forge_default frontmatter consistency (WARN on mismatch).
    #  3. Either merge plain (no shadow) or render with [!OVERRIDE] callout (shadow).
    #  4. Emit one banner line per shadow.
    local rel src_path img_path dest_path shadows reason
    while IFS= read -r -d '' src_path; do
        rel="${src_path#${project_cs}/}"
        dest_path="/opt/cheatsheets/${rel}"
        img_path="/opt/cheatsheets-image/${rel}"
        mkdir -p "$(dirname "$dest_path")" 2>/dev/null || true

        # Parse the shadows_forge_default field from frontmatter (may be empty).
        shadows="$(_read_frontmatter_field "$src_path" shadows_forge_default)"

        if [ -f "$img_path" ]; then
            # Same relative path exists in forge baked layer -> SHADOW.
            reason="$(_read_frontmatter_field "$src_path" override_reason | head -n1)"
            echo "[cheatsheet override] ${rel} → project version (reason: ${reason:-<no override_reason set>})"
            if [ -n "$shadows" ]; then
                _inject_override_callout "$src_path" "$dest_path"
            else
                # Project file shadows by path but did not declare it. Validator
                # WARNs separately (task 6.3); merge plainly here.
                cp -af "$src_path" "$dest_path" 2>/dev/null || true
            fi
        else
            if [ -n "$shadows" ]; then
                # Declared shadow but no forge default at that path -> config error.
                echo "[cheatsheet override] WARN: ${rel} declares shadows_forge_default but no forge default exists at that path"
                _inject_override_callout "$src_path" "$dest_path"
            else
                # Net-new project cheatsheet — just merge.
                cp -af "$src_path" "$dest_path" 2>/dev/null || true
            fi
        fi
    done < <(find "$project_cs" -type f -name '*.md' -print0 2>/dev/null)

    trace_lifecycle "hot-paths" "project-committed cheatsheets merged from ${project_cs}"

    # Re-render /opt/cheatsheets/INDEX.md to include project-committed entries
    # and any pulled materializations under $TILLANDSIAS_PULL_CACHE. The image-
    # baked INDEX.md reflects only host repo state at build time; the agent's
    # discovery surface needs the runtime-merged view.
    _regen_runtime_index
}

# @trace spec:cheatsheets-license-tiered (task 8.2)
# @cheatsheet runtime/cheatsheet-pull-on-demand.md
# @cheatsheet runtime/cheatsheet-crdt-overrides.md
#
# Append entries to /opt/cheatsheets/INDEX.md for any cheatsheet present at
# runtime that is NOT already listed in the image-baked INDEX. Two sources:
#   1. /opt/cheatsheets/**/*.md   — includes project-committed merges done by
#      populate_hot_paths() above (badge: [bundled, project-committed] when
#      shadows_forge_default is set, else [pull-on-demand: project-committed]).
#   2. ${TILLANDSIAS_PULL_CACHE}/**/*.md — agent-materialized pulls under the
#      per-project cache (badge: [pulled]).
#
# Append-only: never rewrites existing lines. Keeps the runtime index aligned
# with the host-side regenerator's line format ("- <path> — <desc> [marker]")
# but uses minimal markers since per-file frontmatter parsing is best-effort
# inside the entrypoint hot path.
#
# Performance budget: O(total cheatsheets); single find + awk pass per source.
# Best-effort throughout — silent failure on a missing index does not abort
# the entrypoint.
_regen_runtime_index() {
    local index="/opt/cheatsheets/INDEX.md"
    [ -f "$index" ] || return 0

    local pull_cache="${TILLANDSIAS_PULL_CACHE:-}"
    local section_header_pulled="## pulled"
    local appended=0

    # Pass 1: project-committed and other runtime-merged entries under
    # /opt/cheatsheets/. Skip files whose relative path is already listed in
    # the index; the image-baked entries are present from the cp -a above.
    # The host-side renderer drops the category prefix on lines under a
    # `## <category>` section (the section header carries the category), so a
    # path like `languages/python.md` shows up in the index as `- python.md`
    # under `## languages`. We dedup against EITHER the relative path (for
    # one-level-deeper subdirs like `languages/java/rxjava-event-driven.md`,
    # which renders as `- java/rxjava-event-driven.md`) OR the bare basename.
    local f rel base no_cat badge desc tier shadows committed
    while IFS= read -r -d '' f; do
        rel="${f#/opt/cheatsheets/}"
        case "$rel" in
            INDEX.md|TEMPLATE.md|*/INDEX.md) continue ;;
        esac
        base="$(basename "$rel")"
        # The host renderer drops the category prefix: `languages/python.md`
        # under `## languages` shows as `- python.md`, and one-level-deeper
        # `languages/java/rxjava-event-driven.md` shows as `- java/rxjava-...md`.
        # Dedup by trying the full rel, the first-component-stripped form,
        # and the bare basename.
        no_cat="${rel#*/}"
        if grep -qE -- "^- ${rel}([[:space:]]|$)" "$index" 2>/dev/null \
           || grep -qE -- "^- ${no_cat}([[:space:]]|$)" "$index" 2>/dev/null \
           || grep -qE -- "^- ${base}([[:space:]]|$)" "$index" 2>/dev/null; then
            continue
        fi

        tier="$(_read_frontmatter_field "$f" tier | head -n1)"
        shadows="$(_read_frontmatter_field "$f" shadows_forge_default | head -n1)"
        committed="$(_read_frontmatter_field "$f" committed_for_project | head -n1)"

        if [ -n "$shadows" ]; then
            badge="[bundled, project-committed]"
        elif [ "$committed" = "true" ] || [ "$tier" = "pull-on-demand" ]; then
            badge="[pull-on-demand: project-committed]"
        else
            badge="[project-committed]"
        fi

        # Best-effort description: first body line matching `**Use when**:` or
        # the title H1 fallback. Empty description is acceptable — agent can
        # cat the file for content; INDEX is for discovery.
        desc="$(awk '
            /^---$/ { in_fm = !in_fm; next }
            in_fm { next }
            /^\*\*Use when\*\*:/ {
                sub(/^\*\*Use when\*\*:[[:space:]]*/, "")
                print
                exit
            }
        ' "$f" 2>/dev/null | head -n1)"
        [ -z "$desc" ] && desc="$(awk '/^# / { sub(/^# /, ""); print; exit }' "$f" 2>/dev/null)"

        if [ -n "$desc" ]; then
            printf -- '- %s %s — %s\n' "$rel" "$badge" "$desc" >> "$index"
        else
            printf -- '- %s %s\n' "$rel" "$badge" >> "$index"
        fi
        appended=1
    done < <(find /opt/cheatsheets -type f -name '*.md' -print0 2>/dev/null)

    # Pass 2: pulled materializations under the per-project pull cache. These
    # mirror URL-host structure (<host>/<path>) and have no frontmatter — emit
    # the bare path with [pulled] under a dedicated `## pulled` section.
    if [ -n "$pull_cache" ] && [ -d "$pull_cache" ]; then
        local pull_rows
        pull_rows="$(find "$pull_cache" -type f -name '*.md' 2>/dev/null \
                     | sort 2>/dev/null)"
        if [ -n "$pull_rows" ]; then
            # Add the section header once if not already present.
            if ! grep -qF -- "$section_header_pulled" "$index" 2>/dev/null; then
                printf '\n%s\n\n' "$section_header_pulled" >> "$index"
            fi
            local p rel_pull
            while IFS= read -r p; do
                [ -f "$p" ] || continue
                rel_pull="${p#${pull_cache}/}"
                if grep -qF -- "- ${rel_pull} " "$index" 2>/dev/null; then
                    continue
                fi
                printf -- '- %s [pulled]\n' "$rel_pull" >> "$index"
                appended=1
            done <<< "$pull_rows"
        fi
    fi

    if [ "$appended" = "1" ]; then
        trace_lifecycle "hot-paths" "runtime INDEX.md augmented with project-committed/pulled entries"
    fi
    return 0
}

# @trace spec:cheatsheets-license-tiered (task 6.2 helper)
# Read a single scalar (or first line of a `|` block scalar) from YAML
# frontmatter at the head of FILE. Echoes empty string on miss. Bash-only
# parser; mirrors the discipline in scripts/check-cheatsheet-tiers.sh but
# narrower (single-key lookup, no full document parse).
_read_frontmatter_field() {
    local file="$1" key="$2"
    [ -f "$file" ] || { echo ""; return 0; }
    awk -v key="$key" '
        BEGIN { in_fm = 0; depth = 0; cur_key = ""; multiline = 0 }
        NR == 1 {
            if ($0 == "---") { in_fm = 1; next }
            else { exit }
        }
        in_fm && $0 == "---" { exit }
        in_fm {
            if (multiline) {
                # Collect indented continuation lines for the matched key.
                if (match($0, /^[ \t]+/)) {
                    line = $0
                    sub(/^[ \t]+/, "", line)
                    print line
                    next
                } else {
                    exit
                }
            }
            # Match top-level "key: value" (no indent).
            if (match($0, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/)) {
                k = $0
                sub(/[ \t]*:.*$/, "", k)
                if (k == key) {
                    v = $0
                    sub(/^[^:]*:[ \t]*/, "", v)
                    if (v == "|" || v == ">" || v == "|-" || v == "|+" || v == ">-" || v == ">+") {
                        multiline = 1
                        next
                    }
                    print v
                    exit
                }
            }
        }
    ' "$file" 2>/dev/null
}

# @trace spec:cheatsheets-license-tiered (task 6.4)
# @cheatsheet runtime/cheatsheet-crdt-overrides.md
# Render a project-committed cheatsheet with a `> [!OVERRIDE]` callout block
# prepended to its body. The callout surfaces shadows_forge_default,
# override_reason, override_consequences, override_fallback so the agent
# reads the deviation contract BEFORE the cheatsheet body. The callout sits
# AFTER the YAML frontmatter (if present), BEFORE the first content line.
_inject_override_callout() {
    local src="$1" dest="$2"
    local sh re co fb
    sh="$(_read_frontmatter_field "$src" shadows_forge_default)"
    re="$(_read_frontmatter_field "$src" override_reason)"
    co="$(_read_frontmatter_field "$src" override_consequences)"
    fb="$(_read_frontmatter_field "$src" override_fallback)"

    # Build the callout. Multi-line scalars get folded into single lines for
    # quote-block readability (the cheatsheet body still has the full text).
    local callout
    callout="$(cat <<EOF
> [!OVERRIDE]
> **shadows_forge_default**: ${sh}
>
> **override_reason**: $(printf '%s' "$re" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')
> **override_consequences**: $(printf '%s' "$co" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')
> **override_fallback**: $(printf '%s' "$fb" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')

EOF
)"

    # Split the source: frontmatter (---\n...\n---\n) + body. If no frontmatter
    # is present, prepend the callout directly. Use awk for a single pass.
    awk -v callout="$callout" '
        BEGIN { state = "pre"; emitted = 0 }
        state == "pre" {
            if (NR == 1 && $0 == "---") { print; state = "fm"; next }
            # No frontmatter — emit callout first, then everything.
            print callout
            print
            state = "body"
            emitted = 1
            next
        }
        state == "fm" {
            print
            if ($0 == "---") { state = "after-fm" }
            next
        }
        state == "after-fm" {
            print callout
            print
            state = "body"
            emitted = 1
            next
        }
        state == "body" { print }
        END {
            # If the file was just frontmatter with no body, still emit callout.
            if (state == "after-fm" && !emitted) { print callout }
        }
    ' "$src" > "$dest" 2>/dev/null || cp -af "$src" "$dest" 2>/dev/null || true
}

# ── Pull cache LRU eviction ─────────────────────────────────
# @trace spec:cheatsheets-license-tiered (task 5.6)
# @cheatsheet runtime/cheatsheet-pull-on-demand.md
# @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
#
# Pure-userspace implementation of the "tmpfs-overlay lane" requirement
# from forge-hot-cold-split. Rationale (chosen path 1, NOT a real tmpfs
# overlay):
#   - The lane SHALL behave as "tmpfs-fast UP TO the cap, disk-backed
#     beyond it." A real `--tmpfs ...:size=Nm` mount would enforce ENOSPC
#     past the cap, breaking the spec's "writes succeed past cap by
#     demoting LRU" scenario.
#   - The pure-userspace LRU treats the cache root as a single COLD pool
#     with a soft cap. Every materialize call optionally invokes this
#     helper; eviction trims the pool back under the cap by removing the
#     least-recently-accessed regular files.
#   - Eviction NEVER crosses the per-project subtree (the function only
#     ever looks at $TILLANDSIAS_PULL_CACHE, which is already per-project
#     by export_pull_cache_path() construction).
#
# Path 2 (real tmpfs + on-disk shadow with merged view) is tracked as a
# follow-up if profiling shows path 1 is too slow. Path 1 satisfies every
# `Tmpfs-overlay lane` scenario in forge-hot-cold-split.spec.md including
# "demotes LRU to disk" (in path 1, the file simply stays on disk — there
# is no separate tmpfs portion to evict from), and "NEVER crosses project
# boundaries" (per-project root is the only thing scanned).
#
# Usage:
#   _pull_cache_evict_lru_if_over_cap        # default cap = $TILLANDSIAS_PULL_CACHE_RAM_MB
#   _pull_cache_evict_lru_if_over_cap 256    # explicit MB override
#
# Failure modes (all non-fatal; helper is best-effort):
#   - Cap not numeric → no-op (return 0).
#   - Cache root unset or missing → no-op.
#   - du / find / sort missing → no-op (image always carries them; defence in depth).
_pull_cache_evict_lru_if_over_cap() {
    local cap_mb="${1:-${TILLANDSIAS_PULL_CACHE_RAM_MB:-}}"
    local cache_root="${TILLANDSIAS_PULL_CACHE:-}"

    case "$cap_mb" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ -d "$cache_root" ] || return 0
    [ "$cap_mb" -gt 0 ] || return 0

    local current_mb
    current_mb="$(du -sm "$cache_root" 2>/dev/null | awk '{print $1}')"
    case "$current_mb" in
        ''|*[!0-9]*) return 0 ;;
    esac

    [ "$current_mb" -le "$cap_mb" ] && return 0

    # Over cap — collect every file with mtime, sort oldest-first, evict
    # one at a time until back under cap. Use mtime as the LRU proxy
    # (atime updates are typically disabled with `noatime`).
    local victims
    victims="$(find "$cache_root" -type f -printf '%T@\t%p\n' 2>/dev/null | sort -n | cut -f2-)"
    [ -n "$victims" ] || return 0

    local f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        rm -f "$f" 2>/dev/null || true
        # Re-measure after each eviction; cheap on small caches, prevents
        # over-evicting when a single victim is large enough to bring us
        # back under cap.
        current_mb="$(du -sm "$cache_root" 2>/dev/null | awk '{print $1}')"
        case "$current_mb" in
            ''|*[!0-9]*) break ;;
        esac
        [ "$current_mb" -le "$cap_mb" ] && break
    done <<< "$victims"

    trace_lifecycle "pull-cache" "evicted to fit cap=${cap_mb}MB (now=${current_mb}MB)"
    return 0
}

# ── Banner ──────────────────────────────────────────────────
show_banner() {
    local agent_name="${1:-terminal}"
    # Use locale-aware strings if available, fall back to English.
    local banner_forge="${L_BANNER_FORGE:-tillandsias forge}"
    local banner_project="${L_BANNER_PROJECT:-project:}"
    local banner_agent="${L_BANNER_AGENT:-agent:}"
    echo ""
    echo "========================================"
    echo "  $banner_forge"
    echo "  $banner_project $(basename "$(pwd)")"
    echo "  $banner_agent $agent_name"
    echo "========================================"
    echo ""
}
