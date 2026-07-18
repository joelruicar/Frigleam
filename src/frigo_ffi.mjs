// frigo_ffi.mjs
// Funciones JS usadas por frigo.gleam vía @external(javascript, ...)
//
// Requiere que Tesseract.js esté cargado globalmente antes de que
// esta app arranque. Añade esto en tu index.html, antes de tu <script>
// que carga el bundle compilado de Gleam:
//
//   <script src="https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js"></script>

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

export function scan_image(file, dispatch) {
  if (typeof window.Tesseract === "undefined") {
    console.error(
      "Tesseract.js no está cargado. Añade el <script> en index.html.",
    );
    dispatch("");
    return;
  }

  window.Tesseract.recognize(file, "spa")
    .then(({ data }) => {
      dispatch(data.text);
    })
    .catch((err) => {
      console.error("Error al escanear la imagen:", err);
      dispatch("");
    });
}
