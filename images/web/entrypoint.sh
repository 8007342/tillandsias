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

# 2007-hear: /etc/httpd.conf adds the audio MIME types.
exec httpd -f -p 8080 -h /var/www -c /etc/httpd.conf
