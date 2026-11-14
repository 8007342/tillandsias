# The forge has no Playwright or headless browser for project smoke scripts (order 2065-k5dd)

Filed 2026-11-09 from the demon_attack forge session (demon-attack-3e),
relayed by macuahuitl-fedora.

## What is wrong

The project ships `tools/*smoke*.cjs` (Playwright). The forge has no
Playwright and no browser binary, so the scripts cannot run, and agents
fall back to `browser.*` MCP calls one step at a time.

## Ask

Choose one of:

- (a) Ship Playwright with one headless engine in the forge image, or as an
  on-demand install through the proxy cache (size matters: chromium alone
  is about 150 MB).
- (b) Give the scripts a Playwright-compatible endpoint backed by the
  enclave's existing browser (CDP over the browser MCP's isolation), so
  nothing new ships in the forge.

(b) keeps the browser-isolation boundary, so it is the likely preference.

## Closure

`node tools/<x>smoke.cjs` runs to its own pass or fail inside a forge
against the local preview.
