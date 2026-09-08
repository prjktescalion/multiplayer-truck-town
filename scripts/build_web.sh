#!/usr/bin/env bash
# Exports the browser build that phones and laptops load.
set -euo pipefail

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
cd "$(dirname "$0")/.."

mkdir -p build/web
"$GODOT" --headless --path . --export-release "Web" build/web/index.html

# vercel.json has to sit at the root of whatever directory gets deployed.
cp vercel.json build/web/vercel.json

echo
echo "Web build ready in build/web"
echo "  Deploy:      vercel --prod build/web"
echo "  Or offline:  scripts/serve_local.sh"
