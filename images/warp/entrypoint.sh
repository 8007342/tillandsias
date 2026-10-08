#!/bin/sh
# @trace order:1506-euvq (change fleet-messaging-poc, Decision 6)
# warp-svc as PID 1, no systemd. The daemon reads
# /var/lib/cloudflare-warp/mdm.xml (written by the tray from
# secret/cloudflare/mesh into the named volume) and listens on
# /run/cloudflare-warp/warp_service for warp-cli.
set -eu

mkdir -p /run/cloudflare-warp /var/lib/cloudflare-warp

if [ ! -c /dev/net/tun ]; then
    echo "warp-entrypoint: /dev/net/tun absent (launch with --device /dev/net/tun)" >&2
fi

exec /bin/warp-svc --accept-tos "$@"
