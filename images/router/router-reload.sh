#!/bin/sh
# @trace spec:subdomain-routing-via-reverse-proxy
# Re-merge base + dynamic Caddyfiles and tell Caddy to reload.
#
# Invoked by the tray after rewriting /run/router/dynamic.Caddyfile
# (e.g., when a forge container starts/stops). Idempotent.
set -eu

BASE=/etc/caddy/base.Caddyfile
DYNAMIC=/run/router/dynamic.Caddyfile
MERGED=/tmp/Caddyfile

[ -f "$DYNAMIC" ] || : > "$DYNAMIC"

{
    cat "$BASE"
    if [ -s "$DYNAMIC" ]; then
        echo ""
        echo "# --- dynamic routes (written by tray) ---"
        cat "$DYNAMIC"
    fi
} > "$MERGED.tmp"
mv -f "$MERGED.tmp" "$MERGED"

# Caddy's --watch flag picks up the file change automatically. The
# explicit `caddy reload` here forces a synchronous reload so the
# tray knows the new routes are live before it returns to the user.
caddy reload --config "$MERGED" --adapter caddyfile
echo "[router-reload] reloaded ($(wc -l < $MERGED) lines)"
