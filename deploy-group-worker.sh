#!/usr/bin/env bash
# Run from the girlfriendCaller Codespace root. Replaces and deploys the group-capable Worker.
set -Eeuo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$ROOT/call-signaling"

if [[ ! -f "$PROJECT_DIR/wrangler.jsonc" ]]; then
  echo "ERROR: $PROJECT_DIR/wrangler.jsonc was not found. Run this from your girlfriendCaller Codespace and make sure call-signaling exists." >&2
  exit 1
fi
mkdir -p "$PROJECT_DIR/src"
cp "$SOURCE_DIR/worker/src/index.js" "$PROJECT_DIR/src/index.js"
cp "$SOURCE_DIR/worker/wrangler.jsonc" "$PROJECT_DIR/wrangler.jsonc"
cd "$PROJECT_DIR"

if ! npx --yes wrangler@latest whoami >/dev/null 2>&1; then
  echo "Cloudflare CLI login is missing. Run: npx wrangler login --device --browser=false" >&2
  exit 1
fi

npx --yes wrangler@latest deploy
printf '\nGroup-capable signaling Worker deployed.\n'
printf 'Health check: https://our-video-call-signal.blackj9898.workers.dev/health\n'
printf 'WebSocket base: wss://our-video-call-signal.blackj9898.workers.dev\n'
