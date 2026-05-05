<!-- @trace spec:web-image -->
# web-image Specification

## Status

status: active

## Purpose
TBD - created by archiving change web-image. Update Purpose after archive.
## Requirements
### Requirement: Minimal Alpine-based container image
The web runtime image MUST be based on Alpine Linux and be under 10MB in total size. @trace spec:web-image

#### Scenario: Image size
- **WHEN** the image is built from `images/web/Containerfile`
- **THEN** the resulting image MUST be less than 10MB

#### Scenario: Base image
- **WHEN** the Containerfile is inspected
- **THEN** the FROM instruction MUST reference `docker.io/library/alpine:latest`

### Requirement: Static file serving via busybox httpd
The image MUST serve static files from `/var/www` on port 8080 using busybox httpd with no additional packages or configuration.

#### Scenario: Serving HTML files
- **WHEN** a directory containing `index.html` is mounted at `/var/www`
- **AND** the container is started
- **THEN** HTTP GET to `http://localhost:8080/` MUST return the contents of `index.html`

#### Scenario: Serving JavaScript and CSS
- **WHEN** files `app.js` and `style.css` exist in the mounted directory
- **THEN** HTTP GET to `http://localhost:8080/app.js` MUST return the JavaScript file with appropriate MIME type
- **AND** HTTP GET to `http://localhost:8080/style.css` MUST return the CSS file with appropriate MIME type

#### Scenario: Serving images
- **WHEN** image files (PNG, JPG, SVG) exist in the mounted directory
- **THEN** HTTP GET to the image paths MUST return the files with appropriate MIME types

#### Scenario: No index.html
- **WHEN** the mounted directory has no `index.html`
- **THEN** HTTP GET to `http://localhost:8080/` MUST return a 404 response (no directory listing)

### Requirement: Port 8080 exposed
The image MUST expose port 8080 for HTTP traffic.

#### Scenario: Container port
- **WHEN** the container is started with `-p 8080:8080`
- **THEN** the web server MUST be accessible at `http://localhost:8080` from the host

### Requirement: Entrypoint displays banner and serving URL
The container entrypoint MUST print a human-readable banner with the project name and serving URL before starting httpd.

#### Scenario: Startup banner
- **WHEN** the container starts
- **THEN** the output MUST include the text "Serving at http://localhost:8080"

#### Scenario: Entrypoint execs httpd
- **WHEN** the entrypoint script runs
- **THEN** it MUST use `exec` to replace itself with the httpd process so that signals are delivered directly to httpd

### Requirement: Graceful shutdown
The container MUST respond to SIGTERM by stopping httpd cleanly.

#### Scenario: Podman stop
- **WHEN** `podman stop` sends SIGTERM to the container
- **THEN** httpd MUST exit cleanly and the container MUST stop

### Requirement: Document root at /var/www
The container WORKDIR and httpd document root MUST be `/var/www`, where the project directory is mounted by Tillandsias.

#### Scenario: Volume mount
- **WHEN** the container is launched with `-v /path/to/project:/var/www:ro`
- **THEN** the project files MUST be served by httpd


## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee` — image size, static file serving, port exposure, shutdown grace

Gating points:
- Image size < 10MB; based on alpine:latest
- busybox httpd serves static files from /var/www on port 8080
- HTML/JS/CSS/images served with appropriate MIME types
- 404 returned for missing index.html (no directory listing)
- Port 8080 exposed and accessible from host
- Entrypoint prints banner with serving URL before exec httpd
- SIGTERM handled gracefully; httpd exits cleanly
- Document root at /var/www; accepts volume mounts with -v

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/build/cargo.md` — Cargo reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:web-image" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
