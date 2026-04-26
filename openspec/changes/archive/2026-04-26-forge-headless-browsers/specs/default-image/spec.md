## ADDED Requirements

### Requirement: Forge ships headless Chromium and headless Firefox with WebDriver bridges

The forge image SHALL install `chromium-headless` (Fedora's headless-only Chromium build), `firefox` (used in `--headless` mode), `chromedriver` (the W3C WebDriver server for Chromium), and `geckodriver` (the Mozilla WebDriver server for Firefox; pinned upstream binary because Fedora doesn't package it). All four binaries SHALL be on the default `$PATH` for the forge user (UID 1000).

The full-Chrome / full-Firefox GUI variants are intentionally NOT installed — interactive browser windows belong to the host (per the `host-chromium-on-demand` capability), not to the forge. The forge needs only the headless variants for agent-driven testing (Selenium, Playwright, raw WebDriver).

#### Scenario: chromium-headless invokable
- **WHEN** an agent inside the forge runs `chromium-headless --version`
- **THEN** the command prints a version string (e.g., `Chromium 134.x`) and exits 0

#### Scenario: firefox headless invokable
- **WHEN** an agent inside the forge runs `firefox --version`
- **THEN** the command prints a version string and exits 0
- **AND** `firefox --headless --screenshot=/tmp/test.png https://example.com` produces a PNG when run with proxy env vars set (egress goes through the enclave proxy)

#### Scenario: WebDriver bridges available
- **WHEN** an agent inside the forge runs `chromedriver --version` and `geckodriver --version`
- **THEN** both commands print their respective versions and exit 0

#### Scenario: Image size impact bounded
- **WHEN** the forge image is built with the headless browsers added
- **THEN** the image size SHALL grow by no more than 600 MB compared to the previous version (target: ~+400 MB; bound: 600 MB to allow for Fedora package transitive deps)

#### Scenario: Drivers are pinned
- **WHEN** the Containerfile fetches `geckodriver` from upstream
- **THEN** the URL SHALL pin a specific version (e.g., `v0.36.0`)
- **AND** the version SHALL be bumped by deliberate Containerfile edits, not by `:latest`-style floating refs

## Sources of Truth

- `cheatsheets/test/selenium.md` (DRAFT) — Selenium WebDriver flow this change unblocks.
- `cheatsheets/test/playwright.md` (DRAFT) — Playwright still installs its own browsers, but having Chromium/Firefox in the forge means the system Chromium can be a fallback when Playwright's downloader fails (e.g., proxy allowlist gap).
- `cheatsheets/runtime/forge-container.md` (DRAFT) — image-is-the-toolbox principle.
