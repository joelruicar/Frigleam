import { main } from "./build/dev/javascript/frigo/frigo.mjs";

if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => main());
  } else {
    main();
  }
}
