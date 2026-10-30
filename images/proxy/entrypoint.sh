#!/bin/bash
# 1922-rann: keep the launcher's notify socket for notify_ready ONLY, and hide it
# from every child. Vault and Vault Agent sd_notify READY=1 on their own start
# (measured: an event before unseal, and a mirror event before its seed), which
# would announce this service before it is ready.
TILLANDSIAS_NOTIFY_SOCKET="${NOTIFY_SOCKET:-}"
unset NOTIFY_SOCKET
set -e
# @trace spec:proxy-container
# Entrypoint for the Tillandsias MITM caching proxy container.
# DISTRO: Alpine 3.22 — bash installed explicitly via apk add bash.
#         Uses POSIX-compatible constructs only (no [[ ]], no arrays).
#         Moved 3.20 -> 3.22 with the squid 6.9 -> 6.12 bump (order 782-9jfg);
#         /usr/lib/squid/security_file_certgen is unchanged on 6.12 and was
#         verified spawning in-container before the bump landed.

# Stage the CA material FIRST (755-qcxh): every squid invocation below —
# including the cache-init `squid -z` — parses squid.conf, and the config
# names the cert/key paths. Initializing the cache before the key existed
# was survivable only while the key arrived as a bind mount; with secret
# delivery it is a FATAL "No valid signing certificate" on first start.

# Copy CA cert from podman secret to working location.
# @trace spec:podman-secrets-integration, spec:proxy-container
# Secrets are mounted at /run/secrets/<name> by podman's --secret flag.
# The PUBLIC cert keeps its bind-mount fallback (it is world-readable
# material and every launcher still mounts it with -v).
if [ -f /run/secrets/tillandsias-ca-cert ]; then
    cp /run/secrets/tillandsias-ca-cert /etc/squid/certs/intermediate.crt
    chmod 644 /etc/squid/certs/intermediate.crt
    echo "CA certificate loaded from podman secret."
elif [ -f /etc/squid/certs/intermediate.crt ]; then
    echo "CA certificate already present (bind-mount fallback)."
else
    echo "ERROR: Intermediate CA cert not found at /run/secrets/tillandsias-ca-cert or /etc/squid/certs/"
    echo "  The tray must create and mount the tillandsias-ca-cert secret via --secret flag."
    exit 1
fi

# 755-qcxh (closes the order 657-vqxz determination): the podman secret is
# the ONLY key path. Every launcher — ensure_proxy_ca_key_secret in the tray,
# scripts/orchestrate-enclave.sh, scripts/diagnose-proxy.sh — creates the
# tillandsias-ca-key secret and mounts it with uid=1000,gid=1000,mode=0400,
# which is what lets the host-side key file stay 0600 instead of the old
# world-readable 0644. The former bind-mount fallback is deliberately GONE:
# images are versioned in lockstep with the tray, so a fallback here would be
# an untaken branch whose only possible use is silently reintroducing a
# world-readable host key. This process runs as `proxy` (uid 1000), so the
# copy below lands owned by the right user; the chown is belt-and-braces for
# an image run without --userns=keep-id.
if [ -f /run/secrets/tillandsias-ca-key ]; then
    cp /run/secrets/tillandsias-ca-key /etc/squid/certs/intermediate.key
    chmod 600 /etc/squid/certs/intermediate.key
    chown proxy:proxy /etc/squid/certs/intermediate.key 2>/dev/null || true
    echo "CA key loaded from podman secret."
else
    echo "ERROR: Intermediate CA key not found at /run/secrets/tillandsias-ca-key"
    echo "  The launcher must create the tillandsias-ca-key podman secret and"
    echo "  mount it via --secret tillandsias-ca-key,uid=1000,gid=1000,mode=0400."
    exit 1
fi

# Initialize cache structure if swap directories don't exist yet.
# (After CA staging: `squid -z` parses the config, which needs the key.)
if [ ! -d /var/spool/squid/00 ]; then
    echo "Initializing squid cache directories..."
    squid -z -N 2>&1
    echo "Cache directories created."
fi

# Initialize SSL certificate database.
# Must recreate on every launch because --userns=keep-id changes ownership.
# @trace spec:proxy-container, spec:podman-secrets-integration
# security_file_certgen -c creates the directory itself — it MUST NOT exist.
echo "Initializing SSL certificate database..."
rm -rf /var/lib/squid/ssl_db 2>/dev/null || true
/usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 16
echo "SSL certificate database created."

echo "========================================"
echo "  tillandsias proxy (ssl-bump enabled)"
echo "  strict:     :3128"
echo "  permissive: :3129 (provisioned, NOT routed — order 245 P6)"
echo "========================================"

# Parse only after the runtime CA material and cache paths exist. This turns
# malformed ACL/action syntax into a bounded startup failure instead of a
# partially running proxy with an accidental trust policy.
echo "Validating Squid configuration..."
squid -k parse

# 767-es4w: squid does NOT run as PID 1 any more — squid-supervisor does, with
# squid as its child. Two reasons, and the second is the one that cost two days:
#   * a real mid-service crash is now counted, named on both streams, and
#     restarted under a flap cap instead of leaving the container Exited(139)
#     with nothing watching;
#   * squid segfaults inside exit() on EVERY ordered shutdown (measured on 6.9
#     and 6.12, idle, this host, 2026-08-17 — after it has already logged
#     "Exiting normally"), so before this wrapper a `podman stop` and a real
#     death were the same Exited(139). The supervisor names that teardown
#     crash separately and normalises its exit code to 0, which is what makes
#     a future Exited(139) on this container mean something again.
# 1922-rann: announce readiness to the launcher. The launcher runs this
# container with `--sdnotify=container` and its own NOTIFY_SOCKET; podman/conmon
# relay this datagram there, so readiness is an event, not a probe. socat because
# BusyBox nc has no unix-socket mode. No socket = an older launcher.
notify_ready() {
    [ -n "$TILLANDSIAS_NOTIFY_SOCKET" ] || return 0
    printf 'READY=1\nSTATUS=%s' "$1" | socat -t1 - "UNIX-SENDTO:$TILLANDSIAS_NOTIFY_SOCKET" 2>/dev/null \
        || echo "[tillandsias] READY=1 not delivered to $TILLANDSIAS_NOTIFY_SOCKET" >&2
}

# squid has no notify hook, so a one-shot watcher reads the kernel's listen
# table (no connection, nothing in squid's log) and announces once, then exits.
# Bounded at 60 s; past that it sends nothing and the launcher's deadline speaks.
(
    port_hex="$(printf '%04X' 3128)"
    i=0
    while [ "$i" -lt 300 ]; do
        for table in /proc/net/tcp /proc/net/tcp6; do
            [ -r "$table" ] || continue
            if awk -v p=":$port_hex" '$4 == "0A" && substr($2, length($2) - 4) == p { f = 1 } END { exit f ? 0 : 1 }' "$table"; then
                notify_ready "proxy listening"
                exit 0
            fi
        done
        i=$((i + 1))
        sleep 0.2
    done
) &

exec /usr/local/bin/squid-supervisor squid squid -N
