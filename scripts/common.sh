#!/usr/bin/env bash

if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

podman_runtime_health_probe() {
    local probe_log="/tmp/litmus-runtime-health.log"
    local migrate_log="/tmp/litmus-runtime-migrate.log"
    local probe_image=""
    local podman_ctl="$REPO_ROOT/scripts/tillandsias-podman"

    probe_image="${FORGE_IMAGE:-tillandsias-forge:v$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")}"
    if [[ -z "$probe_image" ]]; then
        printf 'forge image not available\n' >"$probe_log"
        return 1
    fi

    if ! "$podman_ctl" image exists "$probe_image" >/dev/null 2>&1; then
        printf 'forge image not available: %s\n' "$probe_image" >"$probe_log"
        return 1
    fi

    if timeout 5 "$podman_ctl" container run --rm --userns=host --entrypoint=env "$probe_image" \
        >/dev/null 2>"$probe_log"; then
        return 0
    fi

    if grep -Eqi 'newuidmap|read-only file system|acquiring runtime init lock|cannot set up namespace' "$probe_log"; then
        "$podman_ctl" system migrate >"$migrate_log" 2>&1 || true
        if timeout 5 "$podman_ctl" container run --rm --userns=host --entrypoint=env "$probe_image" \
            >/dev/null 2>>"$probe_log"; then
            return 0
        fi
    fi

    return 1
}

_resolve_podman_bin() {
    local path_entry candidate
    IFS=: read -ra _path_entries <<<"${PATH:-}"
    for path_entry in "${_path_entries[@]}"; do
        candidate="$path_entry/podman"
        if [[ -x "$candidate" ]]; then
            case "$candidate" in
                */target/litmus-runtime/bin/podman| \
                */tillandsias-podman-wrapper/podman)
                    continue
                    ;;
            esac
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    for _candidate in /usr/bin/podman /bin/podman /usr/local/bin/podman; do
        if [[ -x "$_candidate" ]]; then
            printf '%s\n' "$_candidate"
            return 0
        fi
    done

    command -v podman 2>/dev/null || true
}

_is_litmus_path() {
    case "$1" in
        *target/litmus-podman*|*target/litmus-runtime*)
            return 0
            ;;
    esac
    return 1
}

_podman_remote_url() {
    local candidate="${TILLANDSIAS_PODMAN_REMOTE_URL:-${CONTAINER_HOST:-}}"
    candidate="${candidate#"${candidate%%[![:space:]]*}"}"
    candidate="${candidate%"${candidate##*[![:space:]]}"}"
    if [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
}

_find_litmus_podman_bin() {
    # Returns the litmus podman wrapper if run-litmus-test.sh has put it on
    # PATH. We can't just go through _resolve_podman_bin because that filter
    # explicitly skips */target/litmus-runtime/bin/podman to avoid recursion
    # when the wrapper itself sources common.sh.
    local IFS=: parts
    read -ra parts <<<"${PATH:-}"
    for d in "${parts[@]}"; do
        if [[ "$d" == */target/litmus-runtime/bin && -x "$d/podman" ]]; then
            printf '%s\n' "$d/podman"
            return 0
        fi
    done
    return 1
}

_podman_bin="$(_resolve_podman_bin)"
_litmus_podman_bin="$(_find_litmus_podman_bin || true)"
if [[ -z "$_podman_bin" ]]; then
    PODMAN=podman
elif [[ -n "${LITMUS_PODMAN_CALLS_FILE:-}" && -n "$_litmus_podman_bin" ]]; then
    # A litmus test run is active and run-litmus-test.sh has installed its
    # wrapper at target/litmus-runtime/bin/podman. That wrapper records every
    # call AND implements LITMUS_PODMAN_MODE fake/real injection — both
    # essential for litmus tests like browser-ephemeral that assert on the
    # contract of the podman call shape. Route $PODMAN through it instead of
    # the host wrapper or direct podman; otherwise launch-chromium.sh and
    # friends silently skip the wrapper and tests see empty calls files.
    PODMAN="$_litmus_podman_bin"
    export TILLANDSIAS_PODMAN_BIN="$_litmus_podman_bin"
elif [[ -z "${TILLANDSIAS_PODMAN_REMOTE_URL:-${CONTAINER_HOST:-}}" ]] \
     && { [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] \
          || timeout 5 "$_podman_bin" info --format '{{.Store.GraphRoot}}' >/dev/null 2>&1; }; then
    # Direct podman works under the current environment. Skip the wrapper so
    # shell-script callers and the Rust binary share one storage view; without
    # this fast-path the wrapper points scripts at a private /tmp graphroot
    # while the binary keeps using the user's default store, splitting the
    # tillandsias-* image inventory between two backends and silently breaking
    # the runtime litmus probe.
    #
    # macOS unconditionally takes this branch (skipping the `podman info`
    # probe): Homebrew Podman on macOS is ALWAYS a remote-machine client, even
    # when a machine happens to be running — it never supports the Linux
    # local-VFS-storage flags (--root/--runroot/--tmpdir) the else branch
    # below generates. Routing macOS through that branch produced "Error:
    # unknown flag: --root" instead of Podman's own actionable "no machine
    # running" message. Skipping the probe also means a macOS host with no
    # machine running gets that same honest, actionable error immediately
    # instead of it being masked behind the wrapper's flag-rejection failure.
    PODMAN="$_podman_bin"
    # Deliberately UNSET TILLANDSIAS_PODMAN_BIN here instead of pinning it
    # to $_podman_bin. The litmus runner (scripts/run-litmus-test.sh) only
    # prepends its mock wrapper to PATH *after* this script is first sourced
    # by build.sh; if we pin the binary to /usr/bin/podman now, the Rust
    # launcher ignores that PATH prepend, runs real podman against a
    # missing inference container, and the cache-recovery-fresh-start
    # litmus times out at 20s with "inference offline".
    unset TILLANDSIAS_PODMAN_BIN
    _stale_wrapper_dir="${TMPDIR:-/tmp}/tillandsias-podman-wrapper"
    case ":$PATH:" in
        *":$_stale_wrapper_dir:"*)
            PATH="${PATH//":$_stale_wrapper_dir:"/":"}"
            PATH="${PATH#"$_stale_wrapper_dir:"}"
            PATH="${PATH%":$_stale_wrapper_dir"}"
            export PATH
            ;;
    esac
    unset _stale_wrapper_dir
else
    _podman_remote_url="$(_podman_remote_url)"
    _podman_wrapper_dir="${TILLANDSIAS_PODMAN_WRAPPER_DIR:-}"
    if _is_litmus_path "$_podman_wrapper_dir"; then
        _podman_wrapper_dir=""
    fi
    if [[ -z "$_podman_wrapper_dir" ]]; then
        _podman_wrapper_dir="${TMPDIR:-/tmp}/tillandsias-podman-wrapper"
    fi
    PODMAN="${_podman_wrapper_dir}/podman"
    export PATH="$_podman_wrapper_dir:$PATH"
    export TILLANDSIAS_PODMAN_BIN="$PODMAN"

    _podman_wrapper_needs_rebuild=false
    if [[ ! -x "$PODMAN" ]] || [[ "$PODMAN" -ot "$_podman_bin" ]]; then
        _podman_wrapper_needs_rebuild=true
    fi
    if [[ -n "$_podman_remote_url" ]]; then
        export TILLANDSIAS_PODMAN_REMOTE_URL="$_podman_remote_url"
        _podman_remote_runtime_dir="${TILLANDSIAS_PODMAN_RUNTIME_DIR:-}"
        if _is_litmus_path "$_podman_remote_runtime_dir"; then
            _podman_remote_runtime_dir=""
        fi
        if [[ -z "$_podman_remote_runtime_dir" ]]; then
            _podman_remote_runtime_dir="${TMPDIR:-/tmp}/tillandsias-podman-remote-runtime"
        fi
        mkdir -p "$_podman_remote_runtime_dir"
        chmod 700 "$_podman_remote_runtime_dir" 2>/dev/null || true
        if ! grep -Fq "# tillandsias-remote-url-v2: $_podman_remote_url" "$PODMAN" 2>/dev/null; then
            _podman_wrapper_needs_rebuild=true
        fi
    elif grep -Fq "# tillandsias-remote-url-v2:" "$PODMAN" 2>/dev/null; then
        _podman_wrapper_needs_rebuild=true
    fi

    if [[ "$_podman_wrapper_needs_rebuild" == true ]]; then
        mkdir -p "$_podman_wrapper_dir"
        if [[ -n "$_podman_remote_url" ]]; then
            cat > "$PODMAN" <<EOF
#!/usr/bin/env bash
# tillandsias-remote-url-v2: $_podman_remote_url
unset TILLANDSIAS_PODMAN_GRAPHROOT TILLANDSIAS_PODMAN_RUNROOT TILLANDSIAS_PODMAN_RUNTIME_DIR TILLANDSIAS_PODMAN_WRAPPER_DIR TILLANDSIAS_PODMAN_STORAGE_CONF TILLANDSIAS_PODMAN_REMOTE_URL CONTAINER_HOST CONTAINER_CONNECTION
unset LITMUS_PODMAN_MODE LITMUS_PODMAN_STATE_DIR LITMUS_PODMAN_CALLS_FILE
XDG_RUNTIME_DIR="$_podman_remote_runtime_dir" exec "$_podman_bin" --remote --url "$_podman_remote_url" "\$@"
EOF
        else
            _podman_graphroot="${TILLANDSIAS_PODMAN_GRAPHROOT:-}"
            if _is_litmus_path "$_podman_graphroot"; then
                _podman_graphroot=""
            fi
            if [[ -z "$_podman_graphroot" ]]; then
                for _candidate_graphroot in \
                    "$HOME/.local/share/tillandsias/podman" \
                    "${TMPDIR:-/tmp}/tillandsias-podman-root"; do
                    if mkdir -p "$_candidate_graphroot" 2>/dev/null && [[ -w "$_candidate_graphroot" ]]; then
                        _podman_graphroot="$_candidate_graphroot"
                        break
                    fi
                done
            fi
            if [[ -z "$_podman_graphroot" ]]; then
                _podman_graphroot="${TMPDIR:-/tmp}/tillandsias-podman-root"
                mkdir -p "$_podman_graphroot" 2>/dev/null || true
            fi
            _podman_runroot="${TILLANDSIAS_PODMAN_RUNROOT:-}"
            if _is_litmus_path "$_podman_runroot"; then
                _podman_runroot=""
            fi
            if [[ -z "$_podman_runroot" ]]; then
                _podman_runroot="${TMPDIR:-/tmp}/tillandsias-podman-runroot"
            fi
            _podman_runtime_dir="${TILLANDSIAS_PODMAN_RUNTIME_DIR:-}"
            if _is_litmus_path "$_podman_runtime_dir"; then
                _podman_runtime_dir=""
            fi
            if [[ -z "$_podman_runtime_dir" ]]; then
                _podman_runtime_dir="${TMPDIR:-/tmp}/tillandsias-podman-runtime"
            fi
            _podman_storage_conf="${TILLANDSIAS_PODMAN_STORAGE_CONF:-}"
            if _is_litmus_path "$_podman_storage_conf"; then
                _podman_storage_conf=""
            fi
            if [[ -z "$_podman_storage_conf" ]]; then
                _podman_storage_conf="${_podman_wrapper_dir}/storage.conf"
            fi
            mkdir -p "$_podman_graphroot" "$_podman_runroot" "$_podman_runtime_dir"
            chmod 700 "$_podman_runtime_dir" 2>/dev/null || true
            if [[ -n "${XDG_RUNTIME_DIR:-}" && "$XDG_RUNTIME_DIR" != "$_podman_runtime_dir" ]]; then
                _podman_host_bus="${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
                if [[ -z "$_podman_host_bus" || "$_podman_host_bus" == "${DBUS_SESSION_BUS_ADDRESS}" ]]; then
                    _podman_host_bus="${XDG_RUNTIME_DIR}/bus"
                fi
                if [[ -e "$_podman_host_bus" && ! -e "$_podman_runtime_dir/bus" ]]; then
                    ln -s "$_podman_host_bus" "$_podman_runtime_dir/bus" 2>/dev/null || true
                fi
                if [[ -d "${XDG_RUNTIME_DIR}/systemd" && ! -e "$_podman_runtime_dir/systemd" ]]; then
                    ln -s "${XDG_RUNTIME_DIR}/systemd" "$_podman_runtime_dir/systemd" 2>/dev/null || true
                fi
            fi
            cat > "$_podman_storage_conf" <<EOF
[storage]
driver = "vfs"
graphroot = "$_podman_graphroot"
runroot = "$_podman_runroot"
EOF
            cat > "$PODMAN" <<EOF
#!/usr/bin/env bash
# tillandsias-local-wrapper
unset TILLANDSIAS_PODMAN_GRAPHROOT TILLANDSIAS_PODMAN_RUNROOT TILLANDSIAS_PODMAN_RUNTIME_DIR TILLANDSIAS_PODMAN_WRAPPER_DIR TILLANDSIAS_PODMAN_STORAGE_CONF TILLANDSIAS_PODMAN_REMOTE_URL CONTAINER_HOST CONTAINER_CONNECTION
unset LITMUS_PODMAN_MODE LITMUS_PODMAN_STATE_DIR LITMUS_PODMAN_CALLS_FILE
if [[ -e "$_podman_runtime_dir/bus" ]]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=$_podman_runtime_dir/bus"
fi
XDG_RUNTIME_DIR="$_podman_runtime_dir" CONTAINERS_STORAGE_CONF="$_podman_storage_conf" ${DBUS_SESSION_BUS_ADDRESS:+DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"} exec "$_podman_bin" --root "$_podman_graphroot" --runroot "$_podman_runroot" --tmpdir "$_podman_runtime_dir" "\$@"
EOF
        fi
        chmod +x "$PODMAN"
        export PATH="$_podman_wrapper_dir:$PATH"
        export TILLANDSIAS_PODMAN_BIN="$PODMAN"
    fi
fi

toolbox() (
    if [[ -z "${TILLANDSIAS_PODMAN_REMOTE_URL:-}" && -z "${CONTAINER_HOST:-}" && -z "${CONTAINER_CONNECTION:-}" ]]; then
        unset TILLANDSIAS_PODMAN_REMOTE_URL CONTAINER_HOST CONTAINER_CONNECTION
    fi
    command toolbox "$@"
)

if [[ -x "${TILLANDSIAS_PODMAN_WRAPPER_DIR:-}/toolbox" ]] && grep -Fq "# tillandsias-toolbox-wrapper-v1" "${TILLANDSIAS_PODMAN_WRAPPER_DIR:-}/toolbox" 2>/dev/null; then
    rm -f "${TILLANDSIAS_PODMAN_WRAPPER_DIR:-}/toolbox" 2>/dev/null || true
fi

require_podman() {
    if "$PODMAN" --version >/dev/null 2>&1; then
        return 0
    fi

    echo "ERROR: podman must be installed and available on PATH" >&2
    return 127
}
