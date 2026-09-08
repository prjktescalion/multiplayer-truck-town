#!/usr/bin/env bash
# Offline fallback for the table: serves the web build over plain HTTP on the local network.
# Pair it with a local server process:
#   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --server
#
# Phones reach the game server automatically, because the page tells them to connect back to
# whichever host served it. This needs a network without client isolation, so use a travel
# router or a phone hotspot rather than campus WiFi.
set -euo pipefail

PORT="${PORT:-8080}"
cd "$(dirname "$0")/.."

if [ ! -f build/web/index.html ]; then
	echo "No web build found. Run scripts/build_web.sh first." >&2
	exit 1
fi

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
echo "Serving on http://$IP:$PORT  <- point the QR code here"
echo

cd build/web
exec python3 -m http.server "$PORT" --bind 0.0.0.0
