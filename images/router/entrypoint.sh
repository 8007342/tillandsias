#!/bin/sh
# @trace spec:subdomain-routing-via-reverse-proxy
# Entrypoint for the Tillandsias router.
#
# Merges the static base.Caddyfile (image-baked) with the dynamic
# Caddyfile written by the tray (at /run/router/dynamic.Caddyfile) into
# /tmp/Caddyfile, then exec's caddy with --watch on the merged file.
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
echo "[router] starting Caddy"
echo "[router] base:    $BASE ($(wc -l < $BASE) lines)"
echo "[router] dynamic: $DYNAMIC ($(wc -l < $DYNAMIC) lines)"
echo "[router] merged:  $MERGED ($(wc -l < $MERGED) lines)"

exec caddy run --config "$MERGED" --adapter caddyfile --watch
