#!/usr/bin/env bash
# Exports the headless relay server that both Fly.io and the offline fallback run.
set -euo pipefail

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
cd "$(dirname "$0")/.."

mkdir -p build/server
"$GODOT" --headless --path . --export-release "Linux Server" build/server/truck-town-server

echo
echo "Server build ready in build/server"
echo "  Deploy: fly deploy"
