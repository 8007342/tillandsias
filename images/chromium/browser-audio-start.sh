# browser-audio-start.sh — SOURCED by a browser window's launcher, before it
# starts the browser (orders 1769-9gna, 1777-yhwr).
#
# The SAME file in images/chromium and images/webkit: each image builds from
# its own context, so the file is copied, and the cargo test
# host_audio_browser_view_is_one_generic_speakers_sink holds the two copies
# byte-identical (with browser-audio.pa, the server's whole configuration).
#
# Order 1769-9gna: the browser never connects to the output-only server the
# window was given. Every client of that server can list the host's devices
# (the HDMI TV's name, the sound card, a LAN AirPlay peer and its address), so
# a private server inside this container, whose only device is a "Speakers"
# tunnel to it, stands in front (/etc/tillandsias/browser-audio.pa). If the
# private server cannot start, the window gets no sound, never the host view.
start_private_audio() {
    local upstream="${PULSE_SERVER#unix:}"
    # /tmp, a writable tmpfs in every window; the Chromium window's runtime
    # tmpfs is root-owned and holds only the sockets it was given.
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
    echo "browser window launcher: the private audio server did not start; the window has no sound" >&2
    unset PULSE_SERVER
fi
