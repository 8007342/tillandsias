## Why

99% of projects Tillandsias creates will eventually need to serve static files over HTTP: an HTML page, some JavaScript, CSS, images. Today, if a user generates a web project and clicks "Run," there is no lightweight runtime image to serve it. The default forge image is ~1GB and includes dev tooling (Nix, OpenCode, Node, git) that a running web app does not need. Shipping a bloated dev image as a runtime is wasteful, slow to start, and violates the ephemeral-and-tiny principle.

A dedicated web image based on Alpine Linux with busybox httpd solves this cleanly. Alpine is ~5MB. The `busybox-extras` package adds httpd (~150KB). The image mounts the project directory as the document root and serves it on port 8080. Total image size: under 10MB.

This is the first "runtime image" in the Tillandsias image catalog. It establishes the pattern: forge images are fat (dev tools), runtime images are tiny (just enough to run). Future runtime images (Node, Python, database) will follow the same pattern.

## What Changes

- **New container image** at `images/web/Containerfile`: Alpine-based, busybox httpd, serves `/var/www` on port 8080
- **New entrypoint script** at `images/web/entrypoint.sh`: prints a banner with the project name and serving URL, then execs httpd
- **New spec** at `openspec/specs/web-image/spec.md`: requirements and scenarios for the web runtime image
- **Enables `--image web`**: the CLI can now resolve `web` to the `tillandsias-web:latest` image and launch static file serving with one flag

## Capabilities

### New Capabilities
- `web-image`: A minimal Alpine + busybox httpd container image that serves static files on port 8080 with a project directory mounted as the document root. Under 10MB. No configuration required.

### Modified Capabilities
<!-- None — this is a new image, no existing specs affected -->

## Impact

- **New files**: `images/web/Containerfile`, `images/web/entrypoint.sh`
- **Image size**: Under 10MB (Alpine base ~5MB + busybox httpd already included)
- **Port**: 8080 (matches Tillandsias convention for web runtimes)
- **Security**: Runs as root inside the container, which is acceptable because the container itself is sandboxed (rootless podman, `--cap-drop=ALL`, `--security-opt=no-new-privileges`)
- **No Rust code changes**: This is a container image only
