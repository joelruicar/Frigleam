let enabled = false;

export function enable_swipe_to_delete(on_swipe) {
  if (enabled) return;
  enabled = true;
  let gesture = null;
  let suppress_click = false;
  document.addEventListener("pointerdown", (event) => {
    const item = event.target.closest?.("[data-swipe-item]");
    if (!item || event.button !== 0) return;
    gesture = { item, start_x: event.clientX, start_y: event.clientY, moved: false };
  });
  document.addEventListener("pointermove", (event) => {
    if (!gesture) return;
    const delta_x = event.clientX - gesture.start_x;
    const delta_y = event.clientY - gesture.start_y;
    if (!gesture.moved && Math.abs(delta_y) > Math.abs(delta_x)) { gesture = null; return; }
    if (delta_x <= 0) return;
    gesture.moved = true;
    gesture.item.classList.add("swiping");
    gesture.item.style.setProperty("--swipe-distance", `${delta_x}px`);
  });
  document.addEventListener("pointerup", (event) => {
    if (!gesture) return;
    const { item, start_x, start_y, moved } = gesture;
    gesture = null;
    const delta_x = event.clientX - start_x;
    const delta_y = event.clientY - start_y;
    if (!moved || delta_x <= 0 || Math.abs(delta_x) <= Math.abs(delta_y)) {
      item.classList.remove("swiping");
      item.style.removeProperty("--swipe-distance");
      return;
    }
    suppress_click = true;
    const threshold = Math.min(180, item.offsetWidth * 0.45);
    if (delta_x >= threshold) {
      item.classList.remove("swiping");
      item.classList.add("swipe-confirmed");
      item.style.setProperty("--swipe-distance", `${item.offsetWidth}px`);
      setTimeout(() => on_swipe(item.getAttribute("data-swipe-item")), 180);
    } else {
      item.classList.remove("swiping");
      item.classList.add("swipe-cancelled");
      item.style.removeProperty("--swipe-distance");
      setTimeout(() => item.classList.remove("swipe-cancelled"), 220);
    }
    setTimeout(() => { suppress_click = false; }, 300);
  });
  document.addEventListener("pointercancel", () => { gesture = null; });
  document.addEventListener("click", (event) => {
    if (!suppress_click) return;
    event.preventDefault();
    event.stopPropagation();
    suppress_click = false;
  }, true);
}