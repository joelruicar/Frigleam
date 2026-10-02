import { get_base_url } from "./sync.mjs";

let turnstile_resolve = null;
let turnstile_reject = null;
let turnstile_ready = null;

function set_turnstile_visibility(visible) {
  const container = document.getElementById("turnstile-widget");
  if (container) container.classList.toggle("turnstile-visible", visible);
}

export function get_file_from_input(event) {
  const input = event.target;
  return input?.files?.length ? input.files[0] : null;
}

export function is_null_file(file) {
  return file === null || file === undefined;
}

async function file_to_bitmap(file) {
  if (typeof window.createImageBitmap === "function") {
    try {
      return await window.createImageBitmap(file, { imageOrientation: "from-image" });
    } catch (_error) {}
  }
  return await new Promise((resolve, reject) => {
    const image = new Image();
    const object_url = URL.createObjectURL(file);
    image.onload = () => { URL.revokeObjectURL(object_url); resolve(image); };
    image.onerror = (error) => { URL.revokeObjectURL(object_url); reject(error); };
    image.src = object_url;
  });
}

function render_to_canvas(source, max_width) {
  const scale = Math.min(1, max_width / source.width);
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(source.width * scale));
  canvas.height = Math.max(1, Math.round(source.height * scale));
  const context = canvas.getContext("2d");
  if (!context) return source;
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";
  context.drawImage(source, 0, 0, canvas.width, canvas.height);
  return canvas;
}

async function canvas_to_blob(canvas, mime_type, quality) {
  return await new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob) resolve(blob);
      else reject(new Error("No se pudo generar la imagen comprimida."));
    }, mime_type, quality);
  });
}

async function scan_image_remote(file) {
  const custom_url = window.FRIGO_OCR_URL?.trim() ?? "";
  const endpoint = custom_url || `${get_base_url()}/api/ocr`;
  const source = render_to_canvas(await file_to_bitmap(file), 1400);
  const form_data = new FormData();
  form_data.append("file", await canvas_to_blob(source, "image/jpeg", 0.82), "ocr.jpg");
  const token = await get_turnstile_token();
  if (token) form_data.append("turnstile_token", token);
  const response = await fetch(endpoint, {
    method: "POST",
    body: form_data,
    credentials: "include",
  });
  if (!response.ok) throw new Error(`OCR falló con estado ${response.status}`);
  if ((response.headers.get("content-type") || "").includes("application/json")) {
    const data = await response.json();
    return String(data.text ?? data.ocr_text ?? "").trim();
  }
  return (await response.text()).trim();
}

async function get_turnstile_token() {
  const is_local = window.location.hostname === "localhost" || window.location.hostname === "127.0.0.1";
  const site_key = window.FRIGO_TURNSTILE_SITE_KEY?.trim() ?? "";
  if (!site_key) {
    if (is_local) return "";
    throw new Error("Falta configurar FRIGO_TURNSTILE_SITE_KEY");
  }

  try {
    await wait_for_turnstile();
  } catch (err) {
    if (is_local) return "";
    throw err;
  }

  const container = document.getElementById("turnstile-widget");
  if (!container) throw new Error("Falta el widget de Turnstile");

  if (window.frigo_turnstile_widget === undefined) {
    window.frigo_turnstile_widget = window.turnstile.render(container, {
      sitekey: site_key,
      size: "normal",
      appearance: "execute",
      callback: (token) => {
        set_turnstile_visibility(false);
        turnstile_resolve?.(token);
      },
      "error-callback": () => {
        set_turnstile_visibility(false);
        turnstile_reject?.(new Error("Turnstile rechazó la petición"));
      },
      "expired-callback": () => {
        set_turnstile_visibility(false);
        turnstile_reject?.(new Error("El token de Turnstile expiró"));
      },
    });
  }

  return await new Promise((resolve, reject) => {
    set_turnstile_visibility(true);
    turnstile_resolve = resolve;
    turnstile_reject = reject;
    window.turnstile.reset(window.frigo_turnstile_widget);
    window.turnstile.execute(window.frigo_turnstile_widget, { action: "ocr" });
  });
}

function wait_for_turnstile() {
  if (window.turnstile) return Promise.resolve();
  if (turnstile_ready) return turnstile_ready;

  turnstile_ready = new Promise((resolve, reject) => {
    const deadline = Date.now() + 10000;
    const check = () => {
      if (window.turnstile) {
        resolve();
      } else if (Date.now() >= deadline) {
        reject(new Error("Turnstile no se pudo cargar"));
      } else {
        setTimeout(check, 100);
      }
    };
    check();
  });

  return turnstile_ready;
}

export async function scan_image(file, dispatch, dispatch_error) {
  try {
    const text = await scan_image_remote(file);
    if (text) { dispatch(text); return; }
  } catch (error) {
    console.warn("Workers AI OCR falló, intentando fallback:", error);
  }
  if (typeof window.Tesseract !== "undefined") {
    try {
      const source = render_to_canvas(await file_to_bitmap(file), 1800);
      const { data } = await window.Tesseract.recognize(source, "spa+eng", {
        tessedit_pageseg_mode: "6",
        preserve_interword_spaces: "1",
        user_defined_dpi: "300",
      });
      dispatch((data.text || "").trim());
      return;
    } catch (error) {
      console.error("Error en fallback Tesseract:", error);
    }
  }
  dispatch_error("No se pudo leer la imagen. Comprueba la conexión e inténtalo de nuevo.");
}