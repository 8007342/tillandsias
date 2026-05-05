#!/bin/bash
set -e
# @trace spec:proxy-container
# Entrypoint for the Tillandsias MITM caching proxy container.
# DISTRO: Alpine 3.20 — bash installed explicitly via apk add bash.
#         Uses POSIX-compatible constructs only (no [[ ]], no arrays).

# Initialize cache structure if swap directories don't exist yet.
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

# Copy CA cert and key from podman secret to working location.
# @trace spec:podman-secrets-integration, spec:proxy-container
# Secrets are mounted at /run/secrets/<name> by podman's --secret flag.
# If secrets are not available (backward compat or manual invocation without --secret),
# fall back to checking the old bind-mount location; if neither exists, fail gracefully.
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

if [ -f /run/secrets/tillandsias-ca-key ]; then
    cp /run/secrets/tillandsias-ca-key /etc/squid/certs/intermediate.key
    chmod 600 /etc/squid/certs/intermediate.key
    chown proxy:proxy /etc/squid/certs/intermediate.key 2>/dev/null || true
    echo "CA key loaded from podman secret."
elif [ -f /etc/squid/certs/intermediate.key ]; then
    echo "CA key already present (bind-mount fallback)."
else
    echo "ERROR: Intermediate CA key not found at /run/secrets/tillandsias-ca-key or /etc/squid/certs/"
    echo "  The tray must create and mount the tillandsias-ca-key secret via --secret flag."
    exit 1
fi

echo "========================================"
echo "  tillandsias proxy (ssl-bump enabled)"
echo "  strict:     :3128"
echo "  permissive: :3129"
echo "========================================"

exec squid -N
