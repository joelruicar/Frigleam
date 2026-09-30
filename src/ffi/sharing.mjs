import QRCode from "qrcode";
import { get_access_token } from "./sync.mjs";

export function get_share_link(room_id) {
  const url = new URL(window.location.href);
  url.searchParams.set("list", room_id);
  url.searchParams.set("access", get_access_token(room_id));
  url.hash = "";
  return url.toString();
}

export function copy_to_clipboard(text) {
  if (navigator.clipboard?.writeText) { navigator.clipboard.writeText(text).catch(() => {}); return; }
  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();
  try { document.execCommand("copy"); } catch (_error) {}
  textarea.remove();
}

export function share_room_link(room_id) {
  const link = get_share_link(room_id);
  if (navigator.share) {
    navigator.share({ title: "Frigo - Lista de la compra", text: `¡Únete a la lista compartida "${room_id}" en Frigo!`, url: link }).catch(() => {});
    return true;
  }
  copy_to_clipboard(link);
  return false;
}

export function render_qr_code(element_id, text) {
  setTimeout(() => {
    const container = document.getElementById(element_id);
    if (!container) return;
    QRCode.toString(text, { type: "svg", margin: 1, width: 190, color: { dark: "#292D3E", light: "#FAF7F0" } })
      .then((svg) => { container.innerHTML = svg; })
      .catch((error) => console.error("Error al generar código QR:", error));
  }, 50);
}