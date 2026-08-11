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
# The image preserves Fedora's vendor roots at an immutable path and points
# Fedora's standard extracted bundle symlink at this forge-owned /run target.
# Compose the per-install CA into that target atomically, before any network
# client starts. The forge remains rootless and can only alter its own
# ephemeral trust bundle; no environment-specific CA path is required.
init_runtime_ca_trust() {
    local vendor_bundle="/usr/local/share/tillandsias/vendor-ca-bundle.crt"
    local runtime_ca="/run/tillandsias/ca-chain.crt"
    local trust_bundle="/run/tillandsias/ca-bundle.crt"
    local temporary_bundle

    if [ ! -r "$vendor_bundle" ]; then
        echo "[trust] ERROR: image vendor CA bundle is missing: $vendor_bundle" >&2
        return 1
    fi
    if [ ! -w "$(dirname "$trust_bundle")" ]; then
        echo "[trust] ERROR: runtime trust boundary is not writable: $(dirname "$trust_bundle")" >&2
        return 1
    fi

    temporary_bundle="$(mktemp "${trust_bundle}.XXXXXX")"
    if [ -r "$runtime_ca" ]; then
        if ! grep -q '^-----BEGIN CERTIFICATE-----$' "$runtime_ca" || \
            ! grep -q '^-----END CERTIFICATE-----$' "$runtime_ca"; then
            rm -f "$temporary_bundle"
            echo "[trust] ERROR: runtime proxy CA is not a PEM certificate" >&2
            return 1
        fi
        if ! cat "$vendor_bundle" "$runtime_ca" >"$temporary_bundle"; then
            rm -f "$temporary_bundle"
            echo "[trust] ERROR: could not compose runtime CA bundle" >&2
            return 1
        fi
    else
        echo "[trust] WARNING: runtime proxy CA is not mounted; using vendor roots only" >&2
        if ! cp "$vendor_bundle" "$temporary_bundle"; then
            rm -f "$temporary_bundle"
            echo "[trust] ERROR: could not initialize vendor CA bundle" >&2
            return 1
        fi
    fi
    chmod 0444 "$temporary_bundle"
    mv -f "$temporary_bundle" "$trust_bundle"
}
init_runtime_ca_trust
unset -f init_runtime_ca_trust

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

# ── Standard environment variable setup ─────────────────────
# @trace spec:forge-git-ergonomics
# Set locale if not already set, to avoid locale-sensitive tool warnings.
export LANG="${LANG:-en_US.UTF-8}"

# Derive JAVA_HOME from the java binary path if available.
if [ -z "${JAVA_HOME:-}" ] && command -v java &>/dev/null; then
    _java_home="$(readlink -f "$(command -v java)" 2>/dev/null || true)"
    _java_home="${_java_home%/bin/java}"
    if [ -n "$_java_home" ] && [ -d "$_java_home" ]; then
        export JAVA_HOME="$_java_home"
    fi
    unset _java_home
fi

# Derive GOROOT from go if available.
if [ -z "${GOROOT:-}" ] && command -v go &>/dev/null; then
    _go_root="$(go env GOROOT 2>/dev/null || true)"
    if [ -n "$_go_root" ]; then
        export GOROOT="$_go_root"
    fi
    unset _go_root
fi

# Unset FLUTTER_ROOT if the Flutter SDK directory does not exist.
if [ -n "${FLUTTER_ROOT:-}" ] && [ ! -d "$FLUTTER_ROOT" ]; then
    unset FLUTTER_ROOT
fi

# Avoid git "dubious ownership" on host-mounted repos with different UID.
# Pre-injected by the launcher (order 224) — skip if already present so the
# command does not fail against the read-only injected global config.
if ! git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "/home/forge/src/*"; then
    git config --global --add safe.directory /home/forge/src/\* 2>/dev/null || true
fi

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

# @trace spec:git-mirror-service, spec:forge-hot-cold-split
# Materialise the git index if the gitdir facade left it absent (order 425).
#
# THIS PREVENTS A MASS-DELETION COMMIT. The host-side facade builder
# (write_forge_index) cannot run `git read-tree` when the launching host has no
# git binary — WSL2 and VZ guests ship none — so it returns early, leaving
# .git/index absent and a comment promising "in-container materialization".
# Nothing implemented that promise; `grep -rn read-tree images/` returned zero.
#
# An absent index is NOT merely inconvenient. Verified empirically:
#
#   $ rm .git/index && git status --porcelain
#   D  a.txt          <- every tracked file reads as STAGED-DELETED
#   ?? a.txt          <- and simultaneously untracked
#   $ git commit -am "work"
#   3 files changed, 3 deletions(-)   <- HEAD is now EMPTY
#
# The working tree still holds every file, so nothing looks wrong locally — and
# through the mirror relay that commit is pushed straight to GitHub. An agent
# doing the most ordinary thing in the world, `git commit -am`, wipes the repo.
#
# Every forge image carries git, which is what the original comment assumed, so
# keeping the promise is a one-liner. Fails LOUD rather than proceeding into the
# dangerous state.
ensure_forge_git_index() {
    local dir="${1:-$PWD}"
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    local gitdir
    gitdir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
    [ -n "$gitdir" ] || return 0
    [ -e "$gitdir/index" ] && return 0

    # No HEAD yet (freshly initialised repo) — an absent index is correct.
    git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1 || return 0

    trace_lifecycle "git" "index absent — materialising from HEAD (order 425)"
    if git -C "$dir" read-tree HEAD 2>/dev/null; then
        trace_lifecycle "git" "index materialised from HEAD"
        return 0
    fi

    echo "" >&2
    echo "ERROR: git index is absent and could not be rebuilt from HEAD." >&2
    echo "  Repo: $dir" >&2
    echo "  Committing in this state would record the DELETION of every tracked" >&2
    echo "  file — 'git commit -am' would empty the repository and the mirror" >&2
    echo "  would relay that upstream. Refusing to continue silently." >&2
    echo "  Fix: run 'git read-tree HEAD' in the repo, or relaunch the forge." >&2
    echo "" >&2
    return 1
}

configure_git_identity() {
    # @trace spec:secrets-management, spec:git-mirror-service
    # GitHub Login stores identity on the host; launchers pass it in as env.
    # Write repo-local config too so `git config user.*` and tools that inspect
    # config see the same identity that Git uses for commits.
    #
    # Order 425: materialise the index FIRST. Every lane already calls this
    # function after find_project_dir, so hooking here covers them all without
    # touching five entrypoints.
    ensure_forge_git_index "${PROJECT_DIR:-$PWD}" || true
    local name="${GIT_AUTHOR_NAME:-${GIT_COMMITTER_NAME:-}}"
    local email="${GIT_AUTHOR_EMAIL:-${GIT_COMMITTER_EMAIL:-}}"

    if [[ -z "$name" || -z "$email" ]]; then
        trace_lifecycle "git-identity" "not configured (missing name or email)"
        return 0
    fi

    export GIT_AUTHOR_NAME="$name"
    export GIT_AUTHOR_EMAIL="$email"
    export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$name}"
    export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$email}"

    git config user.name "$name" 2>/dev/null || true
    git config user.email "$email" 2>/dev/null || true
    trace_lifecycle "git-identity" "configured"
    _install_agent_trailer_hook
    _install_expert_refresh_hook
}

# @trace spec:forge-git-identity-anonymization
# Install a prepare-commit-msg hook that appends agent attribution trailers
# (Co-Authored-By, Generated-By) when TILLANDSIAS_AGENT_NAME is set at
# commit time. Uses core.hooksPath in global git config so the host's
# .git/hooks/ is never touched.
_install_agent_trailer_hook() {
    local hooks_dir="$HOME/.cache/tillandsias/git-hooks"
    local hook_file="$hooks_dir/prepare-commit-msg"
    mkdir -p "$hooks_dir" 2>/dev/null || return 0

    # Idempotent: skip if hook already installed
    if [ -f "$hook_file" ] && grep -q "TILLANDSIAS_AGENT" "$hook_file" 2>/dev/null; then
        return 0
    fi

    cat > "$hook_file" <<-'HOOK'
#!/usr/bin/env bash
# prepare-commit-msg hook — Tillandsias forge attribution (auto-installed)
# @trace spec:forge-git-identity-anonymization
# Appends Co-Authored-By and Generated-By trailers for agentic commits.
COMMIT_MSG_FILE="$1"
COMMIT_SOURCE="${2:-}"

[ -n "${TILLANDSIAS_AGENT_NAME:-}" ] || exit 0

case "${COMMIT_SOURCE}" in
    merge|squash|commit) exit 0 ;;
esac

grep -q "^Generated-By:" "$COMMIT_MSG_FILE" 2>/dev/null && exit 0

{
    echo ""
    echo "Co-Authored-By: ${TILLANDSIAS_AGENT_NAME} <noreply@tillandsias>"
    echo "Generated-By: ${TILLANDSIAS_GENERATED_BY:-tool=${TILLANDSIAS_AGENT_NAME}}"
} >> "$COMMIT_MSG_FILE"
HOOK

    chmod 0755 "$hook_file" 2>/dev/null || true
    git config --global core.hooksPath "$hooks_dir" 2>/dev/null || true
    trace_lifecycle "git-hook" "agent trailer hook installed (core.hooksPath=${hooks_dir})"
}

# @trace packet:experts-refresh-on-commit
# Install a post-commit hook that triggers incremental expert refresh.
# Never blocks the commit — forks background work immediately.
# The hook's source lives at scripts/hooks/post-commit-expert-refresh.sh
# in the tillandsias repository; this inlines it into the hooks dir.
_install_expert_refresh_hook() {
    local hooks_dir="$HOME/.cache/tillandsias/git-hooks"
    local hook_file="$hooks_dir/post-commit"
    mkdir -p "$hooks_dir" 2>/dev/null || return 0

    # Idempotent: skip if hook already installed with our marker
    if [ -f "$hook_file" ] && grep -q "experts-refresh-on-commit" "$hook_file" 2>/dev/null; then
        return 0
    fi

    cat > "$hook_file" <<-'HOOK'
#!/usr/bin/env bash
# post-commit hook — Tillandsias forge expert refresh (auto-installed, order 396)
# @trace packet:experts-refresh-on-commit
HOOK

    # Append the refresh logic (shared from repository source)
    # This is inlined so the hook is self-contained with no source dependency.
    cat >> "$hook_file" <<-'REFRESH'
set -uo pipefail

HOOK_NAME="post-commit-expert-refresh"
HOOK_START=$(date +%s%N 2>/dev/null || echo 0)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$REPO_ROOT/plan/index.yaml" ] || exit 0

CHANGED=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null) || exit 0
[ -n "$CHANGED" ] || exit 0

HOOK_LOG="${TILLANDSIAS_HOOK_LOG:-/tmp/tillandsias-hooks.log}"

# L0: plan/ and methodology/ — engine reads files fresh at query time.
# When L1 prose indexes are added, re-index changed corpora here.

# Crate changes → async binary rebuild (bounded, loud on failure)
if echo "$CHANGED" | grep -qE '^crates/tillandsias-plan/'; then
    (
        BIN_DIR="${FORGE_EXPERTS_BIN_DIR:-$HOME/.local/bin}"
        mkdir -p "$BIN_DIR" 2>/dev/null || true
        BIN_PATH="$BIN_DIR/tillandsias-plan"
        BUILD_TIMEOUT="${FORGE_EXPERTS_BUILD_TIMEOUT:-600}"

        if command -v cargo &>/dev/null; then
            timeout "$BUILD_TIMEOUT" cargo build --release -p tillandsias-plan \
                >> "$HOOK_LOG" 2>&1 \
                && {
                    mkdir -p "$BIN_DIR" 2>/dev/null
                    cp "target/release/tillandsias-plan" "$BIN_PATH" 2>/dev/null
                    echo "[$HOOK_NAME] $(date -u +%Y-%m-%dT%H:%M:%SZ) binary rebuilt from commit $(git rev-parse --short HEAD 2>/dev/null)" >> "$HOOK_LOG"
                } \
                || echo "[$HOOK_NAME] $(date -u +%Y-%m-%dT%H:%M:%SZ) FAILED: binary rebuild exited $? (timeout=${BUILD_TIMEOUT}s)" >> "$HOOK_LOG"
        else
            echo "[$HOOK_NAME] $(date -u +%Y-%m-%dT%H:%M:%SZ) SKIP: cargo not available" >> "$HOOK_LOG"
        fi
    ) &
    disown 2>/dev/null || true
fi

# Measure latency (fork-only, must be <50ms)
HOOK_END=$(date +%s%N 2>/dev/null || echo 0)
if [ "$HOOK_START" -ne 0 ] && [ "$HOOK_END" -ne 0 ]; then
    HOOK_LATENCY_MS=$(( (HOOK_END - HOOK_START) / 1000000 ))
    echo "[$HOOK_NAME] latency=${HOOK_LATENCY_MS}ms budget_commit=<50ms budget_total=<50ms" >> "$HOOK_LOG" 2>/dev/null || true
fi

exit 0
REFRESH

    chmod 0755 "$hook_file" 2>/dev/null || true
    trace_lifecycle "git-hook" "expert refresh hook installed (post-commit)"
}

# @trace spec:git-mirror-service, spec:forge-offline, spec:enclave-network
# rewrite_origin_for_enclave_push — host-mount-only remote rewrite.
#
# When TILLANDSIAS_PROJECT_HOST_MOUNT=1, the project workspace at
# /home/forge/src/<project> is a bind-mount of the host's working tree. The
# bind-mounted `.git/config` carries the host's `origin = https://github.com/...`,
# but the forge has zero credentials and no DNS for github.com — direct push fails
# with "Could not resolve host: github.com".
#
# This routine installs a container-ephemeral `url.<mirror>.insteadOf <github>`
# rule in `~/.gitconfig` (NOT the bind-mounted `.git/config`, which must stay
# pristine so the host's normal workflow keeps working). The rule redirects
# any push or fetch against the GitHub URL onto the enclave-local git mirror
# reachable at its per-project name `git://git-<project>/<project>`
# (order 659-8faj). The mirror owns the GitHub token (fetched from Vault at
# push time by the post-receive hook via vault-cli) and post-receive hook.
#
# Net effect inside the forge:
#   - `git remote -v` still shows the GitHub URL (matches user expectation).
#   - `git push origin <branch>` silently routes to `git://git-<project>/<project>`.
#   - The host's `.git/config` is never modified.
#
# Diagnostic forensics: the original origin URL is preserved under
# `tillandsias.original-origin` in the global config so debug runs can see
# what was rewritten without touching the bind-mounted repo config.
#
# Idempotent — re-running on each forge attach overwrites the same global
# config keys.

# @trace spec:git-mirror-service
# Order 659-8faj: the mirror's DNS identity is PER-PROJECT — the shared
# `tillandsias-git` / `git-service` aliases are retired and no longer resolve.
# The launcher injects the authoritative name (git_mirror_service_identity in
# tillandsias-headless, `git-{sanitized-project}`) as TILLANDSIAS_GIT_SERVICE.
# The fallback mirrors that derivation for simple project names and exists
# only for lanes where the launcher does not inject the variable (host-mount).
# Every mirror URL in this file MUST derive its host here — never a constant.
git_mirror_host() {
    printf '%s' "${TILLANDSIAS_GIT_SERVICE:-git-${TILLANDSIAS_PROJECT}}"
}

rewrite_origin_for_enclave_push() {
    # Only act when host-mount mode is active. Other transports (filesystem
    # /Windows-WSL, git daemon /Linux-podman) handle their own remote setup
    # in the clone branches below.
    [[ "${TILLANDSIAS_PROJECT_HOST_MOUNT:-}" == "1" ]] || return 0
    [[ -n "${TILLANDSIAS_PROJECT:-}" ]] || return 0

    local original
    original="$(git remote get-url origin 2>/dev/null || true)"
    if [[ -z "$original" ]]; then
        trace_lifecycle "git-mirror" "no origin on host-mounted repo; skipping rewrite"
        return 0
    fi

    # Only rewrite when the host's origin is a remote URL the forge cannot
    # reach (GitHub HTTPS/SSH). If it's already a local/enclave URL leave it.
    local needs_rewrite=0
    case "$original" in
        https://github.com/*|http://github.com/*|git@github.com:*|ssh://git@github.com/*)
            needs_rewrite=1
            ;;
    esac
    if [[ "$needs_rewrite" -ne 1 ]]; then
        trace_lifecycle "git-mirror" "origin ${original} is not GitHub; leaving as-is"
        return 0
    fi

    local mirror_url="git://$(git_mirror_host)/${TILLANDSIAS_PROJECT}"

    # Check whether the redirect is already installed (pre-injected by the
    # launcher's write_forge_gitconfig in order 224). If so, skip redundant
    # writes that would fail on the read-only injected global config mount.
    if git config --global --get-all "url.${mirror_url}.insteadOf" 2>/dev/null | grep -Fxq "$original"; then
        trace_lifecycle "git-mirror" "redirect already installed for ${original}; skipping"
        return 0
    fi

    # Stash the original under tillandsias.* in the GLOBAL config (ephemeral
    # ~/.gitconfig inside the forge — NOT the bind-mounted .git/config).
    # Forensic only; no functional dependency.
    git config --global "tillandsias.original-origin" "$original" 2>/dev/null || true
    git config --global "tillandsias.mirror-url" "$mirror_url" 2>/dev/null || true

    # Install the insteadOf redirect so `git push origin <branch>` (and any
    # explicit operation against the GitHub URL) routes through the mirror.
    # Use --global so this lands in ~/.gitconfig, NEVER in the bind-mounted
    # .git/config. Setting it under --local would persist to the host repo.
    git config --global --replace-all "url.${mirror_url}.insteadOf" "$original" 2>/dev/null || true

    # For SSH-style remotes also pre-compute the HTTPS equivalent and redirect
    # that too, so a user who runs `git push https://github.com/<org>/<repo>`
    # by hand also hits the mirror.
    if [[ "$original" == git@github.com:* ]]; then
        local nwo="${original#git@github.com:}"
        nwo="${nwo%.git}"
        local https_form="https://github.com/${nwo}.git"
        git config --global --add "url.${mirror_url}.insteadOf" "$https_form" 2>/dev/null || true
    fi

    trace_lifecycle "git-mirror" "host-mount origin rewrite: ${original} -> ${mirror_url}"
    echo "[forge] git push origin <branch> routes to the enclave mirror (${mirror_url}); upstream is ${original}."
}

# @trace spec:cross-platform, spec:git-mirror-service
# COMMON TAIL of clone_project_from_mirror (order 501, repair B6 —
# plan/issues/git-branching-methodology-research-2026-07-28.md §5.2): runs on
# EVERY clone transport (Linux git-daemon network, Windows/WSL filesystem,
# macOS staged filesystem) so no transport is left with the sticky-HEAD
# hazard. The host-mount path also runs this convergence step: the launcher
# already captured the operator checkout's branch as the launch-gated seed, and
# the mounted checkout may have moved between that gate and container startup.
# A failed switch remains fail-soft and is surfaced by the startup context as
# base_state=mismatch; the verdict never judges the branch by name.
#
# The mirror's HEAD symref is global and STICKY: a persisted mirror volume
# can hand a fresh clone branch Y after this launch's gate passed on branch
# X. The launcher pins the launch-gated branch in
# TILLANDSIAS_FORGE_SEED_BRANCH; check it out here via a fallback chain:
#   already on <seed>            -> no-op
#   git fetch origin <seed>      -> tolerated failure (mirror mid-reconcile
#                                   in its 120s window, or never-pushed seed)
#   <seed> local or origin/<seed> -> git switch <seed>
#   otherwise                    -> LOUD warning, stay on the clone's HEAD
# A hard `git clone -b <seed>` is FORBIDDEN (B6): it hard-fails the whole
# launch for a never-pushed branch and inside the reconcile window. This
# tail NEVER hard-fails — worst case is the clone's HEAD, which is exactly
# the pre-501 behavior. Unset/empty env -> no-op, byte-identical to today
# (end-user transparency).
#
# Caveat: a REUSED (not recreated) container carries creation-time env, so a
# stale seed is possible until the container is recreated.
checkout_forge_seed_branch() {
    local seed="${TILLANDSIAS_FORGE_SEED_BRANCH:-}"
    [[ -n "$seed" ]] || return 0

    local current
    current="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [[ "$current" == "$seed" ]]; then
        trace_lifecycle "git-mirror" "clone already on seed branch ${seed}"
        return 0
    fi

    # Refresh origin's view of the seed branch; tolerate failure (the mirror
    # may still be inside its reconcile window, or the branch may never have
    # been pushed). The clone itself already carries all mirror heads, so
    # this only narrows the race, it is not load-bearing.
    git fetch origin "$seed" >/dev/null 2>&1 || true

    if git show-ref --verify --quiet "refs/heads/${seed}" || \
       git show-ref --verify --quiet "refs/remotes/origin/${seed}"; then
        # `git switch` DWIMs a local tracking branch from origin/<seed> when
        # no local branch exists yet.
        if git switch "$seed" >/dev/null 2>&1; then
            trace_lifecycle "git-mirror" "checked out launch-gated seed branch ${seed} (clone HEAD was ${current:-detached})"
            echo "[forge] Checked out '${seed}' — the branch this launch was gated on."
        else
            echo "[forge] WARNING: seed branch '${seed}' exists but 'git switch ${seed}' failed; staying on '${current:-HEAD}'." >&2
            echo "[forge] Work will land on '${current:-HEAD}', which may NOT be the branch this launch was gated on." >&2
        fi
    else
        echo "[forge] WARNING: launch-gated seed branch '${seed}' was not found in the mirror clone; staying on '${current:-HEAD}'." >&2
        echo "[forge] The mirror may still be reconciling (120s window) or '${seed}' was never pushed. Work will land on '${current:-HEAD}'." >&2
    fi
    return 0
}

# @trace spec:cross-platform, spec:windows-wsl-runtime, spec:git-mirror-service, spec:forge-offline
# Shared clone-from-mirror routine for ALL forge entrypoints (opencode,
# claude, opencode-web, terminal). Two transports:
#   - filesystem  : TILLANDSIAS_GIT_MIRROR_PATH=/path/to/bare/mirror (Windows/WSL)
#   - git daemon  : TILLANDSIAS_GIT_SERVICE=host:port (Linux/podman)
#
# Idempotent: if /home/forge/src/<project> is a host-mounted project selected
# by the launcher, use it in place and never wipe it. Otherwise, if a stale
# ephemeral working tree exists, wipe it before cloning so re-attaches don't
# fail with "destination already exists".
#
# Returns 0 on successful clone, exits 1 on hard failure.
#
# NOTE (order 456 / 394 rung 1): the PUBLIC entry point is the thin
# `clone_project_from_mirror` wrapper defined immediately after this
# implementation. The wrapper is what every entrypoint calls; it delegates here
# and then starts the backgrounded expert build. The split exists because this
# implementation has FOUR success returns (host-mount, filesystem transport,
# git-daemon transport, fallback tail) — a hook appended to the last one would
# silently skip the other three, which is precisely the class of drift that
# left order 456's MCP server without a binary.
_clone_project_from_mirror_impl() {
    local clone_dir
    if [[ -z "${TILLANDSIAS_PROJECT:-}" ]]; then
        return 0  # nothing to clone — non-project session
    fi
    clone_dir="/home/forge/src/${TILLANDSIAS_PROJECT}"

    # Direct CLI/tray launches bind-mount the real host checkout at the same
    # path the mirror clone would normally occupy. Treat that as authoritative
    # project state. Wiping it would delete the user's checkout through the
    # bind mount.
    if [[ "${TILLANDSIAS_PROJECT_HOST_MOUNT:-}" == "1" ]] && [[ -d "$clone_dir" ]]; then
        trace_lifecycle "git-mirror" "using mounted project ${clone_dir}; mirror clone skipped"
        cd "$clone_dir" || return 1
        configure_git_identity
        # @trace spec:git-mirror-service, spec:forge-offline, spec:enclave-network
        # The bind-mounted `.git/config` carries the HOST's `origin = https://github.com/...`,
        # which the offline, credential-free forge cannot reach. Without rewriting,
        # `git push origin <branch>` fails with "Could not resolve host: github.com".
        #
        # Fix: install a `url.<mirror>.insteadOf <github>` rule in the container-ephemeral
        # `~/.gitconfig` (NOT in `.git/config`, which is bind-mounted from the host and
        # must stay pristine). This redirects any push/fetch against the GitHub URL to
        # the enclave-local git mirror, which has the GitHub token and runs the
        # post-receive hook to forward the push.
        #
        # `git remote -v` continues to show the GitHub URL (matches host expectation),
        # but the actual transport is the enclave mirror. The host's `.git/config` is
        # never modified — the host can keep using its own `origin` directly.
        rewrite_origin_for_enclave_push
        # Order 534: a bind-mounted checkout must converge just like every clone
        # transport. This is intentionally seed-based, never a Tillandsias
        # branch-name allowlist; end-user projects keep their own conventions.
        checkout_forge_seed_branch
        return 0
    fi

    # Wipe stale working tree (ephemeral-tree contract).
    if [[ -d "$clone_dir" ]]; then
        trace_lifecycle "git-mirror" "wiping stale working tree ${clone_dir}"
        if ! rm -rf "$clone_dir"; then
            echo "[forge] FATAL: refusing to continue after failing to remove stale working tree: ${clone_dir}" >&2
            echo "[forge] If this path is a mounted project, the launcher must set TILLANDSIAS_PROJECT_HOST_MOUNT=1." >&2
            exit 1
        fi
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
            # `git -C` resolves the gitdir for BOTH bare mirrors (Windows/WSL)
            # and non-bare staged checkouts (macOS clone lane, order 342).
            # `GIT_DIR=$src` only worked for bare repos: on a non-bare checkout
            # it reads <checkout>/config (absent) -> empty -> the push URL fell
            # back to the read-only staged path and every in-forge push died.
            # plan/issues/macos-clone-lane-push-remote-misalignment-2026-07-16.md
            mirror_origin="$(git -C "${src}" config --get remote.origin.url 2>/dev/null || true)"
            local github_url=""
            if [[ -n "$mirror_origin" ]]; then
                # Strip user[:password]@ prefix if present.
                github_url="$(echo "$mirror_origin" | sed -E 's#https://[^@/]+@#https://#')"
            fi
            if [[ -n "$github_url" ]] && [[ "$github_url" != "$src" ]]; then
                git remote set-url origin "$github_url" 2>/dev/null || true
                # Route GitHub-URL traffic back to ${src} ONLY when it is a
                # bare mirror (accepts pushes, forwards via post-receive with
                # the vault token). A non-bare staged checkout (macOS clone
                # lane) can never accept a push — it is mounted read-only and
                # denyCurrentBranch besides — so routing there just moves the
                # failure. Keep the honest GitHub origin instead: pushes fail
                # with a clear network/credential error until mirror routing
                # for this lane lands (same plan issue as above).
                if [[ "$(git -C "${src}" rev-parse --is-bare-repository 2>/dev/null)" == "true" ]]; then
                    git config --local "url.${src}.insteadOf" "$github_url" 2>/dev/null || true
                    trace_lifecycle "git-mirror" "origin presented as ${github_url}; routes to ${src}"
                elif [[ -n "${TILLANDSIAS_GIT_SERVICE:-}" ]]; then
                    # macOS clone lane (order 342): the staged source is non-bare
                    # + read-only and cannot accept a push, but the enclave git
                    # mirror IS running and relays to GitHub via the Vault token.
                    # Route pushes there — the same transport the network lane
                    # (git daemon, below) already uses — keeping the fast local
                    # clone while giving the forge a real push route.
                    git remote set-url --push origin "git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}" 2>/dev/null || true
                    trace_lifecycle "git-mirror" "origin presented as ${github_url}; pushes route to git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}"
                else
                    trace_lifecycle "git-mirror" "origin presented as ${github_url}; no push route (non-bare staged source)"
                fi
            else
                # No real GitHub remote on the mirror — keep the local path.
                git remote set-url --push origin "${src}" 2>/dev/null || true
            fi
            configure_git_identity
            # COMMON TAIL (order 501, B6): every transport, incl. this
            # Windows/WSL + macOS staged path, must defeat sticky-HEAD.
            checkout_forge_seed_branch
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
        trace_lifecycle "git-mirror" "cloning from git://$(git_mirror_host)/${TILLANDSIAS_PROJECT}"
        # Retry budget: the launcher-side wait_for_git_mirror_ready gate
        # (order 452 slice 2) blocks the launch until the mirror advertises a
        # resolvable HEAD, so this loop is the fail-loud BACKSTOP, not the
        # primary wait. Still, a first seed is a full-repo fetch from GitHub
        # through the proxy (~minutes on slow links, and the gate can be
        # skipped on lanes without a remote), so back off to ~60s instead of
        # the old 5x1s that guaranteed a crash during any real seed window.
        local max_retries=12
        local backoff
        for i in $(seq 1 $max_retries); do
            if [[ $i -le 6 ]]; then backoff=2; else backoff=5; fi
            if git clone "git://$(git_mirror_host)/${TILLANDSIAS_PROJECT}" "$clone_dir" 2>&1; then
                # @trace spec:git-mirror-service
                # A git daemon serving a mid-seed (still-empty) bare repo returns
                # a SUCCESSFUL clone of an EMPTY repository — git only prints
                # "warning: You appear to have cloned an empty repository" and
                # exits 0. That silently drops the agent into a checkout with no
                # HEAD and no files (the "forge had no checkout" symptom,
                # 2026-07-20). Assert ground truth: the clone MUST have a
                # resolvable HEAD. If not, the mirror has not finished seeding
                # from upstream — treat it like a not-ready mirror and RETRY
                # rather than proceeding, and FAIL LOUD (never launch on an empty
                # tree) once retries are exhausted.
                if ! git -C "$clone_dir" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
                    rm -rf "$clone_dir" 2>/dev/null || true
                    if [[ $i -lt $max_retries ]]; then
                        trace_lifecycle "git-mirror" "clone returned an EMPTY tree (mirror still seeding), retrying ($i/$max_retries, ${backoff}s)..."
                        sleep "$backoff"
                        continue
                    fi
                    echo "[forge] FATAL: git clone from git://$(git_mirror_host)/${TILLANDSIAS_PROJECT} produced an EMPTY checkout (no HEAD) after $max_retries attempts." >&2
                    # Distinguish the two failure classes so the operator fixes
                    # the right thing (they previously shared one misleading
                    # message that blamed seeding for a mirror-side defect):
                    #   - refs advertised but no HEAD line -> the mirror's HEAD
                    #     is unset/unborn (mirror defect; ensure-mirror-head in
                    #     the git image repairs this — the running container is
                    #     probably an OLD image);
                    #   - no refs at all -> the mirror has not finished seeding
                    #     from upstream, or upstream is genuinely empty.
                    local advertised
                    advertised="$(git ls-remote "git://$(git_mirror_host)/${TILLANDSIAS_PROJECT}" 2>/dev/null || true)"
                    if [[ -n "$advertised" ]] && ! echo "$advertised" | grep -q $'\tHEAD$'; then
                        echo "[forge] The mirror ADVERTISES refs but its HEAD is unset (unborn-HEAD mirror defect)." >&2
                        echo "[forge] Restart/rebuild the tillandsias-git container so ensure-mirror-head repairs it (images/git/ensure-mirror-head.sh)." >&2
                    else
                        echo "[forge] The mirror is reachable but advertised no cloneable refs — it has not finished seeding from upstream (or upstream is empty)." >&2
                    fi
                    echo "[forge] Refusing to launch an agent on an empty working tree." >&2
                    exit 1
                fi
                trace_lifecycle "git-mirror" "clone successful"
                cd "$clone_dir" || return 1
                git remote set-url --push origin "git://$(git_mirror_host)/${TILLANDSIAS_PROJECT}" 2>/dev/null || \
                    echo "[entrypoint] WARNING: Failed to set push URL — git push may not work" >&2
                configure_git_identity
                rewrite_origin_for_enclave_push
                # COMMON TAIL (order 501, B6): every transport, incl. this
                # network path, must defeat sticky-HEAD.
                checkout_forge_seed_branch
                echo "[forge] All changes must be committed to persist. Uncommitted work is lost on stop."
                return 0
            fi
            if [[ $i -lt $max_retries ]]; then
                trace_lifecycle "git-mirror" "git service not ready, retrying ($i/$max_retries, ${backoff}s)..."
                sleep "$backoff"
            else
                trace_lifecycle "git-mirror" "clone failed after $max_retries attempts"
            fi
        done
        echo "[forge] FATAL: git clone failed from git://$(git_mirror_host)/${TILLANDSIAS_PROJECT}" >&2
        echo "[forge] The git mirror service is unreachable or has not finished initialising." >&2
        exit 1
    fi

    # Fallback rewrite attempt for any remaining transport or edge case
    # where TILLANDSIAS_PROJECT_HOST_MOUNT may not have been propagated.
    rewrite_origin_for_enclave_push
    return 0
}

# clone_project_from_mirror — PUBLIC entry point for every forge lane.
#
# @trace order:456, plan/issues/experts-construction-research-2026-07-29.md §3
# Delegates to the implementation above, then starts the EXPERTS build in the
# background. Hooking here rather than in each `entrypoint-forge-*.sh` covers
# ALL agent lanes that get a checkout (opencode, opencode-web, claude, codex,
# antigravity, terminal) from a single site, so a new lane cannot ship without
# its plan expert. The research's hook point ("immediately after
# clone_project_from_mirror") is honoured exactly — the call is simply on the
# callee side of the boundary so it cannot be forgotten by a caller.
#
# The exit status of the clone is preserved verbatim: the expert build NEVER
# changes whether a launch proceeds.
clone_project_from_mirror() {
    local _clone_rc=0
    _clone_project_from_mirror_impl "$@" || _clone_rc=$?
    start_forge_experts_async || true
    return "$_clone_rc"
}

# ── Forge EXPERTS: launch-time build of the L0 plan query engine ─────────────
# @trace order:456, order:394 (rung 1, slice 1)
# @trace plan/issues/experts-construction-research-2026-07-29.md §3
# @trace spec:forge-environment-discoverability
#
# An "expert" is a CITED RETRIEVAL SURFACE behind an MCP tool, not a model. The
# plan expert is the compiled `tillandsias-plan` CLI, wrapped by the
# `forge-plan` MCP server (config-overlay/mcp/forge-plan.sh). Order 456 shipped
# that wrapper WITHOUT its payload: nothing in the image ever built or installed
# `tillandsias-plan`, so every MCP call answered "binary not found". This block
# is the payload.
#
# WHY BUILT AT LAUNCH INSTEAD OF BAKED INTO THE IMAGE
#   - `podman build` has NO enclave network (operator finding, order 459), so a
#     `cargo fetch`/`cargo build` in a Containerfile cannot resolve crates.io.
#   - The toolchain IS already in the image (Containerfile.base:23 installs
#     `rust cargo clippy rustfmt rust-analyzer cargo-deny`).
#   - `.crates.io` is allowlisted through the enclave proxy
#     (images/proxy/allowlist.txt:18) — the build goes through the proxy, never
#     direct egress.
#   - CARGO_HOME and CARGO_TARGET_DIR live on the persistent project cache
#     (see the cache block above), so a cold build is ~5s and a warm one is a
#     cargo no-op.
#
# IDEMPOTENT + EPHEMERAL
#   - Idempotent: keyed on a content hash of the plan crate's sources plus the
#     workspace lockfile. Same sources -> same state, no rebuild. Changed
#     sources -> rebuild and reinstall, converging on the same result.
#   - Ephemeral: the launch state lives in tmpfs (/dev/shm) and dies with the
#     container; the installed binary lives in the container-ephemeral
#     $HOME/.local/bin. The ONLY thing that outlives the container is the
#     sanctioned cargo cache — and per the research's §7.3 carve-out a compiled
#     binary in a cache volume is a BUILD ARTIFACT, not expert knowledge.
#
# NEVER GATES A LAUNCH
#   Every failure mode writes a NAMED degraded reason and returns 0, mirroring
#   order 486's warn-and-continue contract for inference. A missing binary
#   degrades the MCP server; it must never degrade the session.

# Install destination for the plan expert binary.
#
# CRITICAL: this MUST agree with the probe list in
# images/default/config-overlay/mcp/forge-plan.sh. A wrapper probing paths that
# no build step produces is EXACTLY the drift that made order 456 dead on
# arrival, so the agreement is pinned structurally by
# litmus:forge-plan-expert-build-shape.
# $HOME/.local/bin is already on PATH (see the PATH export near the top of this
# file), so the installed binary is reachable as plain `tillandsias-plan`.
FORGE_EXPERTS_BIN_DIR="${FORGE_EXPERTS_BIN_DIR:-$HOME/.local/bin}"
# tmpfs by construction — dies with the container, no reaper needed.
FORGE_EXPERTS_STATE_DIR="${FORGE_EXPERTS_STATE_DIR:-/dev/shm/tillandsias-experts}"
export FORGE_EXPERTS_BIN_DIR FORGE_EXPERTS_STATE_DIR

# PINNED STATE GRAMMAR (litmus:forge-plan-expert-build-shape):
#   experts: ready
#   experts: building(<n>s)
#   experts: degraded(<reason>)
# reason vocabulary (CLOSED set — never an ad-hoc string, never an ambiguous
# "may still be building"):
#   no-checkout    the expected project checkout is not a directory
#   no-plan-crate  this project has no crates/tillandsias-plan (most projects)
#   no-cargo       cargo is not on PATH in this image
#   build-failed   cargo build returned non-zero
#   build-timeout  cargo build exceeded FORGE_EXPERTS_BUILD_TIMEOUT
#   binary-missing cargo succeeded but produced no artifact
#   install-failed the artifact could not be installed to FORGE_EXPERTS_BIN_DIR
#   not-built      no build was ever started in this container
_forge_experts_set_state() {
    local state="$1" reason="${2:-}"
    mkdir -p "$FORGE_EXPERTS_STATE_DIR" 2>/dev/null || return 0
    if [ "$state" = "degraded" ]; then
        printf 'degraded:%s\n' "${reason:-unknown}" \
            > "$FORGE_EXPERTS_STATE_DIR/state" 2>/dev/null || true
    else
        printf '%s\n' "$state" > "$FORGE_EXPERTS_STATE_DIR/state" 2>/dev/null || true
    fi
    if [ "$state" = "building" ]; then
        date +%s > "$FORGE_EXPERTS_STATE_DIR/started_at" 2>/dev/null || true
    fi
    return 0
}

# forge_experts_state_line — render the pinned grammar on stdout.
# Consumed by inject_startup_context and by the forge-plan MCP wrapper's
# error text. Always succeeds; an unreadable/absent state file renders
# `degraded(not-built)` rather than an empty or ambiguous string.
forge_experts_state_line() {
    local state="" started=0 now=0 elapsed=0
    if [ -r "$FORGE_EXPERTS_STATE_DIR/state" ]; then
        state="$(cat "$FORGE_EXPERTS_STATE_DIR/state" 2>/dev/null || true)"
    fi
    case "$state" in
        ready)
            printf 'ready\n'
            ;;
        building)
            started="$(cat "$FORGE_EXPERTS_STATE_DIR/started_at" 2>/dev/null || echo 0)"
            case "$started" in
                '' | *[!0-9]*) started=0 ;;
            esac
            now="$(date +%s 2>/dev/null || echo 0)"
            elapsed=$((now - started))
            [ "$elapsed" -ge 0 ] || elapsed=0
            budget="${FORGE_EXPERTS_BUILD_BUDGET_SECS:-300}"
            if [ "$elapsed" -gt "$budget" ]; then
                printf 'degraded(build-abandoned-after-%ss)\n' "$elapsed"
            else
                printf 'building(%ss)\n' "$elapsed"
            fi
            ;;
        degraded:*)
            printf 'degraded(%s)\n' "${state#degraded:}"
            ;;
        *)
            printf 'degraded(not-built)\n'
            ;;
    esac
    return 0
}

# _forge_experts_source_hash — content key over the plan crate + lockfile.
# POSIX only (find | sort | cat | sha256sum). Any failure yields "unknown",
# which simply forces a rebuild that cargo itself deduplicates.
#
# ORDER 569: `capabilities.txt` is in the key alongside the .rs sources. It is
# compiled INTO the binary via include_str!, so a change to it changes what the
# expert reports about itself — but it is neither a .rs file nor Cargo.toml, so
# without this predicate the idempotency fast path below would see an unchanged
# hash, skip the rebuild, and leave a binary whose advertised capability set no
# longer matches the checkout. A capability probe that reports a stale answer is
# worse than no probe, because it is believed.
_forge_experts_source_hash() {
    local crate_dir="$1" project_dir="$2" out=""
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(
            {
                find "$crate_dir" -type f \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'capabilities.txt' \) -print0 2>/dev/null \
                    | sort -z | xargs -0 cat 2>/dev/null || true
                cat "$project_dir/Cargo.lock" 2>/dev/null || true
            } | sha256sum 2>/dev/null | cut -d' ' -f1
        )" || out=""
    fi
    printf '%s\n' "${out:-unknown}"
    return 0
}

_generic_project_set_state() {
    local state="$1" reason="${2:-}"
    mkdir -p "$FORGE_EXPERTS_STATE_DIR" 2>/dev/null || true
    if [ "$state" = "building" ]; then
        date +%s > "$FORGE_EXPERTS_STATE_DIR/generic_started_at" 2>/dev/null || true
        printf 'building\n' > "$FORGE_EXPERTS_STATE_DIR/generic_state" 2>/dev/null || true
    elif [ "$state" = "ready" ]; then
        printf 'ready\n' > "$FORGE_EXPERTS_STATE_DIR/generic_state" 2>/dev/null || true
    elif [ "$state" = "degraded" ]; then
        printf 'degraded:%s\n' "${reason:-not-built}" > "$FORGE_EXPERTS_STATE_DIR/generic_state" 2>/dev/null || true
    fi
}

# generic_project_state_line — return project-expert state token (C3)
# Grammar: ready | building(<n>s) | degraded(<reason>)
# Closed vocabulary: no-project-path | unreadable-path | index-failed | not-built
generic_project_state_line() {
    local state="" started=0 now=0 elapsed=0
    if [ -r "$FORGE_EXPERTS_STATE_DIR/generic_state" ]; then
        state="$(cat "$FORGE_EXPERTS_STATE_DIR/generic_state" 2>/dev/null || true)"
    fi
    case "$state" in
        ready)
            printf 'ready\n'
            ;;
        building)
            started="$(cat "$FORGE_EXPERTS_STATE_DIR/generic_started_at" 2>/dev/null || echo 0)"
            case "$started" in
                '' | *[!0-9]*) started=0 ;;
            esac
            now="$(date +%s 2>/dev/null || echo 0)"
            elapsed=$((now - started))
            [ "$elapsed" -ge 0 ] || elapsed=0
            budget="${FORGE_EXPERTS_BUILD_BUDGET_SECS:-300}"
            if [ "$elapsed" -gt "$budget" ]; then
                printf 'degraded(build-abandoned-after-%ss)\n' "$elapsed"
            else
                printf 'building(%ss)\n' "$elapsed"
            fi
            ;;
        degraded:*)
            printf 'degraded(%s)\n' "${state#degraded:}"
            ;;
        *)
            printf 'degraded(not-built)\n'
            ;;
    esac
    return 0
}

# discover_generic_project — build project index under tmpfs (C1, C2)
discover_generic_project() {
    local project_path=""
    if [ -n "${TILLANDSIAS_PROJECT_PATH:-}" ]; then
        project_path="$TILLANDSIAS_PROJECT_PATH"
    elif [ -n "${TILLANDSIAS_PROJECT:-}" ]; then
        project_path="/home/forge/src/${TILLANDSIAS_PROJECT}"
    fi
    [ -n "$project_path" ] || project_path="$PWD"

    if [ -z "$project_path" ]; then
        _generic_project_set_state degraded no-project-path
        return 0
    fi
    if [ ! -d "$project_path" ] || [ ! -r "$project_path" ]; then
        _generic_project_set_state degraded unreadable-path
        return 0
    fi

    local index_dir="$FORGE_EXPERTS_STATE_DIR/project-index"
    mkdir -p "$index_dir" 2>/dev/null || true

    # ORDER 669-egjn — the index carries the FULL deterministic subset
    # (commands/layout/actions with citable spans), derived by the baked
    # answer engine (`project-info.sh index`, the order-569 subcommand
    # pattern), so the document persisted here and the document
    # project_answer serves from cannot drift apart. The engine is
    # image-baked (order 459); when it is absent or fails, fall back to the
    # thin pre-669-egjn path/types/meta shape rather than degrading launch.
    local engine=""
    local engine_candidate=""
    for engine_candidate in \
        "${TILLANDSIAS_PROJECT_ENGINE:-}" \
        "/home/forge/.config-overlay/mcp/project-info.sh"; do
        [ -n "$engine_candidate" ] && [ -r "$engine_candidate" ] || continue
        engine="$engine_candidate"
        break
    done
    if [ -n "$engine" ] \
        && bash "$engine" index "$project_path" > "$index_dir/index.json.tmp" 2>/dev/null \
        && [ -s "$index_dir/index.json.tmp" ]; then
        mv -f "$index_dir/index.json.tmp" "$index_dir/index.json" 2>/dev/null || true
        _generic_project_set_state ready
        return 0
    fi
    rm -f "$index_dir/index.json.tmp" 2>/dev/null || true

    local types=""
    types="$(detect_project_types "$project_path" 2>/dev/null || echo "unknown")"
    local meta=""
    meta="$(get_project_metadata "$project_path" 2>/dev/null || echo "{}")"

    if [ -z "$meta" ] || [ "$meta" = "{}" ]; then
        _generic_project_set_state degraded index-failed
        return 0
    fi

    printf '{"path":"%s","types":"%s","meta":%s}\n' "$project_path" "$types" "$meta" > "$index_dir/index.json" 2>/dev/null || true
    _generic_project_set_state ready
    return 0
}

# start_forge_experts_async — publish `building` SYNCHRONOUSLY, then fork.
#
# Publishing before the fork removes the race where inject_startup_context
# (which runs later on the critical path) observes no state file at all and has
# to report something ambiguous. After this returns, the state file always
# exists and always carries a truthful token.
start_forge_experts_async() {
    if [ -z "${TILLANDSIAS_PROJECT:-}" ] && [ -z "${TILLANDSIAS_PROJECT_PATH:-}" ]; then
        # Non-project session: nothing was cloned, so there is nothing to build.
        return 0
    fi
    _forge_experts_set_state building
    _generic_project_set_state building
    (
        discover_generic_project >>/tmp/forge-lifecycle.log 2>&1 || true
        ensure_forge_experts >>/tmp/forge-lifecycle.log 2>&1 || true
    ) &
    return 0
}

# ensure_forge_experts — build + install the plan expert. FAIL-SOFT: always
# returns 0, always leaves a named state behind. Intended to be backgrounded.
ensure_forge_experts() {
    local project_dir crate_dir bin_dst stamp src_hash short_hash target_dir built
    local started rc=0 elapsed=0
    started="$(date +%s 2>/dev/null || echo 0)"

    project_dir=""
    if [ -n "${TILLANDSIAS_PROJECT:-}" ]; then
        project_dir="/home/forge/src/${TILLANDSIAS_PROJECT}"
    fi
    [ -n "$project_dir" ] || project_dir="$PWD"

    if [ ! -d "$project_dir" ]; then
        trace_lifecycle "experts" "degraded (no-checkout): ${project_dir} is not a directory"
        _forge_experts_set_state degraded no-checkout
        return 0
    fi

    crate_dir="$project_dir/crates/tillandsias-plan"
    if [ ! -f "$crate_dir/Cargo.toml" ]; then
        # NOT an error. Forges run on arbitrary projects and most have no plan
        # crate. Named explicitly so an agent reading the state is never left
        # guessing whether a build failed or was never applicable.
        trace_lifecycle "experts" "degraded (no-plan-crate): ${crate_dir}/Cargo.toml absent — this project has no plan expert"
        _forge_experts_set_state degraded no-plan-crate
        return 0
    fi

    bin_dst="$FORGE_EXPERTS_BIN_DIR/tillandsias-plan"
    stamp="$FORGE_EXPERTS_STATE_DIR/plan-source-hash"
    src_hash="$(_forge_experts_source_hash "$crate_dir" "$project_dir")"
    short_hash="$(printf '%s' "$src_hash" | cut -c1-12)"

    # Idempotency fast path: same sources + an installed binary => already
    # converged. A relaunched or rebuilt forge lands here.
    if [ "$src_hash" != "unknown" ] && [ -x "$bin_dst" ] && [ -r "$stamp" ] \
        && [ "$(cat "$stamp" 2>/dev/null || true)" = "$src_hash" ]; then
        trace_lifecycle "experts" "ready (cached): ${bin_dst} already matches source ${short_hash}"
        _forge_experts_set_state ready
        return 0
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        trace_lifecycle "experts" "degraded (no-cargo): cargo is not on PATH"
        _forge_experts_set_state degraded no-cargo
        return 0
    fi

    target_dir="${CARGO_TARGET_DIR:-$project_dir/target}"
    trace_lifecycle "experts" "building tillandsias-plan (src=${short_hash}, target=${target_dir}) — crates.io flows through the enclave proxy"

    # Bounded: a cargo target-dir lock held by a concurrent agent build must not
    # leave the state pinned at `building` forever.
    if command -v timeout >/dev/null 2>&1; then
        ( cd "$project_dir" && timeout "${FORGE_EXPERTS_BUILD_TIMEOUT:-600}" \
            cargo build --release -p tillandsias-plan ) || rc=$?
    else
        ( cd "$project_dir" && cargo build --release -p tillandsias-plan ) || rc=$?
    fi

    if [ "$rc" -eq 124 ]; then
        trace_lifecycle "experts" "degraded (build-timeout): cargo build exceeded ${FORGE_EXPERTS_BUILD_TIMEOUT:-600}s"
        _forge_experts_set_state degraded build-timeout
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        trace_lifecycle "experts" "degraded (build-failed): cargo build -p tillandsias-plan exited ${rc}"
        _forge_experts_set_state degraded build-failed
        return 0
    fi

    built="$target_dir/release/tillandsias-plan"
    if [ ! -x "$built" ]; then
        trace_lifecycle "experts" "degraded (binary-missing): cargo succeeded but ${built} is absent"
        _forge_experts_set_state degraded binary-missing
        return 0
    fi

    mkdir -p "$FORGE_EXPERTS_BIN_DIR" 2>/dev/null || true
    if ! install -m 0755 "$built" "$bin_dst" 2>/dev/null; then
        trace_lifecycle "experts" "degraded (install-failed): could not install ${built} -> ${bin_dst}"
        _forge_experts_set_state degraded install-failed
        return 0
    fi
    printf '%s\n' "$src_hash" > "$stamp" 2>/dev/null || true

    elapsed=$(( $(date +%s 2>/dev/null || echo 0) - started ))
    [ "$elapsed" -ge 0 ] || elapsed=0
    trace_lifecycle "experts" "ready: installed ${bin_dst} (src=${short_hash}) in ${elapsed}s"
    _forge_experts_set_state ready
    return 0
}

# ── Cache directory structure and staleness rules ─────────────────
# @trace spec:forge-cache-dual, spec:forge-staleness, spec:forge-shell-tools
# @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
#
# Forge containers use four distinct path categories. Each has a defined
# staleness policy and isolation guarantee:
#
# 1. SHARED CACHE (RO): /nix/store/
#    - Built into image at build time via Nix (reproducible, content-addressed)
#    - Read-only bind-mount from host nix store
#    - Populated only by nix-managed processes (single entry point)
#    - NEVER stale: versioned by image tag, updated only at image rebuild
#    - Isolation: N/A (all projects share the same nix store)
#
# 2. PER-PROJECT CACHE (RW): /home/forge/.cache/tillandsias-project/
#    - Bind-mount from host at ~/.cache/tillandsias/<project>/
#    - Populated by package managers (cargo, go, npm, maven, gradle, etc.)
#    - Expensive artifacts cached across container restarts within same project
#    - STALENESS RULE: compare ~/.cache/tillandsias/<project>/VERSION vs running image tag
#      If versions differ, cache is stale; recommend cache clear and rebuild
#    - Isolation: per-project only; project A cannot read project B's cache
#
# 3. PROJECT WORKSPACE: /home/forge/src/<project>/
#    - User's git repo (bind-mount from host working tree)
#    - SOURCE CODE ONLY — no build artifacts
#    - User-managed; tray never touches this directory
#    - Persistence: committed to git; survives container stop
#
# 4. EPHEMERAL: /tmp, /run/user/1000, and unmounted home dirs
#    - Kernel-enforced size caps: /tmp=256MB, /run/user/1000=64MB
#    - Container's overlayfs upper-dir for other writes (unbounded, backed by host disk)
#    - Lost on container stop (by design)
#    - Non-persistent: working space only
#
# The cache staleness check happens at container launch. Per the spec,
# stale caches are flagged but do NOT block attachment (user can clear manually
# or rebuild to refresh). The VERSION marker is placed by the tray at initial
# attach and compared on subsequent attaches.
#
# @trace spec:forge-cache-dual
export TILLANDSIAS_SHARED_CACHE="/nix/store"
PROJECT_CACHE="/home/forge/.cache/tillandsias-project"
export TILLANDSIAS_PROJECT_CACHE="$PROJECT_CACHE"
export TILLANDSIAS_WORKSPACE="/home/forge/src"
export TILLANDSIAS_EPHEMERAL="/tmp"

# Helper: check if per-project cache is stale relative to the running image.
# Usage: cache_is_stale <project_name> <image_version>
# Returns 0 (true) if stale, 1 (false) if fresh.
# @trace spec:forge-staleness
cache_is_stale() {
    local project="$1" image_version="$2"
    [ -z "$project" ] || [ -z "$image_version" ] && return 1

    local cache_version_file="$HOME/.cache/tillandsias/${project}/VERSION"
    if [ ! -f "$cache_version_file" ]; then
        # Cache version file does not exist — cache is stale.
        return 0
    fi

    local cache_version
    cache_version="$(cat "$cache_version_file" 2>/dev/null || echo "")"
    [ -z "$cache_version" ] && return 0

    # Compare versions. If they differ, cache is stale.
    [ "$cache_version" != "$image_version" ]
}

# Helper: record the image version in the per-project cache directory.
# Called once at first attach to establish the staleness baseline.
# Usage: record_cache_version <project_name> <image_version>
# @trace spec:forge-staleness
record_cache_version() {
    local project="$1" image_version="$2"
    [ -z "$project" ] || [ -z "$image_version" ] && return 1

    local cache_dir="$HOME/.cache/tillandsias/${project}"
    mkdir -p "$cache_dir" 2>/dev/null || return 1

    echo "$image_version" > "$cache_dir/VERSION" 2>/dev/null || return 1
    trace_lifecycle "cache" "recorded version ${image_version} for project ${project}"
    return 0
}

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

# PATH augmentation for per-project binaries, user home binaries, and system-wide toolchains
export RUSTUP_HOME="/usr/local/rustup"
export DART_ROOT="/opt/dart-sdk"
export FLUTTER_ROOT="/opt/flutter"
export TILLANDSIAS_CHEATSHEETS="/opt/cheatsheets"
export PATH="$NPM_CONFIG_PREFIX/bin:$CARGO_HOME/bin:$GOPATH/bin:$PNPM_HOME:$HOME/.cargo/bin:$HOME/go/bin:/usr/local/cargo/bin:$PROJECT_CACHE/dart/dart-sdk/bin:$PATH"


# ── FIRST_RUN prebuilt dev-tool install (arch-aware) ────────────
# @trace plan/issues/macos-forge-base-build-arch-and-fragility-2026-07-05.md (order 188)
# @trace plan/issues/forge-firstrun-tool-migration-2026-07-04.md (order 180)
#
# Moves the prebuilt cargo dev-tools OUT of container CREATION (the fragile
# hardcoded curl/tar chain in Containerfile.base that (a) baked non-executable
# x86_64 binaries on the aarch64 macOS guest and (b) hung `podman build` / VM
# setup on any stalled fetch) INTO an idempotent, fail-soft, timeout-guarded
# FIRST_RUN install into the persistent CARGO_HOME (order 179 named volume).
# Policy: prebuilt release-asset CDN URLs only — NO GitHub API, NO cargo install
# (source compile), NO cargo binstall (rate-limited API). See
# cheatsheets/build/nix-ci-incremental-release.md.

# Map the running machine arch to the release-asset arch token. Empty = unsupported.
_forge_uname_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "x86_64" ;;
        aarch64 | arm64) echo "aarch64" ;;
        *) echo "" ;;
    esac
}

# install_prebuilt <check_bin> <url>
# Idempotent (skip if $CARGO_HOME/bin/<check_bin> already executable), fail-soft
# (a fetch/extract miss is logged and RETRIED next launch — never fatal), and
# timeout-guarded (--max-time so a stalled fetch can NEVER hang the launch the way
# the CREATION-time chain hung the build). Extracts the archive's binaries into
# $CARGO_HOME/bin. The caller has already substituted the arch into <url>.
install_prebuilt() {
    local check_bin="$1" url="$2"
    local bindir="${CARGO_HOME:-/usr/local/cargo}/bin"
    [ -x "$bindir/$check_bin" ] && return 0
    mkdir -p "$bindir" 2>/dev/null || true
    # Multiple forge lanes for the same project share CARGO_HOME. Keep the
    # executable fast-path above first (a warm launch performs zero network
    # work), then serialize the cold miss per tool so concurrent lane starts
    # cannot fetch the same release asset repeatedly.
    local lock_root="${PROJECT_CACHE:-$HOME/.cache/tillandsias-project}/prebuilt-locks"
    local tool_lock="$lock_root/$check_bin.lock" waited=0
    mkdir -p "$lock_root" 2>/dev/null || true
    if ! mkdir "$tool_lock" 2>/dev/null; then
        # A killed cold installer may leave its empty mkdir lock behind.
        # Reclaim only after a generous bound; ordinary downloads are capped
        # at 120 seconds and must never be mistaken for stale work.
        if [ -d "$tool_lock" ] \
            && [ -n "$(find "$tool_lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
            rm -f "$tool_lock/owner.pid" 2>/dev/null || true
            rmdir "$tool_lock" 2>/dev/null || true
        fi
        while [ -d "$tool_lock" ] && [ "$waited" -lt 420 ]; do
            [ -x "$bindir/$check_bin" ] && return 0
            sleep 1
            waited=$((waited + 1))
        done
        [ -x "$bindir/$check_bin" ] && return 0
        mkdir "$tool_lock" 2>/dev/null || return 0
    fi

    (
        # BASHPID needs bash >= 4 (always true in the Linux image); the $PPID
        # fallback keeps the extracted-function test harness alive on bash 3.2.
        local tmp="" archive lock_owner="${BASHPID:-$(sh -c 'echo "$PPID"')}"
        printf '%s\n' "$lock_owner" >"$tool_lock/owner.pid" 2>/dev/null || true
        # shellcheck disable=SC2329 # invoked indirectly by trap
        _prebuilt_lock_cleanup() {
            [ -n "$tmp" ] && rm -rf "$tmp"
            if [ "$(cat "$tool_lock/owner.pid" 2>/dev/null || true)" = "$lock_owner" ]; then
                rm -f "$tool_lock/owner.pid" 2>/dev/null || true
                rmdir "$tool_lock" 2>/dev/null || true
            fi
        }
        trap _prebuilt_lock_cleanup EXIT
        trap 'exit 130' HUP INT TERM

        tmp="$(mktemp -d 2>/dev/null)" || return 0
        archive="$tmp/asset"
        if ! curl -fsSL --max-time 120 --retry 2 --retry-delay 3 "$url" -o "$archive" 2>/dev/null; then
            trace_lifecycle "tools" "prebuilt fetch failed (non-fatal, retry next launch): $check_bin"
            return 0
        fi
        case "$url" in
            *.tar.gz | *.tgz) tar -xzf "$archive" -C "$tmp" 2>/dev/null || true ;;
            *.tar.xz) tar -xJf "$archive" -C "$tmp" 2>/dev/null || true ;;
            *.zip) unzip -qo "$archive" -d "$tmp" 2>/dev/null || true ;;
        esac
        # Install every regular executable the archive carries (these are bare binary
        # distributions). basename-placed onto the persistent cache PATH.
        find "$tmp" -type f -perm -u+x ! -name asset 2>/dev/null | while read -r f; do
            install -m 0755 "$f" "$bindir/$(basename "$f")" 2>/dev/null || true
        done
        if [ -x "$bindir/$check_bin" ]; then
            trace_lifecycle "tools" "installed prebuilt $check_bin ($(uname -m))"
        else
            trace_lifecycle "tools" "prebuilt install incomplete (non-fatal, retry next launch): $check_bin"
        fi
        return 0
    )
}

# ensure_dart_sdk: FIRST_RUN, ARCH-AWARE install of the Dart SDK into the order-179
# persistent PROJECT_CACHE. Unlike the cargo dev-tools (single binaries handled by
# install_prebuilt), Dart ships as a FULL SDK that unpacks to a top-level `dart-sdk/`
# directory, so it gets its own helper. Idempotent (skip if the SDK's `dart` binary is
# already executable), fail-soft (a failed fetch is logged and RETRIED next launch —
# NEVER fatal), and timeout-guarded (--max-time so a stalled fetch can NEVER hang the
# launch the way the CREATION-time curl/unzip chain hung the aarch64 macOS VM build,
# where the baked x86_64 SDK was also non-executable). Dart's arch token differs from
# the cargo triple: x86_64 -> x64, aarch64 -> arm64.
# @trace plan/issues/forge-firstrun-tool-migration-2026-07-04.md (order 180 dart sub-slice)
ensure_dart_sdk() {
    local arch zarch
    arch="$(_forge_uname_arch)"
    case "$arch" in
        x86_64) zarch="x64" ;;
        aarch64) zarch="arm64" ;;
        *)
            trace_lifecycle "tools" "unsupported arch $(uname -m); skipping dart SDK"
            return 0
            ;;
    esac
    local sdk_bin="$PROJECT_CACHE/dart/dart-sdk/bin/dart"
    [ -x "$sdk_bin" ] && return 0
    mkdir -p "$PROJECT_CACHE/dart" 2>/dev/null || true
    local tmp archive url
    tmp="$(mktemp -d 2>/dev/null)" || return 0
    archive="$tmp/dart-sdk.zip"
    url="https://storage.googleapis.com/dart-archive/channels/stable/release/3.12.1/sdk/dartsdk-linux-${zarch}-release.zip"
    if ! curl -fsSL --max-time 300 "$url" -o "$archive" 2>/dev/null; then
        trace_lifecycle "tools" "dart SDK fetch failed (non-fatal, retry next launch): ${zarch}"
        rm -rf "$tmp"
        return 0
    fi
    # The zip carries a top-level dart-sdk/ dir; unzip -o overwrites a partial prior try.
    unzip -qo "$archive" -d "$PROJECT_CACHE/dart" 2>/dev/null || true
    if [ -x "$sdk_bin" ]; then
        trace_lifecycle "tools" "installed dart SDK ($(uname -m))"
    else
        trace_lifecycle "tools" "dart SDK install incomplete (non-fatal, retry next launch): ${zarch}"
    fi
    rm -rf "$tmp"
    return 0
}

# ensure_forge_prebuilt_tools: FIRST_RUN, ARCH-AWARE install of the cargo dev-tool
# group into the persistent CARGO_HOME. Idempotent + fail-soft; safe to call every
# launch (installed tools are skipped instantly). Intended to be backgrounded by
# the forge entrypoints so it never blocks the agent launch.
# NOTE: versions are a centralized pinned FLOOR (moved out of Containerfile.base);
# de-hardcoding to `releases/latest` (via the web redirect, NOT the API) is the
# next slice of order 180. This slice's job is the arch-correctness + de-fragiling
# that unblocks the aarch64 macOS guest.
ensure_forge_prebuilt_tools() {
    local arch
    arch="$(_forge_uname_arch)"
    if [ -z "$arch" ]; then
        trace_lifecycle "tools" "unsupported arch $(uname -m); skipping prebuilt dev-tools"
        return 0
    fi
    local gnu="${arch}-unknown-linux-gnu"
    local musl="${arch}-unknown-linux-musl"
    local qi="https://github.com/cargo-bins/cargo-quickinstall/releases/download"
    trace_lifecycle "tools" "ensuring prebuilt cargo dev-tools (arch=${arch}) in ${CARGO_HOME}/bin"

    install_prebuilt cargo-nextest "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-0.9.137/cargo-nextest-0.9.137-${gnu}.tar.gz"
    install_prebuilt cargo-chef "${qi}/cargo-chef-0.1.77/cargo-chef-0.1.77-${gnu}.tar.gz"
    install_prebuilt cargo-watch "${qi}/cargo-watch-8.5.3/cargo-watch-8.5.3-${gnu}.tar.gz"
    install_prebuilt cargo-audit "${qi}/cargo-audit-0.22.2/cargo-audit-0.22.2-${gnu}.tar.gz"
    install_prebuilt wasm-pack "${qi}/wasm-pack-0.15.0/wasm-pack-0.15.0-${gnu}.tar.gz"
    install_prebuilt typos "${qi}/typos-cli-1.47.2/typos-cli-1.47.2-${gnu}.tar.gz"
    install_prebuilt watchexec "${qi}/watchexec-cli-2.5.1/watchexec-cli-2.5.1-${gnu}.tar.gz"
    install_prebuilt cargo-upgrade "${qi}/cargo-edit-0.13.11/cargo-edit-0.13.11-${musl}.tar.gz"
    install_prebuilt cargo-expand "${qi}/cargo-expand-1.0.122/cargo-expand-1.0.122-${gnu}.tar.gz"
    install_prebuilt cargo-criterion "${qi}/cargo-criterion-1.1.0/cargo-criterion-1.1.0-${gnu}.tar.gz"
    install_prebuilt cargo-wasi "${qi}/cargo-wasi-0.1.28/cargo-wasi-0.1.28-${gnu}.tar.gz"
    install_prebuilt cargo-outdated "${qi}/cargo-outdated-0.19.0/cargo-outdated-0.19.0-${gnu}.tar.gz"
    install_prebuilt trunk "https://github.com/trunk-rs/trunk/releases/download/v0.22.0-beta.1/trunk-${gnu}.tar.gz"
    install_prebuilt cargo-llvm-cov "https://github.com/taiki-e/cargo-llvm-cov/releases/download/v0.8.7/cargo-llvm-cov-${gnu}.tar.gz"
    install_prebuilt cargo-semver-checks "https://github.com/obi1kenobi/cargo-semver-checks/releases/download/v0.48.0/cargo-semver-checks-${gnu}.tar.gz"

    # actionlint / vale / wasmtime — prebuilt, arch-aware (order 180 slice 2). These
    # use DIFFERENT arch tokens than the cargo `-unknown-linux-gnu` triple. Installed
    # onto the persistent cache PATH by install_prebuilt (dart's SDK is a separate
    # sub-slice — it unpacks to /opt/dart-sdk, not a single binary).
    local actionlint_arch vale_arch
    case "$arch" in
        x86_64) actionlint_arch="amd64"; vale_arch="64-bit" ;;
        aarch64) actionlint_arch="arm64"; vale_arch="arm64" ;;
    esac
    install_prebuilt actionlint "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_${actionlint_arch}.tar.gz"
    install_prebuilt vale "https://github.com/errata-ai/vale/releases/download/v3.14.2/vale_3.14.2_Linux_${vale_arch}.tar.gz"
    install_prebuilt wasmtime "https://github.com/bytecodealliance/wasmtime/releases/download/v45.0.0/wasmtime-v45.0.0-${arch}-linux.tar.xz"

    # Dart ships as a full SDK (unpacks a top-level dart-sdk/ dir), so it has its own
    # arch-aware first-run helper rather than install_prebuilt (single binaries). Runs
    # in this same backgrounded context. @trace order 180 dart sub-slice.
    ensure_dart_sdk

    # ── marksman Markdown LSP (single binary) ────────────────────
    # Unlike cargo dev-tools (archives), marksman is a raw GitHub release asset.
    # Idempotent: skip if already executable. Fail-soft: a failed fetch is logged
    # and retried next launch — never fatal. Uses the GitHub `latest` redirect
    # so the version is de-hardcoded (not pinned in Containerfile).
    # @trace order 180 marksman sub-slice
    local marksman_bin="${CARGO_HOME:-/usr/local/cargo}/bin/marksman"
    if [ ! -x "$marksman_bin" ]; then
        local marksman_arch
        case "$arch" in
            x86_64) marksman_arch="x64" ;;
            aarch64) marksman_arch="arm64" ;;
        esac
        if [ -n "$marksman_arch" ]; then
            if curl -fsSL --max-time 120 --retry 2 --retry-delay 3 \
                "https://github.com/artempyanykh/marksman/releases/latest/download/marksman-linux-${marksman_arch}" \
                -o "$marksman_bin" 2>/dev/null; then
                chmod +x "$marksman_bin" 2>/dev/null || true
                trace_lifecycle "tools" "installed marksman ($arch)"
            else
                trace_lifecycle "tools" "marksman fetch failed (non-fatal, retry next launch)"
            fi
        fi
    fi

    trace_lifecycle "tools" "prebuilt dev-tools ensured (arch=${arch})"
}

# ── Agent harness EVERY_LAUNCH update ──────────────────────────
# ── Harness health probe + last-good rollback (order 284) ───
# The 2026-07-10 outage: upstream published a broken opencode-ai@latest
# mid-night, the EVERY_LAUNCH refresh installed it, and the whole forge
# lane was down until upstream fixed it. @latest is structurally unsafe
# without a survival path, so every update is now probed and a broken
# fresh install rolls back to the last KNOWN-GOOD version recorded in the
# persistent npm cache.
# ── Harness CONTRACT verification (order 439) ───────────────
# Liveness is not enough. An upstream release can start cleanly while having
# renamed or dropped a flag we pass, and `--version` will happily report OK:
#
#   * order 429 found the forge passing `--dangerously-skip-permissions` to
#     opencode — a flag it DOES NOT HAVE. yargs is non-strict, so it was
#     silently swallowed for an unknown length of time while the lane's
#     permissive behaviour actually came from the config overlay.
#   * order 431 is blocked because we would depend on the UNDOCUMENTED
#     OPENCODE_AUTH_CONTENT for keeping credentials off disk; a release that
#     renames it passes a liveness probe while credentials silently revert to
#     auth.json — inside the container built to keep them off disk.
#
# So the probe now asserts the contracts we actually rely on. A harness that
# starts but no longer accepts a flag we pass is broken FOR US, and takes the
# same last-good rollback path as a crashing one (order 284).
#
# Keep these lists in sync with the entrypoints that pass the flags. A flag
# listed here and absent upstream is a LOUD failure by design — that is the
# whole point.

# OpenCode Vault auth (order 431) ─────────────────────────────
# The existing credential producer remains secret/gemini/api-key. Every
# interactive/Web path reaches the scoped CLI launch and mounts an
# opencode-forge AppRole token. This function reads that source and adapts it to
# OPENCODE_AUTH_CONTENT in memory. No credential document is materialized under
# XDG_DATA_HOME.
opencode_auth_file_path() {
    printf '%s/opencode/auth.json\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

opencode_remove_stale_auth_file() {
    local auth_file
    auth_file="$(opencode_auth_file_path)"
    if [ -e "$auth_file" ] || [ -L "$auth_file" ]; then
        if ! rm -f -- "$auth_file" 2>/dev/null; then
            trace_lifecycle "credentials" "opencode: refusing launch; stale auth.json could not be removed"
            return 1
        fi
    fi
    if [ -e "$auth_file" ] || [ -L "$auth_file" ]; then
        trace_lifecycle "credentials" "opencode: refusing launch; stale auth.json remains"
        return 1
    fi
    return 0
}

prepare_opencode_vault_auth() {
    opencode_remove_stale_auth_file || return 1

    if [ "${TILLANDSIAS_OPENCODE_AUTH_EXPECTED:-0}" != "1" ]; then
        # Never honor an ambient, non-Vault credential.
        unset OPENCODE_AUTH_CONTENT
        return 0
    fi

    local gemini_key auth_content
    # The marker is launcher-owned, but the surrounding process environment
    # is not a credential source. Always replace any ambient document with the
    # value read through this lane's scoped Vault token.
    unset OPENCODE_AUTH_CONTENT
    if ! gemini_key="$(vault-cli.sh read -field=key secret/gemini/api-key 2>/dev/null)" \
        || [ -z "$gemini_key" ]; then
        trace_lifecycle "credentials" "opencode: Vault credential was expected but could not be read"
        return 1
    fi
    if ! auth_content="$(printf '%s' "$gemini_key" \
        | jq -Rsc '{google:{type:"api",key:.}}' 2>/dev/null)"; then
        unset gemini_key
        trace_lifecycle "credentials" "opencode: could not assemble Vault auth content"
        return 1
    fi
    unset gemini_key

    if ! printf '%s' "$auth_content" \
        | jq -e 'type == "object" and length > 0' >/dev/null 2>&1; then
        trace_lifecycle "credentials" "opencode: Vault auth content is malformed"
        return 1
    fi
    OPENCODE_AUTH_CONTENT="$auth_content"
    export OPENCODE_AUTH_CONTENT
    unset auth_content
    return 0
}

# Probe the undocumented environment contract itself, independent of any real
# credential. The sentinel is generated at runtime, used only in an isolated
# temp state tree, and never printed or committed as fixture data.
opencode_auth_contract_ok() {
    local bin_path="$1" probe_root probe_key probe_content probe_output auth_file
    local probe_status=0
    probe_root="$(mktemp -d /tmp/tillandsias-opencode-auth-probe.XXXXXX)" || return 1
    probe_key="tillandsias-probe-${RANDOM:-0}-$$-$(date +%s%N 2>/dev/null || date +%s)"
    probe_content="$(printf '%s' "$probe_key" \
        | jq -Rsc '{"tillandsias-contract-probe":{type:"api",key:.}}')" \
        || probe_status=1
    if [ "$probe_status" -eq 0 ]; then
        probe_output="$(
            XDG_DATA_HOME="$probe_root/data" \
            XDG_STATE_HOME="$probe_root/state" \
            OPENCODE_DB=:memory: \
            OPENCODE_AUTH_CONTENT="$probe_content" \
            timeout 30 "$bin_path" auth list 2>&1
        )" || probe_status=1
    fi
    auth_file="$probe_root/data/opencode/auth.json"
    if [ "$probe_status" -eq 0 ] \
        && { [ -e "$auth_file" ] || [ -L "$auth_file" ]; }; then
        probe_status=1
    fi
    if [ "$probe_status" -eq 0 ] \
        && ! printf '%s' "$probe_output" | grep -qF "tillandsias-contract-probe"; then
        probe_status=1
    fi
    if [ "$probe_status" -eq 0 ] \
        && ! printf '%s' "$probe_output" | grep -Eq '(^|[^0-9])1 credentials?([^0-9]|$)'; then
        probe_status=1
    fi
    if [ "$probe_status" -eq 0 ] \
        && grep -R -a -F -f <(printf '%s' "$probe_key") \
            "$probe_root" >/dev/null 2>&1; then
        probe_status=1
    fi
    rm -rf -- "$probe_root"
    if [ "$probe_status" -ne 0 ] || [ -e "$probe_root" ]; then
        trace_lifecycle "harness" "opencode AUTH CONTRACT BROKEN — env credential was not parsed cleanly without disk state"
        return 1
    fi
    return 0
}

# Positive assertion for the credential actually injected into this lane. The
# isolated probe compares OpenCode's reported count and provider IDs with the
# in-memory JSON, checks both probe and real XDG paths for auth.json, and never
# emits command output or credential values.
opencode_actual_auth_ok() {
    local bin_path="$1" expected_count providers provider
    local probe_root probe_output normalized_output auth_file real_auth_file status=0
    [ "${TILLANDSIAS_OPENCODE_AUTH_EXPECTED:-0}" = "1" ] || return 0
    [ -n "${OPENCODE_AUTH_CONTENT:-}" ] || return 1

    expected_count="$(printf '%s' "$OPENCODE_AUTH_CONTENT" \
        | jq -er 'if type == "object" and length > 0 then length else error("empty") end')" \
        || return 1
    providers="$(printf '%s' "$OPENCODE_AUTH_CONTENT" | jq -er 'keys[]')" || return 1
    probe_root="$(mktemp -d /tmp/tillandsias-opencode-auth-actual.XXXXXX)" || return 1
    probe_output="$(
        XDG_DATA_HOME="$probe_root/data" \
        XDG_STATE_HOME="$probe_root/state" \
        OPENCODE_DB=:memory: \
        timeout 30 "$bin_path" auth list 2>&1
    )" || status=1
    normalized_output="$(printf '%s' "$probe_output" \
        | sed $'s/\033\\[[0-9;]*[[:alpha:]]//g' \
        | tr '[:upper:]' '[:lower:]')"
    auth_file="$probe_root/data/opencode/auth.json"
    real_auth_file="$(opencode_auth_file_path)"
    if [ -e "$auth_file" ] || [ -L "$auth_file" ] \
        || [ -e "$real_auth_file" ] || [ -L "$real_auth_file" ]; then
        status=1
    fi
    if [ "$status" -eq 0 ] \
        && ! printf '%s' "$normalized_output" \
            | grep -Eq "(^|[^0-9])${expected_count} credentials?([^0-9]|$)"; then
        status=1
    fi
    if [ "$status" -eq 0 ]; then
        while IFS= read -r provider; do
            if ! printf '%s' "$normalized_output" \
                | grep -qF -- "$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"; then
                status=1
                break
            fi
        done <<<"$providers"
    fi
    rm -rf -- "$probe_root"
    if [ "$status" -ne 0 ] || [ -e "$probe_root" ]; then
        trace_lifecycle "credentials" "opencode: injected Vault credential failed the no-auth.json contract"
        return 1
    fi
    trace_lifecycle "credentials" "opencode: Vault auth content parsed; auth.json absent"
    return 0
}

harness_contract_help_cmd() {
    # Flags live on subcommands, so each harness needs its own help invocation.
    case "$1" in
        opencode) echo "run --help" ;;
        codex)    echo "exec --help" ;;
        *)        echo "" ;;
    esac
}

harness_contract_flags() {
    case "$1" in
        # entrypoint-forge-opencode.sh: `opencode run --auto [--format json]`
        opencode) echo "--auto --format" ;;
        # entrypoint-forge-codex.sh: `codex exec --dangerously-bypass-approvals-and-sandbox [--json --output-last-message]`
        codex)    echo "--json --output-last-message --dangerously-bypass-approvals-and-sandbox" ;;
        *)        echo "" ;;
    esac
}

harness_contract_ok() {
    # $1 = binary name, optional $2 = exact binary path. Returns 0 when every
    # flag we pass still exists, or when no contract is declared for this
    # harness.
    local bin="$1"
    local bin_path="${2:-${NPM_CONFIG_PREFIX:-/usr/local}/bin/$bin}"
    local help_cmd flags help_out missing=""
    help_cmd="$(harness_contract_help_cmd "$bin")"
    flags="$(harness_contract_flags "$bin")"
    [ -n "$help_cmd" ] && [ -n "$flags" ] || return 0

    # shellcheck disable=SC2086
    help_out="$(timeout 30 "$bin_path" $help_cmd 2>&1)" || return 0
    [ -n "$help_out" ] || return 0

    for f in $flags; do
        printf '%s' "$help_out" | grep -qF -- "$f" || missing="$missing $f"
    done
    if [ -n "$missing" ]; then
        trace_lifecycle "harness" "$bin CONTRACT BROKEN — flags we pass are absent upstream:$missing"
        return 1
    fi
    return 0
}

harness_probe() {
    # $1 = binary name. Liveness (--version within a short timeout) AND the
    # contracts we depend on (order 439). Both must hold: a harness that starts
    # but silently ignores our flags is not usable, it just fails invisibly.
    local bin_path="${2:-${NPM_CONFIG_PREFIX:-/usr/local}/bin/$1}"
    [ -x "$bin_path" ] && timeout 30 "$bin_path" --version >/dev/null 2>&1 \
        && harness_contract_ok "$1" "$bin_path" \
        && { [ "$1" != "opencode" ] || opencode_auth_contract_ok "$bin_path"; }
}

harness_last_good_file() {
    # $1 = binary name → stamp file in the persistent npm prefix.
    echo "${NPM_CONFIG_PREFIX:-$HOME/.cache}/last-good-$1.version"
}

harness_record_last_good() {
    # $1 = binary, $2 = npm package. Probe first; record only working installs.
    local ver
    harness_probe "$1" || return 1
    ver="$(npm ls -g --depth=0 "$2" 2>/dev/null | grep -oE '@[0-9][^ ]*' | tail -1 | tr -d '@')"
    [ -n "$ver" ] && echo "$ver" > "$(harness_last_good_file "$1")" 2>/dev/null
    return 0
}

# ensure_forge_harnesses: refresh agent harnesses through their declared channels
# at launch. Runs in the background
# so it never blocks the agent launch. Fail-soft: if npm is offline or the proxy
# is unreachable, the baked/cached version is used silently (no hard fail).
# A fresh install that fails the health probe rolls back to the recorded
# last-good version (order 284).
# @trace plan/issues/forge-harness-every-launch-latest-2026-07-04.md (order 181)
ensure_forge_harnesses() {
    # Avoid a concurrent npm join race — only the first process runs npm.
    local npm_lock="$HOME/.cache/tillandsias-project/npm-update.lock"
    if ! mkdir "$npm_lock" 2>/dev/null; then
        # Self-heal locks leaked by the pre-fix trap bug (they live on the
        # PERSISTENT volume, so one leak used to disable updates forever):
        # a real concurrent updater finishes in minutes — reclaim after 1h.
        if [ -d "$npm_lock" ] && [ -n "$(find "$npm_lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
            trace_lifecycle "harness" "reclaiming stale npm-update lock (leaked pre-fix)"
            rm -rf "$npm_lock"
            mkdir "$npm_lock" 2>/dev/null || return 0
        else
            return 0
        fi
    fi
    # Ensure we clean up the lock on exit (even forked). The path MUST be
    # expanded NOW (double quotes): a single-quoted "$npm_lock" is expanded
    # when the EXIT trap fires, after this function's `local` is out of
    # scope — under set -u the trap then dies unbound and the lock dir
    # LEAKS onto the persistent volume, silently disabling every future
    # harness update (found by scripts/test-harness-rollback.sh, order 284).
    # shellcheck disable=SC2064
    trap "rm -rf '$npm_lock'" EXIT

    local npm_bin
    npm_bin="$(command -v npm 2>/dev/null)"
    if [ -z "$npm_bin" ]; then
        trace_lifecycle "harness" "npm not available; skipping harness update"
        return 0
    fi

    # Keep a diagnostic timestamp, but do not use it as a gate: the launch
    # contract is that every ephemeral forge launch attempts to refresh all
    # harnesses.  Installers are idempotent and cached binaries remain the
    # fail-soft fallback when the proxy is unavailable.
    local update_stamp="$HOME/.cache/tillandsias-project/harness-update-stamp"
    date +%s > "$update_stamp" 2>/dev/null || true

    # Official vendor installers are the source of truth for OpenCode and
    # Claude. They write only into the persistent harness-curl cache. OpenCode
    # is attempted every launch; Claude may use its bounded, version-matched
    # currentness record so a recent warm launch performs zero network work.
    if declare -F curl_install_opencode >/dev/null 2>&1; then
        curl_install_opencode || trace_lifecycle "harness" "opencode curl refresh failed (using cache)"
    fi
    if declare -F curl_install_claude >/dev/null 2>&1; then
        curl_install_claude || trace_lifecycle "harness" "claude curl refresh failed (using cache)"
    fi

    # Update each harness to latest. We use `npm install` (not `npm update`) so
    # a missing or removed package is installed rather than silently skipped.
    # Uses $NPM_CONFIG_PREFIX (persistent cache, set in lib-common.sh).
    # opencode and claude-code left this list 2026-07-21 (order 459): they
    # are curl-managed at every launch by require_opencode/require_claude
    # (official vendor installers, persistent-cache backed). Only the
    # npm-channel harnesses remain here.
    local pkg bin lg
    for pkg in "@fission-ai/openspec" "@openai/codex"; do
        case "$pkg" in
            "@fission-ai/openspec") bin=openspec ;;
            "@openai/codex") bin=codex ;;
        esac
        # stdout MUST be muted too: this function is backgrounded by the agent
        # entrypoints and shares the TTY with a live TUI — npm's "added N
        # packages" stdout lands mid-frame and corrupts the agent's display
        # (operator repro 2026-07-12: OpenCode tray lane escape-char spill).
        if ! "$npm_bin" install -g --no-audit --no-fund "$pkg@latest" >/dev/null 2>&1; then
            trace_lifecycle "harness" "npm update failed for $pkg (non-fatal, using cached)"
            continue
        fi
        if harness_record_last_good "$bin" "$pkg"; then
            continue
        fi
        # Fresh @latest is broken (the order-284 class). Roll back to the
        # recorded last-good version when we have one; otherwise leave the
        # broken install in place and trace loudly (the entrypoint's
        # require path surfaces it with the real error).
        lg="$(cat "$(harness_last_good_file "$bin")" 2>/dev/null || true)"
        if [ -n "$lg" ]; then
            trace_lifecycle "harness" "$pkg@latest FAILED health probe — rolling back to last-good $lg"
            if "$npm_bin" install -g --no-audit --no-fund "$pkg@$lg" >/dev/null 2>&1 && harness_probe "$bin"; then
                trace_lifecycle "harness" "$pkg rollback to $lg OK"
            else
                trace_lifecycle "harness" "$pkg rollback to $lg FAILED (broken install remains)"
            fi
        else
            trace_lifecycle "harness" "$pkg@latest FAILED health probe and no last-good recorded (upstream-broken publish?)"
        fi
    done

    # Antigravity has no npm package; use its official installer on every
    # launch.  require_antigravity is fail-soft here, while the primary
    # antigravity entrypoint still emits an actionable fatal message when no
    # cached binary exists.
    if declare -F require_antigravity >/dev/null 2>&1; then
        require_antigravity || trace_lifecycle "harness" "antigravity refresh failed (using cache)"
    fi

    # Order 299 first-run floor: fail-soft is only sound when a cached
    # harness exists to fall back to. On a PRISTINE cache (fresh curl-install,
    # post `podman system reset`) a dead proxy means every install above
    # failed and NOTHING is present — the operator gets a healthy-looking
    # banner and four bare `command not found`s. Detect the zero-harness
    # state, say so loudly on stderr (this function is backgrounded but its
    # stderr reaches the lane terminal), and clear the cadence stamp so the
    # very next launch retries instead of waiting out the 6h window. The
    # update path stays silent as designed: with any cached harness present
    # the floor check passes and this branch is never reached.
    local floor_prefix="${NPM_CONFIG_PREFIX:-/usr/local}" floor_bin any_harness=0
    # Fallback dir override exists for the fixtures in
    # scripts/test-harness-rollback.sh (a dev host's own /usr/local/bin
    # must not satisfy the floor check under test).
    local floor_fallback="${TILLANDSIAS_HARNESS_FALLBACK_DIR:-/usr/local/bin}"
    for floor_bin in opencode claude codex openspec; do
        if [ -x "$floor_prefix/bin/$floor_bin" ] || [ -x "$floor_fallback/$floor_bin" ]; then
            any_harness=1
            break
        fi
    done
    # Curl-managed harnesses (order 459) satisfy the floor from their own
    # persistent cache locations. Default-expanded so fixtures that extract
    # this function alone (test-harness-rollback.sh) stay set -u clean.
    local floor_curl_root="${HARNESS_CURL_ROOT:-$HOME/.cache/tillandsias-project/harness-curl}"
    if [ "$any_harness" = "0" ]; then
        if [ -x "$floor_curl_root/opencode/bin/opencode" ] || [ -x "$floor_curl_root/claude/bin/claude" ]; then
            any_harness=1
        fi
    fi
    if [ "$any_harness" = "0" ]; then
        rm -f "$update_stamp" 2>/dev/null || true
        trace_lifecycle "harness" "FIRST-RUN FLOOR: zero harnesses present after install attempt"
        {
            echo ""
            echo "WARNING: no agent harness is installed (opencode/claude/codex/openspec"
            echo "all missing) and the launch-time npm installs failed. This is almost"
            echo "always dead enclave egress — e.g. 'Could not resolve proxy: proxy'."
            echo "Fix egress (or relaunch the forge: installs retry at every launch),"
            echo "or retry by hand: npm install -g opencode-ai@latest"
            echo ""
        } >&2
        return 0
    fi

    trace_lifecycle "harness" "agent harnesses up to date"
}

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

# ── Coding agents (installed EVERY_LAUNCH / persistent cache) ──
# @trace spec:default-image, spec:forge-shell-tools
# @trace plan/issues/forge-harness-every-launch-latest-2026-07-04.md (order 181)
# Nothing is baked at image CREATION (order 181): harnesses live in the
# order-179 persistent npm volume and are (re)installed at launch. After
# `podman system reset` that volume is EMPTY, so the install path below is
# the only source — it must be fail-SOFT. These helpers always return 0;
# on failure they leave *_BIN pointing at a non-executable path and trace
# the real npm error (previously discarded to /dev/null, which made every
# post-reset launch die as an unexplained exit 1 under `set -e` because
# the bare `require_*` call propagated the return 1 through the entrypoint).
# Entrypoints whose PRIMARY agent is missing must check `[ -x "$*_BIN" ]`
# themselves and fail with an actionable message (see harness_missing_fatal).
_require_harness() {
    # $1=friendly-name  $2=npm-package  $3=bin-name  → echoes resolved path
    local name="$1" pkg="$2" bin="$3" path errlog
    path="${NPM_CONFIG_PREFIX:-/usr/local}/bin/$bin"
    [ -x "$path" ] || path="${TILLANDSIAS_HARNESS_FALLBACK_DIR:-/usr/local/bin}/$bin"
    # Updater race (2026-07-11 gate incident): a SIBLING container's
    # background ensure_forge_harnesses replaces the shared prefix's bin
    # symlinks non-atomically, so a launch landing in that window sees the
    # harness "missing" and then races a SECOND npm against the same
    # prefix (fails in ~1s with mid-state errors). If the npm-update lock
    # is held, wait for the updater (bounded 90s; a lock is stale only
    # via the 1h reclaim path) and re-check before deciding anything.
    if [ ! -x "$path" ] && [ -d "$HOME/.cache/tillandsias-project/npm-update.lock" ]; then
        trace_lifecycle "harness" "$name not visible while updater lock held — waiting for sibling npm update"
        local waited=0
        while [ -d "$HOME/.cache/tillandsias-project/npm-update.lock" ] && [ "$waited" -lt 90 ]; do
            sleep 2
            waited=$((waited + 2))
            path="${NPM_CONFIG_PREFIX:-/usr/local}/bin/$bin"
            [ -x "$path" ] || path="${TILLANDSIAS_HARNESS_FALLBACK_DIR:-/usr/local/bin}/$bin"
            [ -x "$path" ] && break
        done
        [ -x "$path" ] && trace_lifecycle "harness" "$name appeared after ${waited}s (sibling updater)"
    fi
    if [ ! -x "$path" ]; then
        trace_lifecycle "harness" "$name missing — install latest"
        errlog="$(mktemp /tmp/npm-install-${bin}.XXXXXX 2>/dev/null || echo /tmp/npm-install-$bin.err)"
        if ! npm install -g --no-audit --no-fund "$pkg@latest" >"$errlog" 2>&1; then
            trace_lifecycle "harness" "$name install FAILED (non-fatal): $(tail -3 "$errlog" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
            trace_lifecycle "harness" "$name install log: $errlog"
            echo "$path"
            return 0
        fi
        rm -f "$errlog" 2>/dev/null || true
        path="${NPM_CONFIG_PREFIX:-/usr/local}/bin/$bin"
        # Seed the order-284 rollback point: the first working install of a
        # fresh cache becomes last-good so a later broken @latest can revert.
        harness_record_last_good "$bin" "$pkg" 2>/dev/null || true
    fi
    if [ -x "$path" ]; then
        trace_lifecycle "install" "$name: available ($("$path" --version 2>/dev/null || echo 'unknown'))"
    fi
    echo "$path"
}

# Fatal-with-explanation path for entrypoints whose PRIMARY agent is absent.
# Prints an actionable banner (the exit_pause trap only shows a bare exit
# code) and exits 1 — callers invoke this INSTEAD of letting set -e fire.
harness_missing_fatal() {
    local name="$1"
    echo "" >&2
    echo "ERROR: the '$name' agent harness is not installed and its launch-time" >&2
    echo "npm install failed (see the 'harness' lifecycle lines above for the" >&2
    echo "real npm error — commonly enclave egress/proxy after 'podman system" >&2
    echo "reset' emptied the persistent npm cache volume)." >&2
    echo "Recovery: check network/proxy, then relaunch — the install retries" >&2
    echo "at every launch. A maintenance terminal still works for diagnosis." >&2
    exit 1
}

# ── Curl-installed harnesses (order 459) ───────────────────────────────
# @trace spec:default-image
# Operator directive 2026-07-21: Claude Code and OpenCode come from their
# OFFICIAL vendor curl installers at CONTAINER LAUNCH — not npm@latest (the
# order-284 rollback class: the npm channel repeatedly broke or lagged the
# real releases, which is why order 431 wanted a pin) and not brew (Linux is
# caskless for the siblings; attestation needs a token injection that drifts
# the credential-free spec, order 435). IMAGE BUILD time cannot curl — the
# enclave network/proxy does not exist during `podman build` (the original
# reason these installers "failed in the Containerfile") — so the install
# runs at LAUNCH with ephemerality + idempotency semantics:
#   - the official installer is the refresh source of truth; Claude may skip
#     it for 600s only when the same locally validated version completed a
#     prior official refresh (warm/current restarts reuse instantly);
#   - installs land on the PERSISTENT tool-cache volume
#     ($HOME/.cache/tillandsias-project), surviving container restarts;
#   - offline / proxy-down: fall back to the cached binary silently
#     (fail-soft), fatal only when no cached binary exists either — same
#     posture as the npm channel it replaces.
# Codex/Antigravity stay on npm for now (operator: "maybe later").
HARNESS_CURL_ROOT="$HOME/.cache/tillandsias-project/harness-curl"

opencode_curl_last_good_path() {
    printf '%s/opencode/last-good/opencode\n' "$HARNESS_CURL_ROOT"
}

opencode_record_curl_last_good() {
    local bin_path="$1" last_good tmp
    harness_probe opencode "$bin_path" || return 1
    last_good="$(opencode_curl_last_good_path)"
    mkdir -p "$(dirname "$last_good")" || return 1
    tmp="${last_good}.tmp.$$"
    if install -m 0755 "$bin_path" "$tmp" 2>/dev/null \
        && mv -f -- "$tmp" "$last_good" 2>/dev/null; then
        return 0
    fi
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
}

opencode_restore_curl_last_good() {
    local target="$1" last_good
    last_good="$(opencode_curl_last_good_path)"
    [ -x "$last_good" ] || return 1
    install -m 0755 "$last_good" "$target" 2>/dev/null || return 1
    harness_probe opencode "$target"
}

opencode_validate_or_rollback() {
    local bin="$1"
    OPENCODE_ROLLBACK_USED=0
    if [ -x "$bin" ] && harness_probe opencode "$bin"; then
        opencode_record_curl_last_good "$bin" >/dev/null 2>&1 || true
        return 0
    fi
    trace_lifecycle "harness" "opencode refresh FAILED auth contract — rolling back to last-good"
    if opencode_restore_curl_last_good "$bin"; then
        OPENCODE_ROLLBACK_USED=1
        trace_lifecycle "harness" "opencode rollback to last-good OK"
        return 0
    fi
    return 1
}

curl_install_opencode() {
    OC_BIN=""
    local dir="$HARNESS_CURL_ROOT/opencode/bin" tmp errlog bin
    local refresh_ok=0
    mkdir -p "$dir" 2>/dev/null || true
    bin="$dir/opencode"
    # Snapshot only a binary that passes liveness, flag, and the isolated
    # OPENCODE_AUTH_CONTENT/no-auth.json contract. This survives an official
    # installer replacing the cached binary with a release that starts but
    # silently dropped the undocumented credential primitive.
    if [ -x "$bin" ]; then
        opencode_record_curl_last_good "$bin" >/dev/null 2>&1 || true
    fi
    tmp="$(mktemp /tmp/opencode-install.XXXXXX 2>/dev/null || echo /tmp/opencode-install.sh)"
    errlog="$(mktemp /tmp/opencode-install-log.XXXXXX 2>/dev/null || echo /tmp/opencode-install.err)"
    # OPENCODE_INSTALL_DIR is the installer's documented target override; the
    # binary downloads from GitHub releases (opencode.ai + github.com are
    # both in the egress allowlist).
    if env -u OPENCODE_AUTH_CONTENT \
        curl -fsSL --max-time 60 https://opencode.ai/install -o "$tmp" 2>"$errlog" \
       && env -u OPENCODE_AUTH_CONTENT OPENCODE_INSTALL_DIR="$dir" \
        bash "$tmp" >>"$errlog" 2>&1 \
       && [ -x "$bin" ]; then
        refresh_ok=1
    fi

    if opencode_validate_or_rollback "$bin"; then
        if [ "${OPENCODE_ROLLBACK_USED:-0}" -eq 1 ]; then
            trace_lifecycle "harness" "opencode refresh rejected — reusing last-good ($("$bin" --version 2>/dev/null || echo '?'))"
            rm -f "$tmp" "$errlog" 2>/dev/null || true
        elif [ "$refresh_ok" -eq 1 ]; then
            trace_lifecycle "harness" "opencode curl-install OK ($("$bin" --version 2>/dev/null || echo '?'))"
            rm -f "$tmp" "$errlog" 2>/dev/null || true
        else
            trace_lifecycle "harness" "opencode curl-install unreachable — reusing cached ($("$bin" --version 2>/dev/null || echo '?'))"
            rm -f "$tmp" 2>/dev/null || true
        fi
        OC_BIN="$bin"
        return 0
    fi

    if [ ! -x "$bin" ]; then
        trace_lifecycle "harness" "opencode curl-install FAILED, no cached binary: $(tail -3 "$errlog" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
    else
        trace_lifecycle "harness" "opencode auth contract FAILED and no usable last-good binary remains"
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

claude_probe() {
    # Claude's native launcher checks for and may install updates even for a
    # `--version` health probe. Anthropic documents DISABLE_AUTOUPDATER=1;
    # newer releases additionally support DISABLE_UPDATES=1 as the strict
    # all-update-path guard. Scope both to probes only. The real foreground
    # Claude process inherits neither variable, so its official launch-time
    # updater remains enabled.
    local bin="$1"
    [ -x "$bin" ] \
        && timeout 30 env DISABLE_AUTOUPDATER=1 DISABLE_UPDATES=1 \
            "$bin" --version >/dev/null 2>&1
}

claude_version() {
    local bin="$1" version
    version="$(timeout 30 env DISABLE_AUTOUPDATER=1 DISABLE_UPDATES=1 \
        "$bin" --version 2>/dev/null | head -1)" || version="?"
    printf '%s\n' "${version:-?}"
}

claude_last_good_path() {
    printf '%s/claude/bin/claude\n' "$HARNESS_CURL_ROOT"
}

claude_last_good_version_file() {
    printf '%s/claude/last-good.version\n' "$HARNESS_CURL_ROOT"
}

claude_refresh_record_file() {
    printf '%s/claude/refreshed.version-epoch\n' "$HARNESS_CURL_ROOT"
}

claude_record_refresh_current() {
    local bin="$1" record version now tmp
    claude_probe "$bin" || return 1
    record="$(claude_refresh_record_file)"
    version="$(claude_version "$bin" | awk '{print $1}')"
    now="$(date +%s)"
    [ -n "$version" ] || return 1
    tmp="${record}.tmp.$$"
    printf '%s %s\n' "$version" "$now" >"$tmp" 2>/dev/null \
        && mv -f -- "$tmp" "$record" 2>/dev/null
}

claude_refresh_is_current() {
    # "Current" is deliberately bounded: only a locally validated version
    # that completed the official installer recently may skip install.sh.
    # A foreground Claude launch keeps its own updater enabled; if that changes
    # the version, the version mismatch forces a new official refresh here.
    local bin="$1" record recorded_version recorded_at version now age
    local max_age="${TILLANDSIAS_CLAUDE_REFRESH_MAX_AGE_SECONDS:-600}"
    record="$(claude_refresh_record_file)"
    [ -r "$record" ] && claude_probe "$bin" || return 1
    read -r recorded_version recorded_at <"$record" || return 1
    version="$(claude_version "$bin" | awk '{print $1}')"
    now="$(date +%s)"
    case "$recorded_at:$max_age" in
        *[!0-9:]* | :* | *:) return 1 ;;
    esac
    age=$((now - recorded_at))
    [ "$age" -ge 0 ] && [ "$age" -le "$max_age" ] \
        && [ "$version" = "$recorded_version" ]
}

claude_session_refresh_stamp() {
    # Background ensure + foreground require run in the same container and
    # therefore share /tmp and `$$` (Bash keeps $$ stable in subshells).
    # Sibling forge containers have isolated /tmp, while the persistent lock
    # below coalesces their simultaneous refreshes.
    printf '%s\n' "${TILLANDSIAS_CLAUDE_REFRESH_STAMP:-/tmp/tillandsias-claude-refresh.$$.done}"
}

claude_restore_cached_launcher() {
    local share="$HARNESS_CURL_ROOT/claude/share"
    local launcher="$HOME/.local/bin/claude" version
    mkdir -p "$share" "$HOME/.local/bin" "$HOME/.local/share" 2>/dev/null || true

    # The share path itself is ephemeral in each forge container. Reattach it
    # to the persistent versions/ directory before asking the official
    # installer whether an update is needed; otherwise the installer sees a
    # fresh machine and downloads the complete ~273 MB distribution again.
    if [ -e "$HOME/.local/share/claude" ] && [ ! -L "$HOME/.local/share/claude" ]; then
        rm -rf "$HOME/.local/share/claude" 2>/dev/null || true
    fi
    ln -sfn "$share" "$HOME/.local/share/claude" 2>/dev/null || true

    [ -x "$launcher" ] && return 0
    # No GNU-only -printf: strip the dirname with awk so BSD find (macOS test
    # hosts) produces the same basename list as GNU find in the Linux image.
    version="$(find "$share/versions" -mindepth 1 -maxdepth 1 -type f \
        -perm -u+x 2>/dev/null | awk -F/ '{print $NF}' \
        | LC_ALL=C sort -V | tail -1)"
    [ -n "$version" ] || return 1
    ln -sfn "$HOME/.local/share/claude/versions/$version" "$launcher" 2>/dev/null
    [ -x "$launcher" ]
}

claude_record_curl_last_good() {
    local bin="$1" last_good version_file version recorded resolved tmp
    claude_probe "$bin" || return 1
    last_good="$(claude_last_good_path)"
    version_file="$(claude_last_good_version_file)"
    version="$(claude_version "$bin" | awk '{print $1}')"
    recorded="$(cat "$version_file" 2>/dev/null || true)"
    if [ -x "$last_good" ] && [ -n "$version" ] && [ "$version" = "$recorded" ]; then
        return 0
    fi

    mkdir -p "$(dirname "$last_good")" || return 1
    resolved="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
    tmp="${last_good}.tmp.$$"
    if install -m 0755 "$resolved" "$tmp" 2>/dev/null \
        && mv -f -- "$tmp" "$last_good" 2>/dev/null; then
        printf '%s\n' "$version" >"$version_file" 2>/dev/null || true
        return 0
    fi
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
}

claude_validate_or_rollback() {
    local candidate="$1" last_good
    CLAUDE_ROLLBACK_USED=0
    if claude_probe "$candidate"; then
        claude_record_curl_last_good "$candidate" >/dev/null 2>&1 || true
        CC_BIN="$candidate"
        return 0
    fi

    last_good="$(claude_last_good_path)"
    if claude_probe "$last_good"; then
        CLAUDE_ROLLBACK_USED=1
        CC_BIN="$last_good"
        trace_lifecycle "harness" "claude refresh FAILED health probe — reusing last-good"
        return 0
    fi
    return 1
}

claude_run_locked_refresh() (
    # Subshell ownership lets the lock cleanup trap cover every return and
    # HUP/INT/TERM path without overwriting the entrypoint's own traps.
    local refresh_lock="$1" result_file="$2" session_stamp="$3"
    # BASHPID needs bash >= 4 (always true in the Linux image); the $PPID
    # fallback keeps the extracted-function test harness alive on bash 3.2.
    local owner_file="$refresh_lock/owner.pid" lock_owner="${BASHPID:-$(sh -c 'echo "$PPID"')}"
    local launcher="$HOME/.local/bin/claude"
    local tmp="" errlog="" refresh_ok=0
    local installer_pid=""
    local install_timeout="${TILLANDSIAS_CLAUDE_INSTALL_TIMEOUT_SECONDS:-600}"
    case "$install_timeout" in
        *[!0-9]* | 0 | "") install_timeout=600 ;;
    esac
    mkdir "$refresh_lock" 2>/dev/null || return 75
    printf '%s\n' "$lock_owner" >"$owner_file" 2>/dev/null || true

    # shellcheck disable=SC2329 # invoked indirectly by trap
    _claude_refresh_cleanup() {
        if [ -n "$installer_pid" ]; then
            kill "$installer_pid" 2>/dev/null || true
            wait "$installer_pid" 2>/dev/null || true
        fi
        [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null || true
        [ -n "$errlog" ] && rm -f "$errlog" 2>/dev/null || true
        if [ "$(cat "$owner_file" 2>/dev/null || true)" = "$lock_owner" ]; then
            rm -f "$owner_file" 2>/dev/null || true
            rmdir "$refresh_lock" 2>/dev/null || true
        fi
    }
    trap _claude_refresh_cleanup EXIT
    trap 'exit 130' HUP INT TERM

    # Preserve the current validated binary before the installer is allowed to
    # replace its launcher or versions directory.
    if claude_probe "$launcher"; then
        claude_record_curl_last_good "$launcher" >/dev/null 2>&1 || true
    fi

    tmp="$(mktemp /tmp/claude-install.XXXXXX 2>/dev/null || echo /tmp/claude-install.sh)"
    errlog="$(mktemp /tmp/claude-install-log.XXXXXX 2>/dev/null || echo /tmp/claude-install.err)"
    if curl -fsSL --max-time 60 https://claude.ai/install.sh -o "$tmp" 2>"$errlog"; then
        timeout --kill-after=15 "$install_timeout" bash "$tmp" >>"$errlog" 2>&1 &
        installer_pid=$!
        if wait "$installer_pid"; then
            installer_pid=""
            [ -x "$launcher" ] && refresh_ok=1
        else
            installer_pid=""
        fi
    fi

    if claude_validate_or_rollback "$launcher"; then
        : >"$session_stamp"
        printf '%s\n' "$CC_BIN" >"$result_file"
        if [ "${CLAUDE_ROLLBACK_USED:-0}" -eq 1 ]; then
            trace_lifecycle "harness" "claude refresh rejected — reusing last-good ($(claude_version "$CC_BIN"))"
        elif [ "$refresh_ok" -eq 1 ]; then
            claude_record_refresh_current "$CC_BIN" >/dev/null 2>&1 || true
            trace_lifecycle "harness" "claude curl-install OK ($(claude_version "$CC_BIN"))"
        else
            trace_lifecycle "harness" "claude curl-install unreachable — reusing cached ($(claude_version "$CC_BIN"))"
        fi
        return 0
    fi

    trace_lifecycle "harness" "claude curl-install FAILED, no cached binary: $(tail -3 "$errlog" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
    return 1
)

curl_install_claude() {
    CC_BIN=""
    local root="$HARNESS_CURL_ROOT/claude" launcher="$HOME/.local/bin/claude"
    local refresh_lock="$root/refresh.lock" session_stamp result_file
    local refresh_status waited=0 stale_reclaimed=0
    local wait_limit="${TILLANDSIAS_CLAUDE_REFRESH_WAIT_SECONDS:-900}"
    case "$wait_limit" in
        *[!0-9]* | 0 | "") wait_limit=900 ;;
    esac
    session_stamp="$(claude_session_refresh_stamp)"
    result_file="$(mktemp /tmp/claude-refresh-result.XXXXXX 2>/dev/null \
        || echo "/tmp/claude-refresh-result.$$")"
    rm -f "$result_file" 2>/dev/null || true
    mkdir -p "$root" "$root/bin" 2>/dev/null || true
    claude_restore_cached_launcher >/dev/null 2>&1 || true

    # A different container may already have completed and validated the same
    # official version moments ago. The bounded version+epoch record makes this
    # warm/current path zero-network across launches, not merely coalesced
    # within one process.
    if claude_refresh_is_current "$launcher" \
        && claude_validate_or_rollback "$launcher"; then
        : >"$session_stamp"
        rm -f "$result_file" 2>/dev/null || true
        trace_lifecycle "harness" "claude refresh current — reusing persistent version ($(claude_version "$CC_BIN"))"
        return 0
    fi

    # The selected entrypoint calls require_claude in the foreground while
    # ensure_forge_harnesses is already refreshing in the background. A
    # successful refresh in this container satisfies both calls.
    if [ -f "$session_stamp" ] && claude_validate_or_rollback "$launcher"; then
        rm -f "$result_file" 2>/dev/null || true
        return 0
    fi

    # Serialize the official installer across both calls and across sibling
    # forge containers sharing the project tool cache.
    if claude_run_locked_refresh "$refresh_lock" "$result_file" "$session_stamp"; then
        IFS= read -r CC_BIN <"$result_file"
        rm -f "$result_file" 2>/dev/null || true
        return 0
    else
        refresh_status=$?
    fi

    if [ "$refresh_status" -ne 75 ]; then
        rm -f "$result_file" 2>/dev/null || true
        return "$refresh_status"
    fi

    if [ -d "$refresh_lock" ] \
        && [ -n "$(find "$refresh_lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
        rm -f "$refresh_lock/owner.pid" 2>/dev/null || true
        if rmdir "$refresh_lock" 2>/dev/null; then
            stale_reclaimed=1
        fi
    fi

    # A warm foreground launch must not wait behind the background refresh,
    # but the live launcher is mutable while that owner runs. Select only the
    # independent last-good snapshot here; never hand the foreground a symlink
    # the owner may replace between this probe and exec. Only a true cold cache
    # with no validated snapshot waits for the bounded owner result.
    if [ "$stale_reclaimed" -eq 0 ]; then
        local active_last_good
        active_last_good="$(claude_last_good_path)"
        if claude_probe "$active_last_good"; then
            CC_BIN="$active_last_good"
            rm -f "$result_file" 2>/dev/null || true
            return 0
        fi
    fi

    while [ -d "$refresh_lock" ] && [ "$waited" -lt "$wait_limit" ]; do
        sleep 1
        waited=$((waited + 1))
    done

    # A sibling completed while we waited. Reattach its persistent version
    # and use it without invoking the installer a second time.
    if [ "$stale_reclaimed" -eq 0 ]; then
        claude_restore_cached_launcher >/dev/null 2>&1 || true
        if claude_validate_or_rollback "$launcher"; then
            : >"$session_stamp"
            rm -f "$result_file" 2>/dev/null || true
            return 0
        fi
    fi

    # The owner failed without leaving a usable candidate. Make one bounded
    # retry as the new owner; the helper still guarantees lock cleanup.
    if claude_run_locked_refresh "$refresh_lock" "$result_file" "$session_stamp"; then
        IFS= read -r CC_BIN <"$result_file"
        rm -f "$result_file" 2>/dev/null || true
        return 0
    else
        refresh_status=$?
    fi
    rm -f "$result_file" 2>/dev/null || true
    return "$refresh_status"
}

require_opencode() {
    # Curl channel first (order 459); legacy npm as the transition fallback
    # so a half-warm cache from the old channel still launches.
    if curl_install_opencode && [ -n "${OC_BIN:-}" ] && [ -x "$OC_BIN" ]; then
        return 0
    fi
    OC_BIN="$(_require_harness opencode opencode-ai opencode)"
    return 0
}

require_claude() {
    if curl_install_claude && [ -n "${CC_BIN:-}" ] && [ -x "$CC_BIN" ]; then
        return 0
    fi
    CC_BIN="$(_require_harness claude-code "@anthropic-ai/claude-code" claude)"
    return 0
}

require_openspec() {
    OS_BIN="$(_require_harness openspec "@fission-ai/openspec" openspec)"
    return 0
}

require_codex() {
    CX_BIN="$(_require_harness codex "@openai/codex" codex)"
    return 0
}

# require_antigravity: install the Antigravity CLI (agy) if absent. Unlike the
# npm harnesses, agy ships via the official installer script — download WITH A
# TIMEOUT then run it (never `curl | bash`), retrying 3x with backoff
# (order 307: one-shot curl was fragile against transient proxy/network
# issues). Shared by the forge entrypoint AND the ephemeral login container
# (`tillandsias --agy-login` failed exit-2 when the login container assumed
# agy was pre-installed — operator repro 2026-07-15).
require_antigravity() {
    command -v agy >/dev/null 2>&1 && return 0

    local _agy_installer _agy_url="https://antigravity.google/cli/install.sh"
    local _attempt _max_attempts=3 _delay=2

    for _attempt in 1 2 3; do
        trace_lifecycle "tools" "agy install attempt $_attempt/$_max_attempts"
        _agy_installer="$(mktemp 2>/dev/null)"
        if [ -n "$_agy_installer" ] && curl -fsSL --max-time 90 "$_agy_url" -o "$_agy_installer" 2>/dev/null; then
            if ANTIGRAVITY_BIN="/usr/local/bin/agy" bash "$_agy_installer" 2>/dev/null; then
                rm -f "$_agy_installer" 2>/dev/null || true
                command -v agy >/dev/null 2>&1 && return 0
            fi
        fi
        rm -f "$_agy_installer" 2>/dev/null || true
        trace_lifecycle "tools" "agy install attempt $_attempt failed (retry in ${_delay}s)"
        sleep "$_delay" 2>/dev/null || true
        _delay=$(( _delay * 2 ))
    done
    return 1
}

# ── On-demand userspace tools (Homebrew, attested formulae only) ──
# @trace spec:default-image
# Plan order 294 (operator-approved 2026-07-11): every command in
# /usr/local/lib/tillandsias/brew-tools-allowlist.txt that is not already
# on PATH gets a shim in a LAST-on-PATH dir. Running the command installs
# it on first use through tillandsias-brew-shim-exec (homebrew-core
# formulae only, Sigstore attestation verification REQUIRED), then execs
# it transparently — distro-style "command-not-found" UX, but it actually
# installs. TILLANDSIAS_BREW_SHIMS=0 disables shim generation;
# TILLANDSIAS_BREW_AUTOINSTALL=0 makes shims print the
# `brew install <formula>` hint instead of installing.
install_brew_shims() {
    local allowlist="/usr/local/lib/tillandsias/brew-tools-allowlist.txt"
    local shim_dir="$HOME/.local/share/tillandsias/brew-shims"
    [ -f "$allowlist" ] || return 0
    [ -x /usr/local/bin/tillandsias-brew-shim-exec ] || return 0
    mkdir -p "$shim_dir" 2>/dev/null || return 0
    local cmd formula
    while read -r cmd formula _; do
        case "$cmd" in \#*|"") continue ;; esac
        [ -n "$formula" ] || continue
        # Real tool already present (image-baked or previously installed):
        # no shim. The shim dir is last on PATH anyway, so this is belt
        # and suspenders against confusing `command -v` output.
        command -v "$cmd" >/dev/null 2>&1 && continue
        [ -e "$shim_dir/$cmd" ] && continue
        printf '#!/bin/bash\nexec /usr/local/bin/tillandsias-brew-shim-exec %q %q "$@"\n' \
            "$cmd" "$formula" > "$shim_dir/$cmd" 2>/dev/null || continue
        chmod +x "$shim_dir/$cmd" 2>/dev/null || true
    done < "$allowlist"
    export PATH="$PATH:$shim_dir"
    trace_lifecycle "tools" "on-demand brew shims ready ($shim_dir)"
}

if [ "${TILLANDSIAS_BREW_SHIMS:-1}" != "0" ]; then
    install_brew_shims || true
fi

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

# ── Claude config overlay ───────────────────────────────────
# @trace spec:forge-environment-discoverability, order:568
# Claude stores credentials, project state, and MCP registration in one file.
# Merge only the forge MCP servers so restoring OAuth state remains lossless.
apply_claude_config_overlay() {
    local overlay_root="${TILLANDSIAS_CONFIG_OVERLAY_ROOT:-/home/forge/.config-overlay}"
    local overlay_cfg="$overlay_root/claude/mcp.json"
    local user_cfg="${CLAUDE_CONFIG_FILE:-$HOME/.claude.json}"
    local tmp

    [ -f "$overlay_cfg" ] || return 0
    if ! jq -e 'type == "object" and (.mcpServers | type == "object")' \
        "$overlay_cfg" >/dev/null 2>&1; then
        trace_lifecycle "config" "claude MCP overlay invalid; existing config preserved"
        return 1
    fi

    mkdir -p "$(dirname "$user_cfg")"
    tmp="$(mktemp "${user_cfg}.tmp.XXXXXX")" || return 1
    if [ -s "$user_cfg" ]; then
        if ! jq -e 'type == "object"' "$user_cfg" >/dev/null 2>&1 \
            || ! jq -s '.[0] * {mcpServers: ((.[0].mcpServers // {}) * .[1].mcpServers)}' \
                "$user_cfg" "$overlay_cfg" >"$tmp"; then
            rm -f "$tmp"
            trace_lifecycle "config" "claude config invalid; existing file preserved"
            return 1
        fi
    else
        cp "$overlay_cfg" "$tmp" || {
            rm -f "$tmp"
            return 1
        }
    fi

    chmod 600 "$tmp"
    mv -f "$tmp" "$user_cfg"
    trace_lifecycle "config" "claude MCP overlay applied"
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

# ── Project environment discovery ──────────────────────────────────
# @trace spec:forge-environment-discoverability
# Export environment variables that allow agents and scripts to discover
# project context and configuration without external dependencies.
# Called once at startup; sets TILLANDSIAS_PROJECT_PATH,
# TILLANDSIAS_PROJECT_GENUS, and other project metadata.
export_project_env() {
    # PROJECT_DIR must be set by find_project_dir() before calling this.
    # If not set, use the first directory under ~/src/ or empty.
    local project_path="${PROJECT_DIR:-}"
    if [ -z "$project_path" ]; then
        for _d in "$HOME/src"/*/; do
            [ -d "$_d" ] && project_path="${_d%/}" && break
        done
    fi

    # Export absolute project path
    if [ -n "$project_path" ] && [ -d "$project_path" ]; then
        export TILLANDSIAS_PROJECT_PATH="$project_path"
        trace_lifecycle "project-env" "TILLANDSIAS_PROJECT_PATH=$TILLANDSIAS_PROJECT_PATH"
    else
        export TILLANDSIAS_PROJECT_PATH=""
        trace_lifecycle "project-env" "TILLANDSIAS_PROJECT_PATH=<empty>"
        return 0  # No project; non-fatal for headless runs
    fi

    # Extract project genus (tillandsia name) from config or generate from name
    local project_genus="${TILLANDSIAS_PROJECT_GENUS:-}"
    if [ -z "$project_genus" ] && [ -f "$project_path/.tillandsias/config.toml" ]; then
        # Try to read genus from project config
        project_genus=$(grep -E '^\s*genus\s*=' "$project_path/.tillandsias/config.toml" 2>/dev/null | \
            sed 's/.*=\s*"\([^"]*\)".*/\1/' || echo "")
    fi
    if [ -z "$project_genus" ]; then
        # Fallback to TILLANDSIAS_PROJECT env var if available
        project_genus="${TILLANDSIAS_PROJECT:-}"
    fi
    if [ -n "$project_genus" ]; then
        export TILLANDSIAS_PROJECT_GENUS="$project_genus"
        trace_lifecycle "project-env" "TILLANDSIAS_PROJECT_GENUS=$TILLANDSIAS_PROJECT_GENUS"
    fi
}

# ── Multi-workspace discovery ───────────────────────────────
# @trace gap:ON-006
# Discovers sibling projects in the parent directory and exports
# TILLANDSIAS_SIBLING_PROJECTS as a colon-separated list of project names.
# Also exports TILLANDSIAS_WORKSPACE_COUNT for easy checking.
export_workspace_env() {
    # PROJECT_DIR must be set by find_project_dir() or export_project_env()
    local project_path="${TILLANDSIAS_PROJECT_PATH:-${PROJECT_DIR:-}}"

    if [ -z "$project_path" ] || [ ! -d "$project_path" ]; then
        export TILLANDSIAS_SIBLING_PROJECTS=""
        export TILLANDSIAS_WORKSPACE_COUNT=0
        return 0
    fi

    local parent_dir
    parent_dir=$(dirname "$project_path")

    local sibling_names=""
    local count=0

    # Scan parent directory for git projects
    if [ -d "$parent_dir" ]; then
        for project_dir in "$parent_dir"/*; do
            # Skip if not a directory or doesn't have .git
            if [ ! -d "$project_dir" ] || [ ! -d "$project_dir/.git" ]; then
                continue
            fi

            # Skip the current project itself
            if [ "$(realpath "$project_dir")" = "$(realpath "$project_path")" ]; then
                continue
            fi

            local project_name
            project_name=$(basename "$project_dir")

            # Add to colon-separated list
            if [ -z "$sibling_names" ]; then
                sibling_names="$project_name"
            else
                sibling_names="$sibling_names:$project_name"
            fi

            count=$((count + 1))
        done
    fi

    export TILLANDSIAS_SIBLING_PROJECTS="$sibling_names"
    export TILLANDSIAS_WORKSPACE_COUNT=$count

    if [ $count -gt 0 ]; then
        trace_lifecycle "workspace-env" "TILLANDSIAS_WORKSPACE_COUNT=$count TILLANDSIAS_SIBLING_PROJECTS=$TILLANDSIAS_SIBLING_PROJECTS"
    fi
}

# ── Quick-switch to sibling project ────────────────────────
# @trace gap:ON-006
# Shell function to quickly cd to a sibling project directory.
# Usage: switch-project <project-name>
switch_project() {
    local target_project="${1:-}"

    if [ -z "$target_project" ]; then
        echo "Usage: switch-project <project-name>"
        if [ "$TILLANDSIAS_WORKSPACE_COUNT" -gt 0 ]; then
            echo ""
            echo "Available projects:"
            IFS=':' read -ra projects <<< "$TILLANDSIAS_SIBLING_PROJECTS"
            for proj in "${projects[@]}"; do
                echo "  • $proj"
            done
        else
            echo "No sibling projects found."
        fi
        return 1
    fi

    # Get the parent directory from current project path
    local parent_dir
    parent_dir=$(dirname "${TILLANDSIAS_PROJECT_PATH:-$(pwd)}")

    # Check if the target project exists
    local target_path="$parent_dir/$target_project"
    if [ ! -d "$target_path" ] || [ ! -d "$target_path/.git" ]; then
        echo "ERROR: Project '$target_project' not found in $parent_dir"
        return 1
    fi

    # Change to the target project directory
    cd "$target_path" || return 1
    echo "Switched to: $target_project"

    # Update environment variables for the new project
    PROJECT_DIR="$target_path"
    export_project_env
    export_workspace_env

    return 0
}

# Alias for convenience
list_projects() {
    echo "Available projects in $(dirname "${TILLANDSIAS_PROJECT_PATH:-$(pwd)}"):"
    if [ "$TILLANDSIAS_WORKSPACE_COUNT" -gt 0 ]; then
        IFS=':' read -ra projects <<< "$TILLANDSIAS_SIBLING_PROJECTS"
        for proj in "${projects[@]}"; do
            echo "  • $proj"
        done
    else
        echo "  (none)"
    fi
}

# ── SSH key auto-discovery ─────────────────────────────
# @trace gap:ON-007
# Auto-discover SSH keys from the host's ~/.ssh/ directory and make them
# available inside the forge without requiring manual bind-mount configuration.
# Supports three modes:
#   1. SSH agent socket (SSH_AUTH_SOCK) — preferred if agent is running
#   2. Traditional SSH key files — fallback if agent not available
#   3. Both — auto-detect and use whichever is available
#
# The forge container is mounted RO to prevent accidental key modification.
# Returns 0 on success, 1 if no SSH keys detected (non-fatal).
export_ssh_env() {
    local ssh_host_dir="${HOME}/.ssh"

    # No SSH directory on host — nothing to do.
    [ -d "$ssh_host_dir" ] || return 1

    # Check for SSH agent socket (most secure, preferred).
    # Priority: SSH_AUTH_SOCK > /run/user/1000/ssh-agent (common on systemd)
    local ssh_agent_socket=""
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
        ssh_agent_socket="$SSH_AUTH_SOCK"
    elif [ -S "/run/user/$(id -u)"/ssh-agent.sock ]; then
        ssh_agent_socket="/run/user/$(id -u)"/ssh-agent.sock
    elif [ -S "/run/user/1000/ssh-agent.sock" ]; then
        ssh_agent_socket="/run/user/1000/ssh-agent.sock"
    fi

    # If agent socket is available, prefer it (no keys on disk needed).
    if [ -n "$ssh_agent_socket" ] && [ -S "$ssh_agent_socket" ]; then
        export SSH_AUTH_SOCK="$ssh_agent_socket"
        trace_lifecycle "ssh" "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
        return 0
    fi

    # Fallback: SSH key files. Check if ~/.ssh/ contains readable keys.
    # Look for common key file patterns (id_rsa, id_ed25519, id_ecdsa, etc).
    # The container will have RO access to these files.
    if [ -f "$ssh_host_dir/id_rsa" ] || \
       [ -f "$ssh_host_dir/id_ed25519" ] || \
       [ -f "$ssh_host_dir/id_ecdsa" ] || \
       [ -f "$ssh_host_dir/id_dsa" ] || \
       [ -f "$ssh_host_dir/id_ecdsa_sk" ] || \
       [ -f "$ssh_host_dir/id_ed25519_sk" ]; then
        # At least one key file exists. Export SSH_KEY_PATH so scripts can discover
        # the location, and ensure ~/.ssh is in place inside the forge (even though
        # it's bind-mounted RO by the orchestrator).
        export SSH_KEY_PATH="$ssh_host_dir"
        trace_lifecycle "ssh" "SSH_KEY_PATH=$SSH_KEY_PATH (key files detected)"
        return 0
    fi

    # No keys or agent found.
    trace_lifecycle "ssh" "no SSH keys or agent detected"
    return 1
}

# ── Forge startup context injection ─────────────────────────
# @trace spec:project-bootstrap-readme, spec:forge-environment-discoverability
# Writes .forge-startup-context.md into the project workspace so agents know
# which project is loaded, what infrastructure is transparent, where the plan
# lives, and what the current branch/version are. Written fresh every launch
# (ephemeral) — the file is gitignored and not committed.
inject_startup_context() {
    local project_dir="${1:-$PROJECT_DIR}"
    [[ -n "$project_dir" ]] || return 0
    [[ -d "$project_dir" ]] || return 0

    local ctx_file="$project_dir/.forge-startup-context.md"
    # Order 392: truthful inference readiness — probe the endpoint once
    # (1s budget) instead of the old indeterminate "may still be starting".
    # The forge-launch path already blocks until /api/version answers, so this
    # probe is the authoritative live check; it reports READY or a concrete
    # not-ready reason, never an ambiguous "may be starting".
    #
    # Order 392a EXTENSION (model-warm state): an endpoint that answers with
    # ZERO models is not useful to an agent, so READY now additionally requires
    # >=1 cached model and carries the warm inventory. The READY / NOT-READY
    # tokens are unchanged — only the parenthesised detail is new.
    #
    # The probe itself lives in lib-inference-state.sh so it stays testable
    # OUTSIDE the forge image (this file hard-fails at source time on the vendor
    # CA bundle, so a probe inlined here could only ever be grep-pinned). See
    # that file for the pinned grammar and the closed reason vocabulary; litmus:
    # inference-model-preload-policy exercises every branch with a stubbed curl.
    local _inference_status _inference_state _inference_reason _inference_warm _inference_count
    local _inference_state_lib="${BASH_SOURCE[0]%/*}/lib-inference-state.sh"
    if [[ -r "$_inference_state_lib" ]]; then
        # shellcheck source=lib-inference-state.sh
        source "$_inference_state_lib"
        tillandsias_inference_state "http://inference:11434"
        _inference_status="$TILLANDSIAS_INFERENCE_STATUS"
        _inference_state="$TILLANDSIAS_INFERENCE_STATE"
        _inference_reason="$TILLANDSIAS_INFERENCE_REASON"
        _inference_warm="$TILLANDSIAS_INFERENCE_WARM"
        _inference_count="$TILLANDSIAS_INFERENCE_MODELS"
    else
        _inference_state="not-ready"
        _inference_reason="probe-helper-missing"
        _inference_warm="-"
        _inference_count=0
        _inference_status="NOT-READY (probe-helper-missing: ${_inference_state_lib} not present in this image)"
    fi
    # Order 456 / 394 rung 1 EXTENSION (experts launch state): a PEER line to
    # the inference state above, under the same discipline — a closed token
    # vocabulary and never an ambiguous "may still be building". The experts
    # state is read from tmpfs, written by ensure_forge_experts.
    #
    # PINNED GRAMMAR (litmus:forge-plan-expert-build-shape):
    #   experts: ready
    #   experts: building(<n>s)
    #   experts: degraded(<reason>)
    # reason vocabulary (closed set):
    #   no-checkout | no-plan-crate | no-cargo | build-failed
    #   | build-timeout | binary-missing | install-failed | not-built
    # Plus one machine-readable token line agents branch on:
    #   experts_state=<ready|building|degraded> experts_reason=<name|->
    #   experts_elapsed=<n|->
    local _experts_status _experts_state _experts_reason _experts_elapsed
    _experts_status="$(forge_experts_state_line)"
    case "$_experts_status" in
        ready)
            _experts_state="ready"
            _experts_reason="-"
            _experts_elapsed="-"
            ;;
        building*)
            _experts_state="building"
            _experts_reason="-"
            _experts_elapsed="${_experts_status#building(}"
            _experts_elapsed="${_experts_elapsed%s)}"
            ;;
        *)
            _experts_state="degraded"
            _experts_reason="${_experts_status#degraded(}"
            _experts_reason="${_experts_reason%)}"
            _experts_elapsed="-"
            ;;
    esac

    local _project_experts_status _project_experts_state _project_experts_reason _project_experts_elapsed
    _project_experts_status="$(generic_project_state_line)"
    case "$_project_experts_status" in
        ready)
            _project_experts_state="ready"
            _project_experts_reason="-"
            _project_experts_elapsed="-"
            ;;
        building*)
            _project_experts_state="building"
            _project_experts_reason="-"
            _project_experts_elapsed="${_project_experts_status#building(}"
            _project_experts_elapsed="${_project_experts_elapsed%s)}"
            ;;
        *)
            _project_experts_state="degraded"
            _project_experts_reason="${_project_experts_status#degraded(}"
            _project_experts_reason="${_project_experts_reason%)}"
            _project_experts_elapsed="-"
            ;;
    esac

    # Order 569 EXTENSION (capability skew). `experts_state=ready` above answers
    # "did the build finish". It has never answered the question an agent
    # actually has, which is three questions:
    #
    #   what can I use NOW · what would a RELAUNCH give me · am I BLOCKED
    #
    # Order 531 is why: a forge seeded from a pre-expert base built that base,
    # installed it, and stamped `ready` truthfully — while every plan_answer
    # returned confidence=unsupported. And the inverse matters just as much:
    # local edits to the expert crate are INVISIBLE to the running binary but
    # WILL be present on the next forge run, so an agent that cannot see the
    # difference either abandons work that is one relaunch away or waits forever
    # for a capability that is never coming.
    #
    # The probe lives in lib-expert-capability.sh for the same reason the
    # inference probe lives in lib-inference-state.sh: this file hard-fails at
    # source time on the vendor CA bundle, so logic inlined here could only ever
    # be grep-pinned. litmus:expert-capability-skew-honesty runs that helper
    # directly against fixture binaries and exercises every branch.
    local _cap_line _cap_skew _cap_advice
    local _cap_lib="${BASH_SOURCE[0]%/*}/lib-expert-capability.sh"
    if [[ -r "$_cap_lib" ]]; then
        # shellcheck source=lib-expert-capability.sh
        source "$_cap_lib"
        tillandsias_expert_capability \
            "$FORGE_EXPERTS_BIN_DIR/tillandsias-plan" "$project_dir"
        _cap_line="$TILLANDSIAS_EXPERT_CAPABILITY_LINE"
        _cap_skew="$TILLANDSIAS_EXPERT_CAP_SKEW"
        _cap_advice="$(tillandsias_expert_capability_advice "$_cap_skew")"
    else
        # A missing helper is its own named fact, not a silent "no skew": an
        # absent probe reporting `skew=none` would be the same lie as `ready`.
        _cap_line="expert_capability: now=none after_relaunch=none skew=none blocked_capabilities=- lost_on_relaunch=- probe=helper-missing"
        _cap_advice="The capability probe (${_cap_lib}) is not present in this image, so the fields above are placeholders — treat expert capability as UNVERIFIED and check \`tillandsias-plan capabilities\` by hand."
    fi

    # Order 619-pfsj (C3): the same honesty for the GENERIC ANSWER ENGINE,
    # REDEFINED for its packaging. project-info.sh is image-baked (order 459 —
    # no network at image build, so the engine ships in the baked shell layer),
    # which means its sources are never the mounted checkout and NO relaunch
    # rebuilds it. `project-expert: ready` above describes the tmpfs INDEX;
    # this line describes the ENGINE — whether the baked artifact carries the
    # answer contract this checkout expects (order 531: an artifact can report
    # ready truthfully while every answer refuses). The probe compares the
    # engine's embedded manifest (`project-info.sh capabilities`, order 569
    # pattern) against the checkout's copy of the engine source — versions and
    # capabilities embedded in the artifacts, never a network probe.
    local _pe_line _pe_advice
    local _pe_lib="${BASH_SOURCE[0]%/*}/lib-project-engine-capability.sh"
    if [[ -r "$_pe_lib" ]]; then
        # shellcheck source=lib-project-engine-capability.sh
        source "$_pe_lib"
        tillandsias_project_engine_capability \
            "${TILLANDSIAS_PROJECT_ENGINE:-/home/forge/.config-overlay/mcp/project-info.sh}" \
            "$project_dir"
        _pe_line="$TILLANDSIAS_PROJECT_ENGINE_LINE"
        _pe_advice="$(tillandsias_project_engine_advice "$TILLANDSIAS_PROJECT_ENGINE_STATE")"
    else
        # A missing probe is its own named fact, not a silent "no skew".
        _pe_line="project_engine: state=unknown baked=- expected=- missing_in_engine=- engine_only=- probe=helper-missing"
        _pe_advice="The engine capability probe (${_pe_lib}) is not present in this image, so the fields above are placeholders — treat the answer engine's capability as UNVERIFIED and run \`project-info.sh capabilities\` by hand."
    fi

    # Order 480 follow-up (accelerator envelope): the host probes its own
    # hardware and passes the verdict in; the forge cannot see PCI devices, an
    # NVIDIA driver, or /dev/accel, so it may never attempt this itself.
    #
    # An ABSENT variable is not the same fact as "no accelerator", and conflating
    # them is how a GPU host silently reads as CPU-only. A launcher too old to
    # export the envelope, or a container started outside the launcher, is
    # reported as its own named state rather than being answered wrongly.
    local _accel_envelope
    if [[ -n "${TILLANDSIAS_ACCEL_ENVELOPE:-}" ]]; then
        _accel_envelope="$TILLANDSIAS_ACCEL_ENVELOPE"
    else
        _accel_envelope="accel_class=unknown accel_gpu=unknown accel_gpu_name=- accel_npu=unknown accel_npu_name=- accel_reason=envelope-not-exported accel_cpu_cores=- accel_ram_gb=-"
    fi

    local branch version agent_name
    branch="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"

    # Order 531: state a VERDICT on the base branch, not just its name.
    #
    # The branch name alone was already printed, and it was not enough: an agent
    # landing on `main` saw "Startup branch: main" and had no signal that this
    # was wrong. Two cycles absorbed exactly that by noticing and hand-rebasing
    # (plan/loop_status.md:203, :243), which is the guard-by-attentive-agent
    # pattern this project forbids.
    #
    # Why it happens: the launcher seeds the forge from the HOST CHECKOUT's
    # current branch (read_host_project_current_branch ->
    # TILLANDSIAS_FORGE_SEED_BRANCH), and the release skill used to park that
    # checkout on `main` and never return it. So every forge launched after a
    # release cycle was pinned to `main`.
    #
    # Why it MATTERS: `main` carries no crates/tillandsias-plan/src/answer.rs or
    # methodology.rs, so the expert build produces a PRE-EXPERT binary and then
    # truthfully reports `experts: ready` while every plan_answer /
    # methodology_path call returns confidence=unsupported. Truthful state, wrong
    # artifact — the hardest kind to notice.
    # SCOPE RULE (methodology/multi-host-development.yaml:21-27): the names
    # linux-next / windows-next / osx-next / main are TILLANDSIAS'S OWN
    # development conventions and are explicitly "NOT a runtime convention of the
    # product" — a forge launched on an end user's project MUST NOT assume them.
    # This code runs in EVERY forge, so it may not judge a branch by its NAME.
    # An earlier draft of this block flagged `main` as non-committable and told
    # the agent to switch to `linux-next`; that is correct only when the target
    # project happens to be Tillandsias, and wrong everywhere else.
    #
    # So the verdict rests on two things that are true of ANY project:
    #   - did the checkout land on the branch this launch was GATED on, and
    #   - can this base actually build the expert.
    local _base_state _base_detail _seed
    _seed="${TILLANDSIAS_FORGE_SEED_BRANCH:-}"
    if [[ "$branch" == "unknown" ]]; then
        _base_state="unknown"
        _base_detail="the checkout has no resolvable branch (detached HEAD, or not a git repo)"
    elif [[ -n "$_seed" && "$branch" != "$_seed" ]]; then
        _base_state="mismatch"
        _base_detail="this launch was gated on '${_seed}' but the checkout is on '${branch}' — work will land somewhere other than where the launch intended"
    else
        _base_state="ok"
        _base_detail="checkout is on the branch this launch was gated on"
    fi

    # The load-bearing signal, and the project-agnostic one: can this base build
    # the plan expert at all? This is a FACT about the checkout, not a judgement
    # about a branch name, so it is safe to assert on any project.
    #
    # It is what catches the order-531 case the `mismatch` test cannot: when the
    # host checkout was itself parked on a pre-expert branch, the seed and the
    # actual branch AGREE, so nothing looks wrong — while the expert build
    # produces a pre-expert binary and truthfully reports `experts: ready`.
    local _expert_sources
    if [[ ! -d "$project_dir/crates/tillandsias-plan" ]]; then
        _expert_sources="n/a"          # not a plan-expert project; nothing to expect
    elif [[ -f "$project_dir/crates/tillandsias-plan/src/answer.rs" ]]; then
        _expert_sources="present"
    else
        _expert_sources="absent"
    fi
    version="$(cat "$project_dir/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")"
    agent_name="${TILLANDSIAS_AGENT_NAME:-forge}"
    local project_name
    project_name="${TILLANDSIAS_PROJECT:-$(basename "$project_dir")}"

    cat > "$ctx_file" <<CONTEXT_EOF
# Forge Startup Context

**Project**: ${project_name}
**Startup branch**: ${branch} — \`base_state=${_base_state}\`
> Note: Branch is a startup snapshot; agents may switch branches during orchestration.
> Machine-readable (branch on this, do not parse the prose): \`base_state=${_base_state} base_actual=${branch} base_expected=${_seed:-<unset>} expert_sources=${_expert_sources}\`
> \`base_state\` is one of \`ok\` | \`mismatch\` | \`unknown\`. ${_base_detail}.
> \`expert_sources=absent\` means this checkout HAS a \`crates/tillandsias-plan\` but NOT \`src/answer.rs\`, so the expert build produces a PRE-EXPERT binary: \`experts: ready\` is then reported truthfully while every \`plan_answer\` / \`methodology_path\` call returns \`confidence=unsupported\`. That is order 531, and note \`base_state\` can read \`ok\` in this situation — the launch landed exactly where it was gated, on a base that cannot build the expert. Do NOT read \`unsupported\` as "the plan has no answer"; it means the ARTIFACT is wrong. Switch to a branch carrying the expert sources before trusting any expert answer, and report which branch you moved to. (\`n/a\` means this project has no plan-expert crate at all, which is normal off-Tillandsias.)
**Version**: ${version}
**Agent**: ${agent_name}
**Generated**: $(date -u +%Y-%m-%dT%H:%MZ)

## Infrastructure (all transparent — zero configuration needed)

- **Git**: push/fetch route through the enclave git mirror; GitHub token is handled automatically.
- **HTTPS proxy**: outbound traffic is cached; CA is trusted at startup.
- **Accelerators** — \`${_accel_envelope}\`
  - This is the HOST's hardware, projected onto a closed vocabulary so you can branch on it without probing devices you cannot see. \`accel_class\` is the one field worth reading first: \`workstation-gpu\` (a discrete GPU is deliverable to this container — larger models are cheap here), \`mobile-npu\` (an NPU is deliverable — prefer small quantized models), \`hybrid-gpu-npu\` (both), or \`cpu-only\`.
  - \`cpu-only\` is never a bare verdict: when hardware is present but unreachable, \`accel_gpu\`/\`accel_npu\` read \`present-unusable\` and \`accel_reason\` names the obstruction (e.g. \`cdi-spec-missing\` — the GPU exists but the container runtime has no CDI spec to hand it over; \`engine-missing\` — the NPU exists but no runtime targets it yet). Report the reason rather than concluding the node has no accelerator.
  - \`accel_class\` describes CAPACITY, not readiness. It is independent of \`inference_state\` below: a \`workstation-gpu\` node still reports \`inference_state=not-ready\` until a model is cached.
- **Inference**: \`http://inference:11434\` (Ollama) — ${_inference_status}, tier: ${TILLANDSIAS_INFERENCE_TIER:-unknown}.
  - Machine-readable (branch on this, do not parse the prose): \`inference_state=${_inference_state} inference_models=${_inference_count} inference_warm=${_inference_warm} inference_reason=${_inference_reason}\`
  - \`inference_state\` is \`ready\` only when the endpoint answers AND at least one model is cached. Otherwise \`not-ready\` with a named \`inference_reason\`: \`no-models\` (endpoint up, nothing cached), \`endpoint-unreachable\`, \`endpoint-timeout\`, \`endpoint-http-error\`, \`probe-tool-missing\`, \`probe-helper-missing\`, or \`probe-error-<n>\`. There is no indeterminate "starting up" state.
  - Local inference is OPTIONAL: a \`not-ready\` endpoint never blocks this session. Use cloud models, or pull one yourself (\`curl http://inference:11434/api/pull -d '{"name":"qwen2.5:0.5b"}'\`).
- **Experts** — \`experts: ${_experts_status}\`. An expert is a CITED RETRIEVAL SURFACE behind an MCP tool, not a model; the plan expert runs NO inference. Query it through the \`forge-plan\` MCP server (\`plan_check\`, \`plan_status\`, \`plan_ready\`, \`plan_blocked_by\`, \`plan_closure\`, \`plan_burndown\`) instead of grepping \`plan/index.yaml\`.
  - Machine-readable (branch on this, do not parse the prose): \`experts_state=${_experts_state} experts_reason=${_experts_reason} experts_elapsed=${_experts_elapsed}\`
  - Machine-readable CAPABILITY SKEW (order 569 — branch on this, do not parse the prose): \`${_cap_line}\`
  - \`experts_state=ready\` only means THE BUILD FINISHED. It has never meant the binary can answer — a forge seeded from a base without the expert sources builds a pre-expert binary and reports \`ready\` truthfully while every \`plan_answer\` returns \`confidence=unsupported\` (order 531). The line above is the honest one. Read it as three answers: \`now=\` is what you can use in THIS session; \`after_relaunch=\` is what the MOUNTED CHECKOUT would give you on the next forge run (so it already includes your uncommitted edits to the expert crate); \`blocked_capabilities=\` is the direct answer to "is my current work blocked pending a relaunch".
  - \`skew\` is the field to branch on, and two of its values demand OPPOSITE actions: \`pending-build\` means the build is still running and the capability WILL appear in this session — wait and retry; \`relaunch-required\` means no build will deliver it here, so retrying is FUTILE and you must relaunch the forge (or rebuild by hand). \`relaunch-regresses\` means the running binary has MORE than the checkout and a relaunch would REMOVE capability. \`none\` means nothing is to be gained by waiting or relaunching. \`now=stale-binary\` means a binary is installed but predates the capability manifest, so its abilities are unknowable — treat everything as blocked.
  - ${_cap_advice}
  - \`experts_state\` is \`ready\` only once \`tillandsias-plan\` is built and installed on PATH. \`building\` carries elapsed seconds and is TRANSIENT — retry the MCP tool. \`degraded\` always names a reason from a closed set: \`no-plan-crate\` (this project has no plan expert — expected off-tillandsias), \`no-checkout\`, \`no-cargo\`, \`build-failed\`, \`build-timeout\`, \`binary-missing\`, \`install-failed\`, \`not-built\`. There is no indeterminate "may still be building" state.
  - Experts are OPTIONAL: the build is backgrounded right after the project clone and never gates this session. Details: \`/tmp/forge-lifecycle.log\`.
- **Generic Project Index** — \`project-expert: ${_project_experts_status}\`. Query via the \`project-info\` MCP server (\`project_answer\`, \`project_metadata\`, \`project_structure\`).
  - Machine-readable (branch on this, do not parse the prose): \`project_expert_state=${_project_experts_state} project_expert_reason=${_project_experts_reason} project_expert_elapsed=${_project_experts_elapsed}\`
  - \`project-expert\` is \`ready\` when the generic project index is built into tmpfs (\`$FORGE_EXPERTS_STATE_DIR/project-index/index.json\`).
  - Machine-readable ENGINE-vs-CHECKOUT skew (order 619-pfsj — branch on this, do not parse the prose): \`${_pe_line}\`
  - \`project-expert: ready\` above describes the tmpfs INDEX, not the engine. The answer engine (\`project-info.sh\`) is IMAGE-BAKED, so unlike the launch-built plan engine no relaunch rebuilds it: \`state=ready\` means the baked engine matches the mounted checkout's answer contract (or the checkout carries none — \`expected=-\`); \`state=skewed\` means this image's engine and the checkout disagree (\`missing_in_engine=\`/\`engine_only=\` name the difference) and only an image rebuild heals it; \`state=stale-engine\` means the engine predates the capability manifest and its abilities are unknowable; \`state=absent\` means no engine is installed.
  - ${_pe_advice}
  - With no local inference endpoint, \`project_answer\` still answers the deterministic subset (type, status, commands, layout, actions; plan-backed answers on Tillandsias) and refuses synthesis questions TYPED: \`unsupported: synthesis question — missing_capability=local-inference inference_state=... inference_reason=...\` — branch on \`missing_capability=\`, never parse the prose.
- **Vault**: secrets are available at \`http://vault:8200\`; token is injected automatically.

You never need to configure git remotes, tokens, SSH keys, proxy settings, or CA certs.

## Plan entry points

- **Active work queue**: \`plan/index.yaml\`
- **Full plan index**: \`plan/index.yaml\`
- **Loop status**: \`plan/loop_status.md\`

Pick up work using the \`/meta-orchestration\` skill or \`/advance-work-from-plan\`.

## Skills

Available skills are under \`.claude/skills/\` (Claude Code) or \`.opencode/skills/\` (OpenCode).
Key skills: \`meta-orchestration\`, \`advance-work-from-plan\`, \`merge-to-main-and-release\`.

## Tooling actually present here — check this before reaching for something

Do NOT assume a tool exists because a skill or doc names it. This forge is a
Fedora base, not your host, and the difference has bitten agents repeatedly.

**Present:** \`jq\` \`yq\` \`git\` \`gh\` \`cargo\` \`rustc\` \`node\` \`go\` \`rust-analyzer\`
**ABSENT:** \`ruby\` — several skills still show \`ruby -ryaml\` for YAML validation.
It is not here. Use \`yq\` instead (verified: it accepts valid YAML and exits
non-zero on invalid).

\`\`\`bash
yq . <file> >/dev/null || echo "INVALID YAML: <file>"
\`\`\`

**\`python3\` is present and is FORBIDDEN for committed automation**
(\`methodology.yaml\` → \`tlatoani_hard_no_python\`). Its presence is not permission.
This is the trap worth naming: the sanctioned validator (\`ruby\`) is missing, the
compiled one (\`tillandsias-policy\`) is built per-lane and may not exist yet, and
the forbidden one is sitting right there on PATH. Reach for \`yq\`.

**On-demand tools** (\`tmux\`, \`lazygit\`, \`gum\`, \`fd\`, \`rg\`, …): typing the command
triggers a userspace Homebrew install through a shim, gated on an allowlist. That
install is NOT free — it verifies a Sigstore attestation per bottle and is
time-bounded, so it can fail with "this tool is unavailable". That is a normal
outcome, not a broken forge: prefer what is already present, and treat an
on-demand tool as a convenience rather than a dependency.

## Code navigation — LSP is available (order 399)

\`rust-analyzer\` ships in this forge. OpenCode's built-in LSP picks it up
from PATH — prefer structural queries (go-to-definition, references,
symbol search) over grepping source when resolving code questions.

## Web servers — you are in a FORGE container (read before starting one)

Two flows; pick by intent:

1. **Dev server (iterating)**: run it in here, but bind \`0.0.0.0\` on the
   framework's conventional port — NEVER \`localhost\`/\`127.0.0.1\` (that is
   this container's own loopback; the router cannot reach it and the
   enclave blocks direct ingress — the server will look dead). Hand the
   user \`http://${project_name}.<service>.localhost/\` (no port). Full
   conventions: the web-services instruction / \`tellme about web\`.
2. **Hosting/publishing** ("host/serve/publish this project"): do NOT run
   a server in here. Delegate to the host over the MCP tools
   (\`host-browser\` server): \`publish_local {"category":"WEB"}\` returns
   \`http://www.${project_name}.localhost:8080\` served by a SIBLING
   container; \`service_status\` / \`service_stop\` manage it. The host
   attributes the project from your session — publishing is local-only
   today (public Cloudflare share is a planned rung).
CONTEXT_EOF

    # Ensure the file is gitignored (idempotent append).
    local gitignore="$project_dir/.gitignore"
    if [[ -f "$gitignore" ]] && ! grep -qxF '.forge-startup-context.md' "$gitignore"; then
        echo '.forge-startup-context.md' >> "$gitignore"
    fi

    export FORGE_STARTUP_CONTEXT_FILE="$ctx_file"
    trace_lifecycle "startup-context" "written to $ctx_file (branch=${branch}, version=${version})"
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
