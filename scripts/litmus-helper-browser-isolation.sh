#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-help}"

case "$MODE" in
  start-mock-opencode)
    podman exec tillandsias-test-forge-e2e sh -c '
      cat > /tmp/opencode-mock.sh << "EOF"
#!/bin/sh
while true; do
  {
    printf "HTTP/1.1 200 OK\r\n"
    printf "Content-Type: application/json\r\n"
    printf "Connection: close\r\n\r\n"
    printf "{\"status\":\"opencode-ready\",\"path\":\"/\"}\n"
  } | nc -l -p 4096
done
EOF
      chmod +x /tmp/opencode-mock.sh
      /tmp/opencode-mock.sh >/tmp/opencode-mock.log 2>&1 &
      sleep 1 && echo MOCK_STARTED' 2>/dev/null | tail -1
    ;;
  help|*)
    echo "Usage: $0 {start-mock-opencode}"
    exit 2
    ;;
esac
