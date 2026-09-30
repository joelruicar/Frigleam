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
  for (let index = 0; index < 4; index += 1) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}

export function get_active_room_id() {
  const params = new URLSearchParams(window.location.search);
  const from_query = sanitize_room_id(params.get("list") ?? "");
  if (from_query) { localStorage.setItem("frigo_active_room", from_query); return from_query; }
  if (window.location.hash) {
    const clean_hash = sanitize_room_id(window.location.hash.replace(/^#\/?(list\/)?/, ""));
    if (clean_hash) { localStorage.setItem("frigo_active_room", clean_hash); return clean_hash; }
  }
  const stored = sanitize_room_id(localStorage.getItem("frigo_active_room") ?? "");
  if (stored) return stored;
  const new_id = random_room_id();
  localStorage.setItem("frigo_active_room", new_id);
  const url = new URL(window.location.href);
  url.searchParams.set("list", new_id);
  window.history.replaceState({}, "", url.toString());
  return new_id;
}

export function set_active_room_id(room_id) {
  const clean = sanitize_room_id(room_id);
  if (!clean) return;
  localStorage.setItem("frigo_active_room", clean);
  const url = new URL(window.location.href);
  url.searchParams.set("list", clean);
  window.history.pushState({}, "", url.toString());
}

export function get_base_url() {
  return (window.FRIGO_API_URL || window.location.origin).replace(/\/$/, "");
}

function schedule_reconnect() {
  if (reconnect_timer) return;
  reconnect_timer = setTimeout(() => { reconnect_timer = null; connect_socket(); }, 3000);
}

function connect_socket() {
  if (reconnect_timer) { clearTimeout(reconnect_timer); reconnect_timer = null; }
  active_ws?.close();
  active_ws = null;
  if (!current_room_id) return;
  const base_url = get_base_url();
  const protocol = base_url.startsWith("https") ? "wss:" : "ws:";
  const host = base_url.replace(/^https?:\/\//, "");
  const url = `${protocol}//${host}/api/room/${encodeURIComponent(current_room_id)}/websocket`;
  try {
    const socket = new WebSocket(url);
    active_ws = socket;
    socket.onopen = () => status_change_callback?.(true);
    socket.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        if (data.type === "sync" && Array.isArray(data.items)) remote_sync_callback?.(data.items);
      } catch (error) { console.error("Error al procesar mensaje WebSocket:", error); }
    };
    socket.onclose = () => { status_change_callback?.(false); schedule_reconnect(); };
    socket.onerror = () => socket.close();
  } catch (error) { console.error("Error conectando WebSocket:", error); schedule_reconnect(); }
}

export function start_sync(room_id, on_remote_sync, on_status_change) {
  current_room_id = room_id;
  remote_sync_callback = on_remote_sync;
  status_change_callback = on_status_change;
  connect_socket();
  fetch(`${get_base_url()}/api/room/${encodeURIComponent(room_id)}`)
    .then((response) => response.ok ? response.json() : null)
    .then((data) => {
      if (room_id === current_room_id && Array.isArray(data?.items)) remote_sync_callback?.(data.items);
    })
    .catch(() => {});
}

export function broadcast_items_json(json) {
  try {
    const items = JSON.parse(json);
    const payload = JSON.stringify({ type: "set_items", items });
    if (active_ws?.readyState === WebSocket.OPEN) { active_ws.send(payload); return; }
    fetch(`${get_base_url()}/api/room/${encodeURIComponent(current_room_id)}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ items }),
    }).catch(() => {});
  } catch (error) { console.error("No se pudieron emitir los artículos:", error); }
}