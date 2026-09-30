import { DurableObject } from "cloudflare:workers";

/**
 * ShoppingListRoom
 * Durable Object that manages state and WebSocket connections for a single shopping list room.
 * Uses the WebSocket Hibernation API so idle connections cost 0 compute.
 */
export class ShoppingListRoom extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);

    // WebSocket upgrade
    if (request.headers.get("Upgrade") === "websocket") {
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);

      // Accept websocket with Hibernation API
      this.ctx.acceptWebSocket(server);

      // Load stored items from SQLite storage
      const items = (await this.ctx.storage.get("items")) || [];

      // Send initial state to the newly connected client
      server.send(JSON.stringify({ type: "sync", items }));

      return new Response(null, { status: 101, webSocket: client });
    }

    // HTTP GET: retrieve list state
    if (request.method === "GET") {
      const items = (await this.ctx.storage.get("items")) || [];
      return Response.json(
        { items },
        {
          headers: {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
          },
        }
      );
    }

    // HTTP POST: update list state (HTTP fallback if WebSockets fail)
    if (request.method === "POST") {
      try {
        const body = await request.json();
        if (Array.isArray(body.items)) {
          await this.ctx.storage.put("items", body.items);
          this.broadcast(JSON.stringify({ type: "sync", items: body.items }));
          return Response.json(
            { success: true, count: body.items.length },
            {
              headers: {
                "Access-Control-Allow-Origin": "*",
              },
            }
          );
        }
      } catch (e) {
        return Response.json({ error: "Invalid JSON" }, { status: 400 });
      }
      return Response.json({ error: "Invalid payload" }, { status: 400 });
    }

    // CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type",
        },
      });
    }

    return new Response("Method not allowed", { status: 405 });
  }

  async webSocketMessage(ws, message) {
    try {
      const text = typeof message === "string" ? message : new TextDecoder().decode(message);
      const data = JSON.parse(text);

      if (data.type === "set_items" && Array.isArray(data.items)) {
        // Persist items
        await this.ctx.storage.put("items", data.items);

        // Broadcast to all other connected clients in this room
        this.broadcast(JSON.stringify({ type: "sync", items: data.items }), ws);
      } else if (data.type === "ping") {
        ws.send(JSON.stringify({ type: "pong" }));
      }
    } catch (err) {
      console.error("Error processing WebSocket message:", err);
    }
  }

  broadcast(message, senderWs = null) {
    for (const client of this.ctx.getWebSockets()) {
      if (client !== senderWs) {
        try {
          client.send(message);
        } catch (_err) {
          // Socket might be closed
        }
      }
    }
  }

  async webSocketClose(ws, code, reason) {
    ws.close(code, reason);
  }

  async webSocketError(ws, error) {
    ws.close(1011, "WebSocket error");
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // API routing: /api/room/:roomId or /api/room/:roomId/websocket
    if (url.pathname.startsWith("/api/room/")) {
      const segments = url.pathname.split("/").filter(Boolean);
      // segments: ["api", "room", "<roomId>", ...]
      const rawRoomId = segments[2] || "general";
      const roomId = rawRoomId.toLowerCase().replace(/[^a-z0-9_-]/g, "");

      if (!roomId) {
        return new Response("Invalid room ID", { status: 400 });
      }

      const id = env.SHOPPING_ROOMS.idFromName(roomId);
      const room = env.SHOPPING_ROOMS.get(id);

      return room.fetch(request);
    }

    // Health check endpoint
    if (url.pathname === "/api/health") {
      return Response.json({ status: "ok", time: new Date().toISOString() });
    }

    // Serve static frontend assets
    if (env.ASSETS) {
      return env.ASSETS.fetch(request);
    }

    return new Response("Not found", { status: 404 });
  },
};
