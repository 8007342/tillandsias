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
        # Order 797-w8kf. The fake podman the litmus fixtures build lives under
        # a `mktemp -d`, not under target/ — scripts/test-image-build-
        # convergence.sh exports LITMUS_FAKE_PODMAN_BIN_DIR="$tmp/fake-podman"
        # and the guard puts the binary in litmus-fake-podman-bin/ beneath it.
        # Unrecognized, it read as a legitimate operator podman, so the wrapper
        # generator baked
        #   exec "/tmp/tmp.XXXXXX/fake-podman/litmus-fake-podman-bin/podman"
        # into the ONE SHARED wrapper at $TMPDIR/tillandsias-podman-wrapper.
        # The tempdir is then removed and the wrapper outlives it, on PATH, for
        # every later consumer on the host.
        #
        # What that cost, measured on macuahuitl 2026-08-17: seven pre-build
        # litmus failures in every `./build.sh --ci-full`, all seven green when
        # run outside it, and three of them reported as "podman unresponsive
        # (>5s): stalled storage lock or dead runtime" while podman answered
        # `info` in 0.07s on 45 consecutive samples taken DURING the failing
        # run. The preflight behind that message is `! timeout 5 podman ps`,
        # which cannot tell a timeout from an exec that failed instantly, so a
        # wrapper pointing at a deleted file was reported as a stalled daemon.
        *fake-podman*|*litmus-fake-podman*)
            return 0
            ;;
    esac
    return 1
}

# Has the CALLER explicitly asked for a private podman store?
#
# Order 793-a62g. This used to be inferred from `timeout 5 podman info`: if the
# probe did not answer within five seconds, the toolchain silently switched to
# the generated wrapper below — a private graphroot with `driver = "vfs"`.
# A five-second stopwatch is not a fact about a host, it is a fact about how
# busy the host was at that instant, so `./build.sh --ci-full` picked its
# storage backend by coin flip: on yoga (Fedora Silverblue, native overlay)
# `podman info` answers in 0.07s idle and 0.26s loaded, but a --ci-full run
# with its lanes in parallel is a different machine than an idle one.
#
# Losing that race is expensive and silent: vfs COPIES every layer instead of
# stacking it (the 30s budget timeouts), and the private graphroot contains
# none of the host's tillandsias-* images (the "missing image" failures).
# Worse, the wrapper is written to one FIXED path shared by every concurrent
# lane, so lanes truncate it while siblings exec it — measured 50/400 = 12.5%
# ETXTBSY exec failures under concurrent rebuild, which `require_podman` could
# only report as "podman is not available on PATH", on a host where podman is
# part of the OS image.
#
# So the wrapper is now CONFIGURATION, never inference: it activates when the
# caller sets a storage override (or points at a remote podman), and otherwise
# we use podman exactly as the operating system provides it. That is also what
# every existing caller already wanted — 022226ce3 added the bypass because the
# wrapper split the image inventory between two stores, and c8ee28dee had to
# special-case macOS out of it because the flags it generates do not exist
# there. Both of those escape hatches are deleted by this rule rather than
# maintained.
_podman_storage_override_requested() {
    local _pso
    for _pso in "${TILLANDSIAS_PODMAN_GRAPHROOT:-}" "${TILLANDSIAS_PODMAN_RUNROOT:-}" \
                "${TILLANDSIAS_PODMAN_STORAGE_CONF:-}"; do
        # A litmus-owned path is the harness talking to itself, not an operator
        # asking for a private store; the wrapper branch already ignores those.
        if [[ -n "$_pso" ]] && ! _is_litmus_path "$_pso"; then
            return 0
        fi
    done
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
     && ! _podman_storage_override_requested; then
    # THE DEFAULT: use podman as the operating system provides it, so
    # shell-script callers and the Rust binary share one storage view. The
    # wrapper below splits the tillandsias-* image inventory between two
    # backends (022226ce3) and generates Linux-only --root/--runroot/--tmpdir
    # flags that Podman on macOS rejects outright with "unknown flag: --root",
    # masking its own actionable "no machine running" message (c8ee28dee).
    #
    # Reaching this branch is no longer conditional on a probe answering
    # quickly enough (see _podman_storage_override_requested). If podman is
    # genuinely broken here, the callers' own checks now say so honestly
    # instead of being silently rerouted onto a private vfs store that is
    # empty, slow, and shared with every parallel lane.
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
    # Order 797-w8kf. Newer-than-podman is not freshness: the wrapper can be
    # perfectly recent and exec a path that no longer exists. The litmus
    # harness builds its fake podman under `mktemp -d` and this file is written
    # to ONE fixed shared path, so the tempdir is removed while the wrapper
    # that execs it survives. Every later consumer then gets exit 127 —
    # "podman EXISTS at ... but did not answer '--version'" — on a host whose
    # real podman answers `info` in 0.06s. Measured on macuahuitl 2026-08-17:
    # one evening's leftover wrapper failed the next morning's whole gate, and
    # deleting it by hand fixed the gate until the next litmus run recreated
    # it. So ask about the target, not only about the mtime.
    if [[ "$_podman_wrapper_needs_rebuild" != true ]] && [[ -r "$PODMAN" ]]; then
        _podman_wrapper_target="$(sed -n 's/^.*exec "\([^"]*\)".*$/\1/p' "$PODMAN" | tail -1)"
        if [[ -n "$_podman_wrapper_target" ]] && [[ ! -x "$_podman_wrapper_target" ]]; then
            _podman_wrapper_needs_rebuild=true
        fi
        unset _podman_wrapper_target
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

    # An ABSENT podman and a podman that is present but did not answer are
    # different faults, and reporting the second as the first sent a host
    # searching PATH while podman sat healthy in /usr/bin (order 793-a62g).
    # On an immutable host — Fedora Silverblue, where podman ships in the OS
    # image — "not available on PATH" is not merely unhelpful, it is a claim
    # the reader can see is false, which costs the whole message its
    # credibility. A wrong diagnosis is worse than a bare failure (741-2izr).
    if [[ ! -e "$PODMAN" ]]; then
        echo "ERROR: podman was not found at '$PODMAN'" >&2
        return 127
    fi

    local _rp_err
    _rp_err="$("$PODMAN" --version 2>&1 >/dev/null)"
    echo "ERROR: podman EXISTS at '$PODMAN' but did not answer '--version'." >&2
    echo "       This is not an installation problem — do not go looking at PATH." >&2
    echo "       podman said: ${_rp_err:-(no output)}" >&2
    # 126 is the shell's own convention for "found, could not execute", which
    # is exactly the ETXTBSY case that made this message lie.
    return 126
}
