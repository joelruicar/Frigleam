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

async function runVisionOcr(env, imageBuffer) {
  const prompt = `You are a shopping list OCR assistant. Read all shopping list items handwritten or printed in this image.
For each item, output the item name and amount on a new line (format: Name Quantity).
Example:
Leche 2
Manzanas 3
Pan 1
Huevos 12

Rules:
- Capitalize the first letter of each item.
- If no quantity is specified, write 1 (e.g. "Arroz 1").
- Do NOT output bullet points, numbering, asterisks, markdown, or greetings.
- Output ONLY the item lines.`;

  const byteList = [...new Uint8Array(imageBuffer)];
  const errors = [];

  // 1. Try Llama 3.2 11B Vision
  try {
    const res = await env.AI.run("@cf/meta/llama-3.2-11b-vision-instruct", {
      prompt,
      image: byteList,
      max_tokens: 512,
    });
    if (res && res.response && res.response.trim() !== "") {
      return res.response.trim();
    }
  } catch (err) {
    const errStr = String(err.message || err);
    errors.push(`Llama 3.2: ${errStr}`);

    // If Meta license agreement is required, agree and retry
    if (
      errStr.toLowerCase().includes("agree") ||
      errStr.toLowerCase().includes("license") ||
      errStr.toLowerCase().includes("terms")
    ) {
      try {
        await env.AI.run("@cf/meta/llama-3.2-11b-vision-instruct", { prompt: "agree" });
        const resRetry = await env.AI.run("@cf/meta/llama-3.2-11b-vision-instruct", {
          prompt,
          image: byteList,
          max_tokens: 512,
        });
        if (resRetry && resRetry.response && resRetry.response.trim() !== "") {
          return resRetry.response.trim();
        }
      } catch (retryErr) {
        errors.push(`Llama 3.2 retry: ${retryErr.message || String(retryErr)}`);
      }
    }
  }

  // 2. Try LLaVA 1.5 7B HF (open vision model, no license agreement needed)
  try {
    const res = await env.AI.run("@cf/llava-hf/llava-1.5-7b-hf", {
      prompt,
      image: byteList,
      max_tokens: 512,
    });
    if (res && (res.description || res.response)) {
      const text = (res.description || res.response).trim();
      if (text !== "") return text;
    }
  } catch (err2) {
    errors.push(`LLaVA 1.5: ${err2.message || String(err2)}`);
  }

  // 3. Fallback to uform-gen2-qwen-500m
  try {
    const res = await env.AI.run("@cf/unum/uform-gen2-qwen-500m", {
      prompt,
      image: byteList,
    });
    if (res && (res.description || res.response)) {
      const text = (res.description || res.response).trim();
      if (text !== "") return text;
    }
  } catch (err3) {
    errors.push(`UForm: ${err3.message || String(err3)}`);
  }

  throw new Error(`Workers AI falló: ${errors.join(" | ")}`);
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

    // OCR API endpoint: /api/ocr powered by Cloudflare Workers AI
    if (url.pathname === "/api/ocr") {
      if (request.method === "OPTIONS") {
        return new Response(null, {
          headers: {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
          },
        });
      }

      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405 });
      }

      try {
        let imageBuffer;
        const contentType = request.headers.get("content-type") || "";

        if (contentType.includes("multipart/form-data")) {
          const formData = await request.formData();
          const file = formData.get("file");
          if (!file) {
            return Response.json(
              { error: "No se encontró el archivo de imagen" },
              { status: 400, headers: { "Access-Control-Allow-Origin": "*" } }
            );
          }
          imageBuffer = await file.arrayBuffer();
        } else {
          imageBuffer = await request.arrayBuffer();
        }

        if (!env.AI) {
          return Response.json(
            { error: "Workers AI no está configurado en el Worker" },
            { status: 500, headers: { "Access-Control-Allow-Origin": "*" } }
          );
        }

        const text = await runVisionOcr(env, imageBuffer);
        return Response.json(
          { text },
          {
            headers: {
              "Access-Control-Allow-Origin": "*",
            },
          }
        );
      } catch (err) {
        console.error("Error en /api/ocr:", err);
        return Response.json(
          { error: err.message || "Error procesando OCR" },
          {
            status: 500,
            headers: {
              "Access-Control-Allow-Origin": "*",
            },
          }
        );
      }
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
