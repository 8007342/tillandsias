#!/bin/sh
# @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session-otp
# Entrypoint for the Tillandsias router.
#
# 1. Merge static base.Caddyfile + dynamic Caddyfile (bind-mounted from
#    the tray at /run/router/dynamic.Caddyfile) into /tmp/Caddyfile.
# 2. Launch the tillandsias-router-sidecar in a supervised background
#    loop so a sidecar crash gets restarted without taking Caddy down.
# 3. Wait until the sidecar is listening on 127.0.0.1:9090 (max 5 s) so
#    Caddy doesn't fire forward_auth requests against a not-yet-bound
#    socket. If the sidecar fails to come up in that window we proceed
#    anyway — Caddy will return 502 from forward_auth, which surfaces
#    the symptom rather than masking it.
# 4. exec caddy with --watch on the merged file.
#
# Reload after the tray writes new routes: the tray runs
#   podman exec tillandsias-router /usr/local/bin/router-reload.sh
# which re-merges and tells caddy to reload via its admin API. The
# admin API is bound to localhost inside the container only, so no
# external reload path exists.
set -eu

BASE=/etc/caddy/base.Caddyfile
DYNAMIC=/run/router/dynamic.Caddyfile
MERGED=/tmp/Caddyfile

mkdir -p "$(dirname "$DYNAMIC")"
[ -f "$DYNAMIC" ] || : > "$DYNAMIC"

merge() {
    {
        cat "$BASE"
        if [ -s "$DYNAMIC" ]; then
            echo ""
            echo "# --- dynamic routes (written by tray) ---"
            cat "$DYNAMIC"
        fi
    } > "$MERGED.tmp"
    mv -f "$MERGED.tmp" "$MERGED"
}

merge
echo "[router] base:    $BASE ($(wc -l < $BASE) lines)"
echo "[router] dynamic: $DYNAMIC ($(wc -l < $DYNAMIC) lines)"
echo "[router] merged:  $MERGED ($(wc -l < $MERGED) lines)"

# @trace spec:opencode-web-session-otp
# Supervise the sidecar in the background. `until ...; do sleep 1; done`
# keeps respawning it if it exits — the loop runs in a subshell so it
# doesn't trap-out when caddy exits. caddy is the foreground process; it
# owns PID 1's death (which kills the container, which kills this loop).
echo "[router] starting tillandsias-router-sidecar (background)"
( until /usr/local/bin/tillandsias-router-sidecar; do
    echo "[router] sidecar exited; restarting in 1s" >&2
    sleep 1
  done ) &
SIDECAR_PID=$!

# Wait for the sidecar to bind 9090 (max 5 s, polled every 100 ms).
# We do this BEFORE exec caddy so the first forward_auth request lands
# against a bound socket. If it never comes up, log and proceed —
# Caddy's 502 is a louder symptom than a hidden hang.
SIDECAR_PORT="${TILLANDSIAS_VALIDATE_PORT:-9090}"
i=0
while [ "$i" -lt 50 ]; do
    if curl -fsS -o /dev/null -m 1 "http://127.0.0.1:${SIDECAR_PORT}/validate?project=health" 2>/dev/null; then
        echo "[router] sidecar listening on 127.0.0.1:${SIDECAR_PORT}"
        break
    fi
    # 401 also means "alive but no session" — that's the expected
    # response to a health-style probe with no Cookie header. curl's
    # exit code is 22 for HTTP 4xx (-f flag treats 4xx/5xx as failure),
    # so we re-probe with -f off and check status code.
    if [ "$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:${SIDECAR_PORT}/validate?project=health" 2>/dev/null)" = "401" ]; then
        echo "[router] sidecar listening on 127.0.0.1:${SIDECAR_PORT} (replied 401 to probe — expected)"
        break
    fi
    i=$((i + 1))
    sleep 0.1
done
if [ "$i" -ge 50 ]; then
    echo "[router] WARNING: sidecar didn't come up within 5s; forward_auth will 502 until it does" >&2
fi

echo "[router] starting Caddy"
exec caddy run --config "$MERGED" --adapter caddyfile --watch
