import { DurableObject } from "cloudflare:workers";

const MAX_OCR_BYTES = 5 * 1024 * 1024;
const ALLOWED_IMAGE_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
const ALLOWED_ORIGINS = new Set([
  "https://frigo.frigleam.workers.dev",
  "http://localhost:8787",
]);
const OCR_SESSION_TTL_SECONDS = 24 * 60 * 60;

function cors_headers(request) {
  const origin = request.headers.get("Origin");
  const headers = new Headers();
  if (origin && ALLOWED_ORIGINS.has(origin)) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Vary", "Origin");
  }
  return headers;
}

function json_response(request, body, status = 200, extra_headers = {}) {
  const headers = cors_headers(request);
  headers.set("Content-Type", "application/json");
  for (const [key, value] of Object.entries(extra_headers)) headers.set(key, value);
  return new Response(JSON.stringify(body), { status, headers });
}

function get_cookie(request, name) {
  const cookies = request.headers.get("Cookie") || "";
  const match = cookies.match(new RegExp(`(?:^|;\\s*)${name}=([^;]*)`));
  return match ? decodeURIComponent(match[1]) : "";
}

function encode_base64url(bytes) {
  let binary = "";
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sign_ocr_session(expires_at, env) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.TURNSTILE_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(String(expires_at)),
  );
  return `${expires_at}.${encode_base64url(signature)}`;
}

async function has_valid_ocr_session(request, env) {
  const value = get_cookie(request, "frigo_ocr_session");
  const [expires_at, signature] = value.split(".");
  if (!expires_at || !signature || Number(expires_at) <= Math.floor(Date.now() / 1000)) {
    return false;
  }
  const expected = await sign_ocr_session(Number(expires_at), env);
  return expected === value;
}

async function ocr_session_cookie(env) {
  const expires_at = Math.floor(Date.now() / 1000) + OCR_SESSION_TTL_SECONDS;
  const value = await sign_ocr_session(expires_at, env);
  return `frigo_ocr_session=${encodeURIComponent(value)}; Max-Age=${OCR_SESSION_TTL_SECONDS}; Path=/api/ocr; HttpOnly; Secure; SameSite=Lax`;
}

function is_valid_image_bytes(bytes, type) {
  if (!ALLOWED_IMAGE_TYPES.has(type)) return false;
  if (type === "image/jpeg") return bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (type === "image/png") return bytes.slice(0, 8).every((value, index) => value === [137, 80, 78, 71, 13, 10, 26, 10][index]);
  return String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" && String.fromCharCode(...bytes.slice(8, 12)) === "WEBP";
}

function apply_delta(items, delta) {
  if (!delta || typeof delta.type !== "string") return null;
  if (delta.type === "item_deleted" && typeof delta.id === "string") {
    return items.filter((item) => item.id !== delta.id);
  }
  if ((delta.type === "item_added" || delta.type === "item_updated") && delta.item) {
    const item = delta.item;
    if (typeof item.id !== "string" || typeof item.name !== "string") return null;
    const without_item = items.filter((existing) => existing.id !== item.id);
    return delta.type === "item_added" ? [...without_item, item] : [...without_item, item];
  }
  if (delta.type === "list_cleared") return [];
  return null;
}

async function verify_turnstile(request, token, env) {
  if (!env.TURNSTILE_SECRET || !token) return false;
  const response = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      secret: env.TURNSTILE_SECRET,
      response: token,
      remoteip: request.headers.get("CF-Connecting-IP"),
    }),
  });
  const result = await response.json();
  return result.success === true;
}

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
    const access_token = url.searchParams.get("access") || "";
    const stored_access_token = await this.ctx.storage.get("access_token");

    if (!stored_access_token) {
      if (!access_token || access_token.length < 32) {
        return new Response("Room access token required", { status: 401 });
      }
      await this.ctx.storage.put("access_token", access_token);
    } else if (access_token !== stored_access_token) {
      return new Response("Invalid room access token", { status: 403 });
    }

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
        if (body.delta) {
          const current = (await this.ctx.storage.get("items")) || [];
          const updated = apply_delta(current, body.delta);
          if (!updated) return Response.json({ error: "Invalid delta" }, { status: 400 });
          await this.ctx.storage.put("items", updated);
          this.broadcast(JSON.stringify({ type: "sync", items: updated }));
          return Response.json({ success: true, count: updated.length });
        }
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
      } else if (data.type === "delta") {
        const current = (await this.ctx.storage.get("items")) || [];
        const updated = apply_delta(current, data.delta);
        if (!updated) return;
        await this.ctx.storage.put("items", updated);
        this.broadcast(JSON.stringify({ type: "sync", items: updated }), ws);
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
        const headers = cors_headers(request);
        headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
        headers.set("Access-Control-Allow-Headers", "Content-Type");
        return new Response(null, { headers });
      }

      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405 });
      }

      try {
        const is_local_request = new URL(request.url).hostname === "localhost" ||
          new URL(request.url).hostname === "127.0.0.1";
        if (!is_local_request && (!env.OCR_RATE_LIMITER || !env.TURNSTILE_SECRET)) {
          return json_response(request, { error: "OCR no está configurado de forma segura" }, 503);
        }

        const ip = request.headers.get("CF-Connecting-IP") || "unknown";
        const rate = is_local_request
          ? { success: true }
          : await env.OCR_RATE_LIMITER.limit({ key: ip });
        if (!rate.success) {
          return json_response(request, { error: "Demasiadas peticiones OCR" }, 429, {
            "Retry-After": "60",
          });
        }

        const contentLength = Number(request.headers.get("content-length") || 0);
        if (contentLength > MAX_OCR_BYTES) {
          return json_response(request, { error: "La imagen supera el límite de 5 MB" }, 413);
        }

        let imageBuffer;
        const contentType = request.headers.get("content-type") || "";
        let imageType;
        let turnstileToken;

        if (contentType.includes("multipart/form-data")) {
          const formData = await request.formData();
          const file = formData.get("file");
          if (!file || typeof file.arrayBuffer !== "function") {
            return json_response(request, { error: "No se encontró el archivo de imagen" }, 400);
          }
          imageType = file.type;
          turnstileToken = formData.get("turnstile_token");
          imageBuffer = await file.arrayBuffer();
        } else {
          return json_response(request, { error: "Se esperaba multipart/form-data" }, 415);
        }

        if (imageBuffer.byteLength === 0 || imageBuffer.byteLength > MAX_OCR_BYTES) {
          return json_response(request, { error: "La imagen supera el límite de 5 MB" }, 413);
        }
        const bytes = new Uint8Array(imageBuffer.slice(0, 12));
        if (!is_valid_image_bytes(bytes, imageType)) {
          return json_response(request, { error: "Tipo de imagen no permitido" }, 415);
        }
        const has_session = await has_valid_ocr_session(request, env);
        if (!has_session && !is_local_request && !(await verify_turnstile(request, turnstileToken, env))) {
          return json_response(request, { error: "Verificación Turnstile inválida" }, 403);
        }
        if (!env.AI) {
          return json_response(request, { error: "Workers AI no está configurado" }, 500);
        }

        const text = await runVisionOcr(env, imageBuffer);
        const headers = has_session
          ? {}
          : { "Set-Cookie": await ocr_session_cookie(env) };
        return json_response(request, { text }, 200, headers);
      } catch (err) {
        console.error("Error en /api/ocr:", err);
        return json_response(request, { error: err.message || "Error procesando OCR" }, 500);
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
