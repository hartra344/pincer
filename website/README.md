# Pincer website

The marketing site and documentation for Pincer, built with [Astro](https://astro.build) and [Starlight](https://starlight.astro.build).

Requires Node 22.12+ (`nvm use` picks it up from `.nvmrc`).

```sh
npm install
npm run dev       # http://localhost:4321/
npm run build     # -> dist/
npm run preview
```

- `src/pages/index.astro` is the landing page.
- `src/content/docs/` holds the docs, one Markdown/MDX file per page. Add new pages to the `sidebar` in `astro.config.mjs`.
- `src/styles/docs.css` applies Pincer's Lobster palette to Starlight.

The site is deployed on Vercel (project root: `website/`). Pushes to `main` deploy to production, and other branches get preview deployments. Set `SITE_URL` in the Vercel project if you add a custom domain.

## Screenshots

See [SCREENSHOTS.md](SCREENSHOTS.md) for the isolated capture app, synthetic demo/mock scenarios, and the shot list. Documentation images use `src/components/DocScreenshot.astro` with captions and full-resolution links.
