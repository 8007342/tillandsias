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
# @trace spec:proxy-container
# security_file_certgen -c creates the directory itself — it MUST NOT exist.
echo "Initializing SSL certificate database..."
rm -rf /var/lib/squid/ssl_db 2>/dev/null || true
/usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 16
echo "SSL certificate database created."

# Validate that the intermediate CA cert and key were injected.
if [ ! -f /etc/squid/certs/intermediate.crt ] || [ ! -f /etc/squid/certs/intermediate.key ]; then
    echo "ERROR: Intermediate CA cert/key not found at /etc/squid/certs/"
    echo "  The host must bind-mount these files at container launch."
    exit 1
fi

echo "========================================"
echo "  tillandsias proxy (ssl-bump enabled)"
echo "  strict:     :3128"
echo "  permissive: :3129"
echo "========================================"

exec squid -N
