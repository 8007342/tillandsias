#!/usr/bin/env bash

_resolve_podman_bin() {
    local path_entry candidate
    IFS=: read -ra _path_entries <<<"${PATH:-}"
    for path_entry in "${_path_entries[@]}"; do
        candidate="$path_entry/podman"
        if [[ -x "$candidate" ]]; then
            case "$candidate" in
                */target/litmus-runtime/bin/podman)
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

_podman_bin="$(_resolve_podman_bin)"
if [[ -z "$_podman_bin" ]]; then
    PODMAN=podman
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
