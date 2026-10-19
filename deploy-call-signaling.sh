#!/usr/bin/env bash
# Deploy a minimal two-person WebSocket signaling Worker using a Durable Object.
# The deployed Worker runs on Cloudflare; this Codespace is only used to deploy it.
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-$PWD/call-signaling}"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || fail "Node.js is required. Run this from your GitHub Codespace terminal."
command -v npm >/dev/null 2>&1 || fail "npm is required."

mkdir -p "$PROJECT_DIR/src"
cd "$PROJECT_DIR"

say "Writing Cloudflare Worker configuration"
cat > wrangler.jsonc <<'JSON'
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "our-video-call-signal",
  "main": "src/index.js",
  "compatibility_date": "2026-10-19",
  "durable_objects": {
    "bindings": [
      {
        "name": "CALL_ROOMS",
        "class_name": "CallRoom"
      }
    ]
  },
  "exports": {
    "CallRoom": {
      "type": "durable-object",
      "storage": "sqlite"
    }
  }
}
JSON

say "Writing WebSocket signaling backend"
cat > src/index.js <<'JS'
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return new Response("Our Video Call signaling is online.\n", {
        headers: { "content-type": "text/plain; charset=utf-8" }
      });
    }

    const match = url.pathname.match(/^\/room\/([a-z0-9-]{1,40})$/);
    if (!match) {
      return new Response(
        "Use /health or connect a WebSocket to /room/ROOM-CODE.\n",
        { status: 404, headers: { "content-type": "text/plain; charset=utf-8" } }
      );
    }

    if ((request.headers.get("Upgrade") || "").toLowerCase() !== "websocket") {
      return new Response("WebSocket upgrade required.\n", { status: 426 });
    }

    const roomId = env.CALL_ROOMS.idFromName(match[1]);
    return env.CALL_ROOMS.get(roomId).fetch(request);
  }
};

export class CallRoom {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    if ((request.headers.get("Upgrade") || "").toLowerCase() !== "websocket") {
      return new Response("WebSocket upgrade required.\n", { status: 426 });
    }

    const url = new URL(request.url);
    const name = (url.searchParams.get("name") || "Guest")
      .trim().replace(/[<>\u0000-\u001f]/g, "").slice(0, 30) || "Guest";
    const existing = this.ctx.getWebSockets();
    const [client, server] = Object.values(new WebSocketPair());

    this.ctx.acceptWebSocket(server);

    if (existing.length >= 2) {
      server.serializeAttachment({ name, rejected: true });
      server.send(JSON.stringify({
        type: "error",
        message: "This room already has two people in it."
      }));
      server.close(1008, "Room full");
      return new Response(null, { status: 101, webSocket: client });
    }

    server.serializeAttachment({ name, joinedAt: Date.now() });
    const shouldOffer = existing.length === 1;

    server.send(JSON.stringify({
      type: "welcome",
      shouldOffer,
      peerCount: existing.length + 1
    }));

    for (const peer of existing) {
      this.safeSend(peer, { type: "peer-joined", name });
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, rawMessage) {
    let message;
    try {
      const text = typeof rawMessage === "string"
        ? rawMessage
        : new TextDecoder().decode(rawMessage);
      if (text.length > 500000) return;
      message = JSON.parse(text);
    } catch {
      this.safeSend(ws, { type: "error", message: "Invalid message format." });
      return;
    }

    if (!message || typeof message.type !== "string") return;
    const attachment = ws.deserializeAttachment() || {};
    if (attachment.rejected) return;

    if (["offer", "answer", "candidate"].includes(message.type)) {
      // Forward WebRTC descriptions/candidates only; never relay media here.
      const safe = { type: message.type };
      if (message.type === "candidate") {
        if (!message.candidate || typeof message.candidate !== "object") return;
        safe.candidate = message.candidate;
      } else {
        if (!message.description || typeof message.description !== "object") return;
        safe.description = message.description;
      }
      this.broadcast(ws, safe);
      return;
    }

    if (message.type === "chat") {
      if (typeof message.text !== "string") return;
      const text = message.text.trim().slice(0, 1000);
      if (!text) return;
      this.broadcast(ws, {
        type: "chat",
        name: attachment.name || "Guest",
        text
      });
      return;
    }

    // Hangup is followed by the socket closing; webSocketClose notifies the peer.
  }

  webSocketClose(ws, code, reason, wasClean) {
    const attachment = ws.deserializeAttachment() || {};
    if (attachment.rejected) return;
    this.broadcast(ws, { type: "peer-left" });
  }

  webSocketError(ws, error) {
    const attachment = ws.deserializeAttachment() || {};
    if (attachment.rejected) return;
    this.broadcast(ws, { type: "peer-left" });
  }

  broadcast(sender, payload) {
    for (const peer of this.ctx.getWebSockets()) {
      if (peer === sender) continue;
      this.safeSend(peer, payload);
    }
  }

  safeSend(ws, payload) {
    try {
      ws.send(JSON.stringify(payload));
    } catch {
      // The peer may have disconnected between enumeration and send.
    }
  }
}
JS

say "Checking JavaScript syntax"
node --check src/index.js || fail "The Worker code did not pass the JavaScript syntax check."

say "Checking Cloudflare login"
if ! npx --yes wrangler@latest whoami >/dev/null 2>&1; then
  echo "A Cloudflare browser login will open next. Finish it, then return here."
  npx --yes wrangler@latest login
fi

say "Deploying signaling service"
npx --yes wrangler@latest deploy

printf '\n==============================================\n'
printf 'SIGNALING WORKER DEPLOYED\n'
printf '==============================================\n'
printf 'Open the deploy output above and copy the workers.dev HTTPS URL.\n'
printf 'Test it by opening URL/health in a browser; it should say signaling is online.\n'
printf 'For Index.html use the same host with wss:// instead of https://.\n'
printf 'Example: https://name.account.workers.dev -> wss://name.account.workers.dev\n'
printf '\nWorker project files: %s\n' "$PROJECT_DIR"
