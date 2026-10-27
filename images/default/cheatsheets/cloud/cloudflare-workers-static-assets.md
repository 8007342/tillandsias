---
tags: [cloudflare, workers, wrangler, static-assets, single-page-application, deploy]
languages: [json]
since: 2026-10-27
last_verified: 2026-10-27
sources:
  - https://developers.cloudflare.com/workers/wrangler/configuration/
  - https://developers.cloudflare.com/workers/static-assets/routing/single-page-application/
  - https://developers.cloudflare.com/workers/platform/limits/
  - https://developers.cloudflare.com/workers/configuration/compatibility-dates/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Cloudflare Workers: serving a website or web app from static assets

@trace spec:agent-cheatsheets, order:1907-xhpx

## Provenance

- Cloudflare Docs, "Configuration - Wrangler" (`name`, `compatibility_date`, `main`, `assets` keys of `wrangler.jsonc`): <https://developers.cloudflare.com/workers/wrangler/configuration/>
- Cloudflare Docs, "Single Page Application (SPA)" (`assets.not_found_handling = "single-page-application"`): <https://developers.cloudflare.com/workers/static-assets/routing/single-page-application/>
- Cloudflare Docs, "Limits" (Workers Free vs Paid account limits): <https://developers.cloudflare.com/workers/platform/limits/>
- Cloudflare Docs, "Compatibility dates": <https://developers.cloudflare.com/workers/configuration/compatibility-dates/>
- **Last updated:** 2026-10-27

## The smallest config that serves a folder

```jsonc
{
  "name": "my-site",                 // lowercase letters, digits, dashes
  "compatibility_date": "2026-10-27", // set to today's date when you create it
  "assets": { "directory": "./public" }
}
```

No `main` is needed when the Worker only serves files. Add `"main": "src/index.ts"`
when the app also has server code (an API route); the assets are served
first and unmatched requests reach the script.

## Single-page apps (React, Vue, Flutter web)

```jsonc
"assets": {
  "directory": "./build/web",          // Flutter: `flutter build web` output
  "not_found_handling": "single-page-application"
}
```

`single-page-application` serves `index.html` for any path that matches no
file, so client-side routes like `/settings` load the app instead of a 404.

## compatibility_date

Pins the Workers runtime behaviour to that date: every compatibility flag up
to and including it is on. Set it to the current date for a new project and
move it forward deliberately.

## Free plan limits that matter for a starter site (Workers Free)

| Limit | Free | Paid |
|---|---|---|
| Requests | 100,000 per day | higher (see source) |
| CPU time per HTTP request | 10 ms | up to 5 min (default 30 s) |
| Memory | 128 MB | 128 MB |
| Static asset files per Worker version | 20,000 | 100,000 |
| Individual static asset file size | 25 MiB | 25 MiB |

## Local preview vs deploy

- `npx wrangler dev` previews locally and needs no account.
- Deploying needs a Cloudflare account and credentials. In a Tillandsias
  forge those stay on the host; deploy only when the user asks.
- Local-only settings go in `.dev.vars` (never committed); ship a
  `.dev.vars.example` with placeholder names only.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

### Source

- **Upstream URL(s):**
  - `https://developers.cloudflare.com/workers/wrangler/configuration/`
  - `https://developers.cloudflare.com/workers/static-assets/routing/single-page-application/`
  - `https://developers.cloudflare.com/workers/platform/limits/`
- **Archive type:** `single-html`
- **Expected size:** `~3 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/developers.cloudflare.com/workers/`
- **License:** see-license-allowlist
- **License URL:** https://developers.cloudflare.com/workers/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
BASE="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/developers.cloudflare.com/workers"
mkdir -p "$BASE"
for p in wrangler/configuration static-assets/routing/single-page-application platform/limits; do
  mkdir -p "$BASE/$(dirname "$p")"
  curl --fail --silent --show-error "https://developers.cloudflare.com/workers/$p/" -o "$BASE/$p.html"
done
```

### Generation guidelines (after pull)

1. Read the pulled pages for the keys and limits relevant to your project.
2. Free-plan limits change; re-read `platform/limits` before quoting a number.
