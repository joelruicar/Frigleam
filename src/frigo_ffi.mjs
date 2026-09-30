// frigo_ffi.mjs
// Funciones JS usadas por frigo.gleam vía @external(javascript, ...)
import QRCode from "qrcode";

export function get_file_from_input(event) {
  const input = event.target;
  if (input && input.files && input.files.length > 0) {
    return input.files[0];
  }
  return null;
}

export function is_null_file(file) {
  return file === null || file === undefined;
}

async function file_to_bitmap(file) {
  if (typeof window.createImageBitmap === "function") {
    try {
      return await window.createImageBitmap(file, { imageOrientation: "from-image" });
    } catch (_error) {
      // Fall back to a regular image element.
    }
  }

  return await new Promise((resolve, reject) => {
    const image = new Image();
    const object_url = URL.createObjectURL(file);

    image.onload = () => {
      URL.revokeObjectURL(object_url);
      resolve(image);
    };

    image.onerror = (error) => {
      URL.revokeObjectURL(object_url);
      reject(error);
    };

    image.src = object_url;
  });
}

function is_mobile_like_device() {
  const has_small_screen =
    typeof window.matchMedia === "function" &&
    window.matchMedia("(max-width: 900px)").matches;
  const has_touch = typeof navigator !== "undefined" && navigator.maxTouchPoints > 0;
  const prefers_data_saving =
    typeof navigator !== "undefined" &&
    navigator.connection &&
    navigator.connection.saveData;

  return Boolean(has_small_screen || has_touch || prefers_data_saving);
}

function get_remote_ocr_url() {
  const url = window.FRIGO_OCR_URL;
  return typeof url === "string" ? url.trim() : "";
}

function should_use_remote_ocr() {
  return get_remote_ocr_url() !== "" && is_mobile_like_device();
}

function render_to_canvas(source, max_width) {
  const scale = Math.min(1, max_width / source.width);
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(source.width * scale));
  canvas.height = Math.max(1, Math.round(source.height * scale));

  const context = canvas.getContext("2d");
  if (!context) {
    return source;
  }

  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";
  context.drawImage(source, 0, 0, canvas.width, canvas.height);

  return canvas;
}

function preprocess_image(source) {
  return render_to_canvas(source, 1800);
}

async function canvas_to_blob(canvas, mime_type, quality) {
  return await new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob) {
        resolve(blob);
      } else {
        reject(new Error("No se pudo generar la imagen comprimida."));
      }
    }, mime_type, quality);
  });
}

async function build_mobile_upload(file) {
  const source = await file_to_bitmap(file);
  const canvas = render_to_canvas(source, 1400);
  return await canvas_to_blob(canvas, "image/jpeg", 0.82);
}

async function scan_image_remote(file) {
  const customUrl = window.FRIGO_OCR_URL ? window.FRIGO_OCR_URL.trim() : "";
  const endpoint = customUrl !== "" ? customUrl : `${get_base_url()}/api/ocr`;

  const form_data = new FormData();
  form_data.append("file", await build_mobile_upload(file), "ocr.jpg");

  const response = await fetch(endpoint, {
    method: "POST",
    body: form_data,
  });

  if (!response.ok) {
    const errorText = await response.text().catch(() => "");
    throw new Error(`OCR falló con estado ${response.status}: ${errorText}`);
  }

  const content_type = response.headers.get("content-type") || "";
  if (content_type.includes("application/json")) {
    const data = await response.json();
    return String(data.text ?? data.ocr_text ?? "").trim();
  }

  return (await response.text()).trim();
}

export async function scan_image(file, dispatch) {
  // 1. Intento primario con Cloudflare Workers AI (/api/ocr)
  try {
    const text = await scan_image_remote(file);
    if (text && text.trim() !== "") {
      dispatch(text);
      return;
    }
  } catch (err) {
    console.warn("Workers AI OCR falló, intentando fallback:", err);
  }

  // 2. Fallback a Tesseract local si está cargado
  if (typeof window.Tesseract !== "undefined") {
    try {
      const source = preprocess_image(await file_to_bitmap(file));
      const { data } = await window.Tesseract.recognize(source, "spa+eng", {
        tessedit_pageseg_mode: "6",
        preserve_interword_spaces: "1",
        user_defined_dpi: "300",
      });
      dispatch((data.text || "").trim());
      return;
    } catch (err) {
      console.error("Error en fallback Tesseract:", err);
    }
  }

  dispatch("");
}

// =============================================================================
// Real-time Collaborative Synchronization (WebSockets & Cloudflare Workers)
// =============================================================================

let active_ws = null;
let reconnect_timer = null;
let current_room_id = "";
let remote_sync_callback = null;
let status_change_callback = null;

export function sanitize_room_id(value) {
  return String(value).trim().toLowerCase().replace(/[^a-z0-9_-]/g, "");
}

export function random_room_id() {
  const chars = "abcdefghjkmnpqrstuvwxyz23456789";
  let result = "frigo-";
  for (let i = 0; i < 4; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}

export function get_active_room_id() {
  // 1. Query parameter ?list=xyz
  const params = new URLSearchParams(window.location.search);
  const fromQuery = sanitize_room_id(params.get("list") ?? "");
  if (fromQuery) {
    localStorage.setItem("frigo_active_room", fromQuery);
    return fromQuery;
  }

  // 2. Hash #list/xyz or #xyz
  if (window.location.hash) {
    const cleanHash = sanitize_room_id(
      window.location.hash.replace(/^#\/?(list\/)?/, ""),
    );
    if (cleanHash) {
      localStorage.setItem("frigo_active_room", cleanHash);
      return cleanHash;
    }
  }

  // 3. Stored room in localStorage
  const stored = sanitize_room_id(localStorage.getItem("frigo_active_room") ?? "");
  if (stored) {
    return stored;
  }

  // 4. Generate new friendly room ID
  const newId = random_room_id();
  localStorage.setItem("frigo_active_room", newId);
  try {
    const url = new URL(window.location.href);
    url.searchParams.set("list", newId);
    window.history.replaceState({}, "", url.toString());
  } catch (_e) {}

  return newId;
}

export function set_active_room_id(roomId) {
  const clean = sanitize_room_id(roomId);
  if (!clean) return;

  localStorage.setItem("frigo_active_room", clean);

  try {
    const url = new URL(window.location.href);
    url.searchParams.set("list", clean);
    window.history.pushState({}, "", url.toString());
  } catch (_e) {}
}

function get_base_url() {
  if (window.FRIGO_API_URL) {
    return window.FRIGO_API_URL.replace(/\/$/, "");
  }
  return `${window.location.protocol}//${window.location.host}`;
}

function connect_socket() {
  if (reconnect_timer) {
    clearTimeout(reconnect_timer);
    reconnect_timer = null;
  }

  if (active_ws) {
    try {
      active_ws.onclose = null;
      active_ws.onerror = null;
      active_ws.close();
    } catch (_e) {}
    active_ws = null;
  }

  if (!current_room_id) {
    return;
  }

  const baseUrl = get_base_url();
  const wsProtocol = baseUrl.startsWith("https") ? "wss:" : "ws:";
  const host = baseUrl.replace(/^https?:\/\//, "");
  const wsUrl = `${wsProtocol}//${host}/api/room/${encodeURIComponent(current_room_id)}/websocket`;

  try {
    const ws = new WebSocket(wsUrl);
    active_ws = ws;

    ws.onopen = () => {
      if (status_change_callback) {
        status_change_callback(true);
      }
    };

    ws.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        if (data.type === "sync" && Array.isArray(data.items)) {
          if (remote_sync_callback) {
            remote_sync_callback(data.items);
          }
        }
      } catch (err) {
        console.error("Error al procesar mensaje WebSocket:", err);
      }
    };

    ws.onclose = () => {
      if (status_change_callback) {
        status_change_callback(false);
      }
      schedule_reconnect();
    };

    ws.onerror = () => ws.close();
  } catch (e) {
    console.error("Error conectando WebSocket:", e);
    schedule_reconnect();
  }
}

function schedule_reconnect() {
  if (!reconnect_timer) {
    reconnect_timer = setTimeout(() => {
      reconnect_timer = null;
      connect_socket();
    }, 3000);
  }
}

export function start_sync(roomId, onRemoteSync, onStatusChange) {
  current_room_id = roomId;
  remote_sync_callback = onRemoteSync;
  status_change_callback = onStatusChange;

  connect_socket();

  // Also do initial fetch via HTTP in case WebSocket takes time
  const baseUrl = get_base_url();
  fetch(`${baseUrl}/api/room/${encodeURIComponent(roomId)}`)
    .then((res) => (res.ok ? res.json() : null))
    .then((data) => {
      if (data && Array.isArray(data.items) && data.items.length > 0) {
        if (remote_sync_callback) {
          remote_sync_callback(data.items);
        }
      }
    })
    .catch(() => {});
}

export function broadcast_items_json(json) {
  if (active_ws && active_ws.readyState === WebSocket.OPEN) {
    active_ws.send(`{"type":"set_items","items":${json}}`);
    return;
  }

  // Socket down: fall back to HTTP so the change still reaches the server.
  fetch(`${get_base_url()}/api/room/${encodeURIComponent(current_room_id)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: `{"items":${json}}`,
  }).catch(() => {});
}

export function get_share_link(roomId) {
  const url = new URL(window.location.href);
  url.searchParams.set("list", roomId);
  url.hash = "";
  return url.toString();
}

export function copy_to_clipboard(text) {
  navigator.clipboard?.writeText(text).catch(() => {});
}

export function share_room_link(roomId) {
  const link = get_share_link(roomId);
  if (navigator.share) {
    navigator
      .share({
        title: "Frigo - Lista de la compra",
        text: `¡Únete a la lista compartida "${roomId}" en Frigo!`,
        url: link,
      })
      .catch(() => {});
  } else {
    copy_to_clipboard(link);
  }
}

export function render_qr_code(elementId, text) {
  setTimeout(() => {
    const container = document.getElementById(elementId);
    if (!container) return;

    QRCode.toString(text, {
      type: "svg",
      margin: 1,
      width: 190,
      color: {
        dark: "#292D3E",
        light: "#FAF7F0",
      },
    })
      .then((svg) => {
        container.innerHTML = svg;
      })
      .catch((err) => {
        console.error("Error al generar código QR:", err);
      });
  }, 50);
}

let swipe_listener_enabled = false;

export function enable_swipe_to_delete(onSwipe) {
  if (swipe_listener_enabled) return;
  swipe_listener_enabled = true;

  let gesture = null;
  let suppress_click = false;

  document.addEventListener("pointerdown", (event) => {
    const item = event.target.closest?.("[data-swipe-item]");
    if (!item || event.button !== 0) return;

    gesture = {
      item,
      startX: event.clientX,
      startY: event.clientY,
      moved: false,
    };
  });

  document.addEventListener("pointermove", (event) => {
    if (!gesture) return;

    const deltaX = event.clientX - gesture.startX;
    const deltaY = event.clientY - gesture.startY;

    if (!gesture.moved && Math.abs(deltaY) > Math.abs(deltaX)) {
      gesture = null;
      return;
    }

    if (deltaX <= 0) return;

    gesture.moved = true;
    gesture.item.classList.add("swiping");
    gesture.item.style.setProperty("--swipe-distance", `${deltaX}px`);
  });

  document.addEventListener("pointerup", (event) => {
    if (!gesture) return;

    const { item, startX, startY, moved } = gesture;
    gesture = null;
    const deltaX = event.clientX - startX;
    const deltaY = event.clientY - startY;

    if (!moved || deltaX <= 0 || Math.abs(deltaX) <= Math.abs(deltaY)) {
      item.classList.remove("swiping");
      item.style.removeProperty("--swipe-distance");
      return;
    }

    suppress_click = true;
    const threshold = Math.min(180, item.offsetWidth * 0.45);

    if (deltaX >= threshold) {
      item.classList.remove("swiping");
      item.classList.add("swipe-confirmed");
      item.style.setProperty("--swipe-distance", `${item.offsetWidth}px`);
      setTimeout(() => {
        onSwipe(item.getAttribute("data-swipe-item"));
      }, 180);
    } else {
      item.classList.remove("swiping");
      item.classList.add("swipe-cancelled");
      item.style.removeProperty("--swipe-distance");
      setTimeout(() => {
        item.classList.remove("swipe-cancelled");
      }, 220);
    }

    setTimeout(() => {
      suppress_click = false;
    }, 300);
  });

  document.addEventListener("pointercancel", () => {
    gesture = null;
  });

  document.addEventListener(
    "click",
    (event) => {
      if (!suppress_click) return;
      event.preventDefault();
      event.stopPropagation();
      suppress_click = false;
    },
    true,
  );
}
