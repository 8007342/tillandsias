# Browser Isolation Core Spec

@trace spec:browser-isolation-core
@trace spec:versioning

## Security Model

The `chromium-core` image provides the base isolated browser environment:

- **Read-only root filesystem** — prevents runtime modification of system files
- **No external network** — browser cannot access external networks directly
- **No credentials** — zero secrets, tokens, or keys in the image
- **Reduced capabilities** — minimal kernel capabilities via `--cap-drop=ALL`

## Image Versioning

The `chromium-core` image MUST use versioned tags in `vX.Y.Z.B` format, derived from the `VERSION` file at the project root.

- Tag format: `tillandsias-chromium-core:v<Major>.<Minor>.<ChangeCount>.<Build>`
- NO `:latest` tags are allowed — all references must be version-explicit

## Build

The image is built using:

```
images/chromium/Containerfile.core
```

Build is invoked via `scripts/build-image.sh chromium-core` which reads the VERSION file and applies the appropriate tag.
