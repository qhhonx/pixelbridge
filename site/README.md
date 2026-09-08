# PixelBridge website

Standard Next.js App Router site, preserving the product's bilingual layout and illustrations.

```sh
npm ci
npm run dev
npm test
npm run build
```

Import the repository in Vercel and select `site` as the Root Directory. Framework: Next.js. Production branch: main. Node: 22.x. Git integration deploys future pushes automatically. See `.env.example` for optional origin and repository settings.

Public downloads are disabled by default while source and release assets are private. The page shows a beta preparation status, `/download` returns to that section, and `/appcast.xml` responds with temporary unavailability. No private-repository credentials are used by the site. After public releases are approved, enable `NEXT_PUBLIC_RELEASES_ENABLED` and optionally set `NEXT_PUBLIC_SOURCE_URL`, then redeploy.

When enabled, release metadata is cached server-side. `/download` redirects to the newest complete public release (including betas), and `/appcast.xml` serves that release's signed Sparkle feed without rewriting it. A release is eligible only when its ZIP, SHA-256 manifest and appcast are all present. These routes do not accept arbitrary remote URLs or handle photos.
