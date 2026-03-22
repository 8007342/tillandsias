#!/bin/sh
set -e

PROJECT_NAME="$(basename "$(pwd)")"

echo "========================================"
echo "  tillandsias web"
echo "  project: ${PROJECT_NAME}"
echo "========================================"
echo ""
echo "Serving at http://localhost:8080"
echo ""

exec httpd -f -p 8080 -h /var/www
