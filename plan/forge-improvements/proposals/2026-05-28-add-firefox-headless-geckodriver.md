---
title: Add headless Firefox and geckodriver for cross-browser agent-driven testing
gap: Headless Firefox and geckodriver WebDriver bridge are missing from the forge image
category: runtime-tool
status: implemented
proposed_at: 2026-05-28T22:02:00Z
implemented_at: 2026-05-29T08:24:50Z
evidence: Added RUN microdnf install -y firefox + curl geckodriver v0.36.0 to Containerfile
changes:
  - file: images/default/Containerfile
    description: Add `RUN microdnf install -y firefox` and curl-based geckodriver pinned binary download. See spec for version pinning.
approved_by: orchestrator
---

## Gap

The `default-image` spec (`openspec/specs/default-image/spec.md`, lines 217-243) requires:

> The forge image SHALL install `firefox` (used in `--headless` mode) and `geckodriver` (the Mozilla WebDriver server for Firefox; pinned upstream binary because Fedora doesn't package it).
>
> **Scenario: firefox headless invokable**
> - **WHEN** an agent inside the forge runs `firefox --version`
> - **THEN** the command SHALL print a version string and exit 0
> - **AND** `firefox --headless --screenshot=/tmp/test.png https://example.com` SHALL produce a PNG
>
> **Scenario: WebDriver bridges available**
> - **WHEN** an agent inside the forge runs `geckodriver --version`
> - **THEN** both commands SHALL print their respective versions and exit 0
>
> **Scenario: Drivers are pinned**
> - **WHEN** the Containerfile fetches `geckodriver` from upstream
> - **THEN** the URL SHALL pin a specific version (e.g., `v0.36.0`)

The current Containerfile does NOT install firefox or geckodriver.

## Evidence

- `openspec/specs/default-image/spec.md` lines 217-243 — full requirement text
- `images/default/Containerfile` line 17-24 — package list excludes firefox and no geckodriver download step
- Fedora does not package geckodriver, so it must be fetched as a pinned binary from GitHub releases

## Impact

Without Firefox/geckodriver:
- Cross-browser testing (Chromium-only) is insufficient for web projects
- The Playwright Firefox integration is unavailable
- `geckodriver` enables the full W3C WebDriver protocol standard for cross-browser agent scripts

## Proposed Change

Add after chromium-headless install in Containerfile:

```dockerfile
# Headless Firefox for cross-browser agent-driven testing
# @trace spec:default-image
RUN microdnf install -y firefox \
    && curl -fsSL -o /tmp/geckodriver.tar.gz \
       https://github.com/mozilla/geckodriver/releases/download/v0.36.0/geckodriver-v0.36.0-linux64.tar.gz \
    && tar -xzf /tmp/geckodriver.tar.gz -C /usr/local/bin/ \
    && chmod +x /usr/local/bin/geckodriver \
    && rm /tmp/geckodriver.tar.gz
```

## Safety

- Firefox running in `--headless` mode has no GUI or X11 dependency
- Pinned geckodriver version ensures deterministic builds (not `:latest`-style floating refs)
- No credential exposure — headless browser has no login state
- Firefox telemetry is blocked by enclave network isolation
