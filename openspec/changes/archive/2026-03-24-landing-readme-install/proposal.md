## Why

The current README.md is an architecture document. A visitor landing on the GitHub page sees workspace structure, container naming conventions, and genus tables before they ever learn how to install or run the app. For a project that targets Average Joe, the first screen should answer one question: "How do I use this?"

## What Changes

- Move the current README.md to README-ABOUT.md (preserves all existing content)
- Replace README.md with a short landing page: tagline, install, run, uninstall, requirements, link to README-ABOUT.md
- Add `scripts/install.sh` (curl-pipe-bash installer for Linux/macOS)
- Add `scripts/uninstall.sh` (standalone uninstaller, also installed as `tillandsias-uninstall`)

## Capabilities

### New Capabilities
- `landing-page`: A concise README that gets users from zero to running in seconds

### Modified Capabilities
<!-- None -->

## Impact

- No code changes — documentation and install scripts only
- Existing README content is preserved verbatim in README-ABOUT.md
- Install script depends on GitHub Releases existing (graceful failure with build-from-source fallback)
