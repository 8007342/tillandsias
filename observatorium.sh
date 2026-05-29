#!/usr/bin/env bash
# observatorium.sh: Standalone launcher for the Tillandsias Observatorium UI
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

PORT=8080
# Simple port check to find a free port starting from 8080
while ss -ltn 2>/dev/null | grep -q ":$PORT " || netstat -an 2>/dev/null | grep -q ":$PORT "; do
    PORT=$((PORT + 1))
done

echo "Starting Observatorium HTTP server on port $PORT..."

# Start python http server in the background (using host python for speed)
python3 -m http.server $PORT --directory "$REPO_ROOT" >/dev/null 2>&1 &
SERVER_PID=$!

# Ensure server stops when script exits
trap "kill $SERVER_PID 2>/dev/null || true" EXIT INT TERM

# Wait a moment for the server to bind
sleep 1

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Error: HTTP server failed to start."
    exit 1
fi

URL="http://localhost:$PORT/observatorium/index.html"
echo "Observatorium is running at: $URL"

if command -v google-chrome &> /dev/null; then
    echo "Launching Google Chrome..."
    google-chrome --app="$URL" --new-window >/dev/null 2>&1 &
elif command -v google-chrome-stable &> /dev/null; then
    echo "Launching Google Chrome..."
    google-chrome-stable --app="$URL" --new-window >/dev/null 2>&1 &
elif command -v xdg-open &> /dev/null; then
    echo "Launching default browser..."
    xdg-open "$URL" >/dev/null 2>&1 &
else
    echo "Please open your browser and navigate to: $URL"
fi

echo "Press Ctrl+C to stop the server."
wait $SERVER_PID
