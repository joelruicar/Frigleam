# OCR security configuration

The `/api/ocr` endpoint requires all of the following in production:

- Cloudflare Rate Limiting binding `OCR_RATE_LIMITER`.
- Turnstile secret stored outside the repository.
- The public Turnstile site key in `assets/index.html`.

Configure the secret with:

```sh
npx wrangler secret put TURNSTILE_SECRET
```

Then set `window.FRIGO_TURNSTILE_SITE_KEY` in `assets/index.html` to the public
site key from the same Turnstile widget. The secret must never be placed in
frontend JavaScript.

The Worker accepts JPEG, PNG, and WebP uploads up to 5 MB and limits OCR to 10
requests per IP every minute.