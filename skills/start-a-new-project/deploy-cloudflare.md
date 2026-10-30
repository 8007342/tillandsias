# Putting the app online with Cloudflare

Read this when the user wants their website or Flutter app online through
Cloudflare, the default for those two kinds of app.

## Cost, said plainly

Free, with no payment method on file. Requests for the site's files (pages,
pictures, the Flutter build) are free with no limit. If the app later gains
server code, that code gets 100,000 requests a day on the free plan; past
that, extra requests are turned away until the next day, and nothing is
charged (as published by Cloudflare on 2026-10-27).

## What the setup script added

| File | What it is |
|---|---|
| `wrangler.jsonc` | Cloudflare's settings: the app's name, today's date as the runtime version, and the folder to serve |
| `public/index.html` | a first page, for a website; replace it with the real one |
| `.dev.vars.example` | where local-only settings would go, with example names only |
| `.gitignore` line `.dev.vars` | keeps the real local settings file out of git |

A website serves `./public`. A Flutter app serves `./build/web`, so run
`flutter build web` first; any address that is not a file opens the app, so
its own page links work.

## Trying it locally

`npx wrangler dev` shows the site on this computer and needs no account.

## Putting it online

This needs the user's own Cloudflare account. Never create an account, sign
in, paste an account id or key into the project, or publish on your own;
publish only when the user asks, and only from their computer, where their
sign-in lives. Once published, the app is at
`https://<name>.<their-subdomain>.workers.dev`.
