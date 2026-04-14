#!/bin/sh
set -e
# @trace spec:web-image
# DISTRO: Alpine — uses #!/bin/sh (busybox ash). No bash dependency.
#         httpd is busybox built-in. No curl/wget needed.

PROJECT_NAME="$(basename "$(pwd)")"

echo "========================================"
echo "  tillandsias web"
echo "  project: ${PROJECT_NAME}"
echo "========================================"
echo ""
echo "Serving at http://localhost:8080"
echo ""

exec httpd -f -p 8080 -h /var/www
