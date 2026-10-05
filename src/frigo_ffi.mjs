export * from "./ffi/ocr.mjs";
export * from "./ffi/sync.mjs";
export * from "./ffi/sharing.mjs";
export * from "./ffi/gestures.mjs";

export function clear_product_input() {
	const input = document.querySelector("#product-input");
	if (input) input.value = "";
}