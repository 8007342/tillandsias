## Why

The forge image today ships no browsers. Agents trying to run Selenium / Playwright / WebDriver tests inside the forge fail at the first `chromedriver: program not found` step. Per `cheatsheets/test/selenium.md` (DRAFT) and `cheatsheets/test/playwright.md` (DRAFT) the workaround was either per-project install (heavy) or a sidecar container — both of which break the "image is the toolbox" contract documented in the `default-image` capability.

Adding headless Chromium + Firefox + their WebDriver bridges to the forge unblocks the common test scenarios (UI smoke tests, integration tests against the agent's own dev server) without requiring the agent to leave the sandbox or download anything at runtime.

## What Changes

- **MODIFIED** Containerfile installs `chromium-headless` (Fedora's headless-only Chromium build), `firefox` (used in `--headless` mode), `chromedriver`, and the Mozilla `geckodriver` binary (downloaded from upstream — not in Fedora's repos).
- **NEW** Cheatsheets `test/selenium.md` and `test/playwright.md` get an updated forge-specific section noting the binaries are now baked. Both cheatsheets remain DRAFT (provenance retrofit happens later).
- Image size grows from ~5.6 GB to ~6.0 GB (chromium-headless ~150 MB, firefox ~100 MB, drivers ~40 MB combined).
- Headless-only choice for Chromium: the user-facing browser is the host-bundled Chromium (per `host-chromium-on-demand`); the forge needs ONLY the headless variant for tests, which is significantly smaller and has no GUI deps.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `default-image`: forge image SHALL ship `chromium-headless`, `firefox`, `chromedriver`, and `geckodriver` so agents can run browser-driven tests without runtime installs.

## Impact

- `images/default/Containerfile` — extend the `microdnf install -y` layer to add `chromium-headless firefox chromedriver`, then a separate layer that fetches `geckodriver` from `https://github.com/mozilla/geckodriver/releases/download/v0.36.0/geckodriver-v0.36.0-linux64.tar.gz` (pinned).
- Image size +400 MB approx.
- Build time +30 s approx (mostly the geckodriver download via curl).
- `cheatsheets/test/selenium.md` and `cheatsheets/test/playwright.md` — drop the "no browsers in forge" warnings, replace with the actual installed versions.
- No tray, no router, no host-side change.
- Acceptance test: `podman run --rm tillandsias-forge:vX sh -c 'chromedriver --version && geckodriver --version && chromium-headless --version && firefox --version'` returns four version lines.

## Sources of Truth

- `cheatsheets/test/selenium.md` (DRAFT) — describes the forge-specific gap this change closes.
- `cheatsheets/test/playwright.md` (DRAFT) — same.
- `cheatsheets/runtime/forge-container.md` (DRAFT) — the "image is the toolbox" rule we're upholding by baking the browsers in.
