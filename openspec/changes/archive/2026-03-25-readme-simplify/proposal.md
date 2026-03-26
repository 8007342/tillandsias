## Why

The current Install section uses nested `<details>` blocks to show per-platform options, including APT repository setup, Fedora COPR, Silverblue rpm-ostree layering, RPM/DEB downloads, and an `.app.tar.gz` bundle. This creates visual noise and maintenance surface: three distro-specific package manager flows, two Linux download formats (AppImage + RPM + DEB), and an `.app` bundle on top of DMG for macOS. Most users just need the one-shot `curl | bash`. The nested details pattern was borrowed from a tab-switching idea that GitHub markdown can't actually implement — the result is a page that appears to offer more control than users want.

## What Changes

- **Remove nested `<details>` "Other ways to install"** blocks for all three platforms
- **Remove distro-specific install methods** — APT repository, Fedora COPR, Silverblue rpm-ostree instructions are gone from the README (they belong in a separate distro guide if needed)
- **Remove RPM/DEB download links** — AppImage is the only Linux binary format surfaced here
- **Remove macOS `.app.tar.gz` download link** — DMG is the canonical macOS install format
- **Flatten to three plain sections** — Linux, macOS, Windows, each with a single install command
- **Collapse direct downloads** — A single `<details>` block at the end of the Install section lists the four canonical direct-download files

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `README.md`: Install section is simplified to three platform sections (Linux, macOS, Windows) each with one install command, plus a collapsed direct-downloads table

## Impact

- **New files**: none
- **Modified files**: `README.md` (Install section only; everything from `## Run` onward is unchanged)
