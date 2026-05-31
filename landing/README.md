# Astro Landing Page

Astro source for `echodesk.us`.

## Structure

- `src/pages/index.astro` - Landing page source
- `public/` - Static assets copied into `dist/`
- `dist/` - Static build output served by nginx

## Local development

```bash
cd landing
npm install
npm run dev
```

## Build

```bash
cd landing
npm run build
```

The VPS deploy script syncs `landing/dist/` to `/var/www/echodesk-landing`.
