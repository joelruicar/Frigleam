import { main } from "./build/dev/javascript/frigo/frigo.mjs";

function initVoiceInput() {
  document.addEventListener("click", (e) => {
    const btn = e.target.closest("#voice-input-btn");
    if (!btn) return;
    const SpeechRecognition =
      window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) {
      alert("El reconocimiento de voz no está disponible en este navegador.");
      return;
    }
    const recognition = new SpeechRecognition();
    recognition.lang = "es-ES";
    recognition.interimResults = false;
    recognition.maxAlternatives = 1;

    btn.classList.add("listening");
    recognition.onresult = (event) => {
      const transcript = event.results[0][0].transcript;
      const input = document.getElementById("product-input");
      if (input) {
        input.value = transcript;
        input.dispatchEvent(new Event("input", { bubbles: true }));
        input.focus();
      }
    };
    recognition.onerror = () => {
      btn.classList.remove("listening");
    };
    recognition.onend = () => {
      btn.classList.remove("listening");
    };
    recognition.start();
  });
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      main();
      initVoiceInput();
    });
  } else {
    main();
    initVoiceInput();
  }
}

