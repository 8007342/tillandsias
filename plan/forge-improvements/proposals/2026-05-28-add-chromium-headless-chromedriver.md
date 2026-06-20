---
title: Add headless Chromium and chromedriver for agent-driven browser testing
gap: Headless Chromium and chromedriver WebDriver bridge are missing from the forge image
category: runtime-tool
status: implemented
proposed_at: 2026-05-28T22:01:00Z
implemented_at: 2026-05-29T08:24:49Z
evidence: Added RUN microdnf install -y chromium-headless chromedriver to Containerfile after system packages
changes:
  - file: images/default/Containerfile
    description: Add `RUN microdnf install -y chromium-headless chromedriver` after the system packages section. These are Fedora-packaged and add ~200 MB to the image.
approved_by: orchestrator
---

## Gap

The `default-image` spec (`openspec/specs/default-image/spec.md`, lines 217-243) requires:

> **Requirement: Forge ships headless Chromium and headless Firefox with WebDriver bridges**
>
> The forge image SHALL install `chromium-headless` (Fedora's headless-only Chromium build), `chromedriver` (the W3C WebDriver server for Chromium)...
>
> **Scenario: chromium-headless invokable**
> - **WHEN** an agent inside the forge runs `chromium-headless --version`
> - **THEN** the command SHALL print a version string (e.g., `Chromium 134.x`) and exit 0
>
> **Scenario: WebDriver bridges available**
> - **WHEN** an agent inside the forge runs `chromedriver --version`
> - **THEN** both commands SHALL print their respective versions and exit 0

The current Containerfile does NOT install chromium-headless or chromedriver.

## Evidence

- `openspec/specs/default-image/spec.md` lines 217-243 — full requirement text
- `images/default/Containerfile` line 17-24 — package list excludes chromium-headless and chromedriver
- Spec also requires the image size grow by no more than 600 MB (target ~+400 MB): Fedora's chromium-headless package is self-contained at ~200 MB; chromedriver is ~10 MB

## Impact

Without headless browsers:
- Agents cannot run Selenium, Playwright, or raw WebDriver tests
- No browser screenshots for debugging
- The `web-services.md` agent instructions reference browser testing but the tools aren't available
- E2E web-app verification inside the forge is impossible

## Proposed Change

Add after the system packages install in Containerfile:

```dockerfile
# Headless Chromium for agent-driven browser testing (Selenium, Playwright, WebDriver)
# @trace spec:default-image
RUN microdnf install -y chromium-headless chromedriver
```

## Safety

- `chromium-headless` is the Fedora-packaged headless-only variant — no GUI components, no X11 dependency
- Runs inside enclave network — browser telemetry/UPDATES are blocked by default
- No credential exposure — no login state persisted in the headless browser
