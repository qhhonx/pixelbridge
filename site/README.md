# PixelBridge website

Standard Next.js App Router site, preserving the product's bilingual layout and illustrations.

```sh
npm ci
npm run dev
npm test
npm run build
```

Import the repository in Vercel and select `site` as the Root Directory. Framework: Next.js. Production branch: main. Node: 22.x. Git integration deploys future pushes automatically. See `.env.example` for optional origin and repository settings.

Release metadata is cached server-side. `/download` redirects to the newest complete public release (including betas), and `/appcast.xml` serves that release's signed Sparkle feed without rewriting it. A release is eligible only when its ZIP, SHA-256 manifest and appcast are all present. These routes do not accept arbitrary remote URLs or handle photos.
