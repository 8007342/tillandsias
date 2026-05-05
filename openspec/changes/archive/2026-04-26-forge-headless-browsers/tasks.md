## 1. Containerfile

- [ ] 1.1 Add `chromium-headless`, `firefox`, `chromedriver` to the existing `microdnf install -y \ ...` layer in `images/default/Containerfile` (after the `protobuf-compiler protobuf-devel xmlstarlet libxml2` group added by `agent-source-of-truth`).
- [ ] 1.2 After the yq+grpcurl curl-and-extract block (already in the Containerfile), add a new layer that fetches `geckodriver-v0.36.0-linux64.tar.gz` from `https://github.com/mozilla/geckodriver/releases/download/v0.36.0/geckodriver-v0.36.0-linux64.tar.gz`, extracts to `/usr/local/bin/geckodriver` (with `--no-same-owner`), `chmod +x`, and verifies `--version`.

## 2. Cheatsheet content updates

- [ ] 2.1 In `cheatsheets/test/selenium.md`, replace the "Forge-specific" section's "no browsers in forge" warning with: "Chromium-headless, Firefox, ChromeDriver, and GeckoDriver are baked into the forge image (see `default-image` capability). No `RUNTIME_LIMITATIONS` report needed for browser-driven tests." Cheatsheet remains DRAFT until provenance retrofit.
- [ ] 2.2 Same update in `cheatsheets/test/playwright.md` — note that Playwright's own `playwright install` still works, but the system Chromium in `chromium-headless` is now available as a fallback / for non-Playwright Selenium scripts.

## 3. Build + verify

- [ ] 3.1 `scripts/build-image.sh forge --force` — confirm the new layer lands and the image rebuilds.
- [ ] 3.2 Smoke test inside the new image: `podman run --rm tillandsias-forge:latest sh -c 'chromedriver --version && geckodriver --version && chromium-headless --version && firefox --version'` — all four return version lines.
- [ ] 3.3 Compare image size before / after; document the delta in the commit message. Confirm ≤ 600 MB growth.
