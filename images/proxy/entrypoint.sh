#!/bin/bash
set -e
# @trace spec:proxy-container
# Entrypoint for the Tillandsias caching proxy container.
# Initializes the squid cache directory if needed, then runs squid in foreground.

# Initialize cache structure if swap directories don't exist yet.
if [ ! -d /var/spool/squid/00 ]; then
    echo "Initializing squid cache directories..."
    squid -z -N 2>&1
    echo "Cache directories created."
fi

echo "========================================"
echo "  tillandsias proxy"
echo "  listening on :3128"
echo "========================================"

# Run squid in foreground mode (no daemon fork).
exec squid -N
