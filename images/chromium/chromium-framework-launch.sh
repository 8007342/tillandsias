#!/usr/bin/env bash
set -euo pipefail

find_chromium() {
    if command -v chromium >/dev/null 2>&1; then
        command -v chromium
        return 0
    fi
    if command -v chromium-browser >/dev/null 2>&1; then
        command -v chromium-browser
        return 0
    fi
    return 1
}

accepts_no_sandbox() {
    local bin="$1"
    # Some Chromium wrappers reject unknown switches before launching.
    # Probe directly with a bounded timeout; Fedora Chromium accepts --no-sandbox
    # but does not advertise it in --help.
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=1s 5s "$bin" --no-sandbox --version >/dev/null 2>&1
    else
        return 1
    fi
}

# Order 1769-9gna: the browser never connects to the output-only server the
# window was given. Every client of that server can list the host's devices
# (the HDMI TV's name, the sound card, a LAN AirPlay peer and its address), so
# a private server inside this container, whose only device is a "Speakers"
# tunnel to it, stands in front (/etc/tillandsias/browser-audio.pa). If the
# private server cannot start, the window gets no sound, never the host view.
start_private_audio() {
    local upstream="${PULSE_SERVER#unix:}"
    # /tmp, not the runtime dir: the window's runtime tmpfs is root-owned and
    # holds only the sockets it was given.
    local dir="/tmp/tillandsias-audio"
    local socket="$dir/native"
    local conf
    [[ -S "$upstream" ]] || return 1
    mkdir -p -m 0700 "$dir" || return 1
    conf="$(< /etc/tillandsias/browser-audio.pa)" || return 1
    conf="${conf//@SOCKET@/$socket}"
    conf="${conf//@UPSTREAM@/$upstream}"
    printf '%s\n' "$conf" > "$dir/private.pa" || return 1
    # Its own runtime dir: pulseaudio refuses one it does not own. Its log goes
    # to a file (it reports the absent system D-Bus as errors), shown only when
    # it fails to start.
    XDG_RUNTIME_DIR="$dir" pulseaudio -n --daemonize=no --exit-idle-time=-1 \
        --disable-shm=yes --use-pid-file=no --disallow-module-loading=yes \
        --disallow-exit=yes --log-target=file:"$dir/pulseaudio.log" \
        --log-level=error -F "$dir/private.pa" &
    local i=0
    while [[ ! -S "$socket" && $i -lt 50 ]]; do
        sleep 0.1
        i=$((i + 1))
    done
    if [[ ! -S "$socket" ]]; then
        tail -n 5 "$dir/pulseaudio.log" >&2 || true
        return 1
    fi
    export PULSE_SERVER="unix:$socket"
}

if [[ -n "${PULSE_SERVER:-}" ]] && ! start_private_audio; then
    echo "chromium framework launcher: the private audio server did not start; the window has no sound" >&2
    unset PULSE_SERVER
fi

CHROMIUM_BIN="$(find_chromium || true)"
if [[ -z "$CHROMIUM_BIN" ]]; then
    echo "chromium framework launcher: no chromium binary found" >&2
    exit 127
fi

ARGS=(
    "$@"
    "--disable-crash-reporter"
    "--disable-breakpad"
    "--disable-sync"
)

if accepts_no_sandbox "$CHROMIUM_BIN"; then
    # Chromium's setuid sandbox cannot launch inside our hardening
    # (--cap-drop=ALL + --security-opt=no-new-privileges); the container exits
    # 21 ("no usable sandbox") without this flag. The container itself remains
    # locked down via userns, dropped caps, no-new-privileges, and tmpfs mounts.
    ARGS+=("--no-sandbox")
fi

exec "$CHROMIUM_BIN" "${ARGS[@]}"
