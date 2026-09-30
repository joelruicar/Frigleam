# 🛒 frigo

Lista de la compra colaborativa en tiempo real construida con **Gleam**, **Lustre** y backend serverless en **Cloudflare Workers**.

Permite que varias personas compartan y editen la misma lista simultáneamente desde el móvil mediante enlace de invitación o escaneo de código QR, con soporte para escaneo OCR de listas escritas en papel.

---

## ✨ Características

- ⚡ **Tiempo real multiusuario**: Sincronización instantánea con WebSockets mediante Cloudflare Durable Objects (WebSocket Hibernation API para coste 0€ en reposo).
- 📲 **PWA Móvil instalable**: Modo *standalone*, iconos nativos, diseño táctil y soporte para "Añadir a pantalla de inicio" en iOS y Android.
- 🔗 **Invitación instantánea**:
  - Enlace directo con parámetro de sala (`?list=nombre-o-codigo`).
  - Código QR generado en pantalla para escanear de móvil a móvil.
  - Botón nativo de compartir (`WhatsApp`, `Telegram`, SMS, etc.).
- 📦 **Local-First**: Persistencia en `localStorage` con [Varasto](https://hexdocs.pm/varasto/) para que funcione sin retraso incluso con poca cobertura en el supermercado.
- 📷 **Escaneo OCR**: Detección automática de listas escritas en papel (Tesseract.js local o endpoint remoto).
- ✏️ **Edición inline y reordenación**: Tachar productos los desplaza al fondo; los no marcados se ordenan alfabéticamente.

---

## 🛠️ Comandos de desarrollo

```sh
# Ejecutar tests unitarios (Gleam en target JavaScript)
gleam test --target javascript

# Compilar frontend y empaquetar bundle con assets
npm run build

# Iniciar servidor local de desarrollo con Cloudflare Workers
npm run dev
```

El servidor local arrancará en `http://localhost:8787`.

---

## 🚀 Despliegue en la nube (Cloudflare Workers)

Para desplegar la aplicación completa (backend serverless + assets de la PWA) en tu cuenta de Cloudflare:

```sh
# Iniciar sesión en Cloudflare (solo la primera vez)
npx wrangler login

# Desplegar
npm run deploy
```

Wrangler publicará la PWA en un dominio gratuito `*.workers.dev` (o en tu propio dominio personalizado).
