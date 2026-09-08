#!/usr/bin/env bash
# Serves the web build for local browser testing.
#
# Open the printed http://localhost URL. Godot's web runtime requires a secure context, and only
# HTTPS, localhost and 127.0.0.1 qualify -- a LAN IP over plain HTTP will fail with
# "Secure Context - Check web server config (use HTTPS)". Phones therefore cannot use this script;
# deploy to Vercel + Fly, or expose it over HTTPS with a tunnel. See the README.
#
# Pair it with a relay server:
#   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --server
set -euo pipefail

PORT="${PORT:-8080}"
cd "$(dirname "$0")/.."

if [ ! -f build/web/index.html ]; then
	echo "No web build found. Run scripts/build_web.sh first." >&2
	exit 1
fi

echo "Open http://localhost:$PORT  (localhost only -- see the note in this script)"
echo

cd build/web
exec python3 -m http.server "$PORT" --bind 0.0.0.0
