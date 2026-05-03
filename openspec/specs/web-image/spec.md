<!-- @trace spec:web-image -->
# web-image Specification

## Status

status: active

## Purpose
TBD - created by archiving change web-image. Update Purpose after archive.
## Requirements
### Requirement: Minimal Alpine-based container image
The web runtime image SHALL be based on Alpine Linux and be under 10MB in total size.

#### Scenario: Image size
- **WHEN** the image is built from `images/web/Containerfile`
- **THEN** the resulting image is less than 10MB

#### Scenario: Base image
- **WHEN** the Containerfile is inspected
- **THEN** the FROM instruction references `docker.io/library/alpine:latest`

### Requirement: Static file serving via busybox httpd
The image SHALL serve static files from `/var/www` on port 8080 using busybox httpd with no additional packages or configuration.

#### Scenario: Serving HTML files
- **WHEN** a directory containing `index.html` is mounted at `/var/www`
- **AND** the container is started
- **THEN** HTTP GET to `http://localhost:8080/` returns the contents of `index.html`

#### Scenario: Serving JavaScript and CSS
- **WHEN** files `app.js` and `style.css` exist in the mounted directory
- **THEN** HTTP GET to `http://localhost:8080/app.js` returns the JavaScript file with appropriate MIME type
- **AND** HTTP GET to `http://localhost:8080/style.css` returns the CSS file with appropriate MIME type

#### Scenario: Serving images
- **WHEN** image files (PNG, JPG, SVG) exist in the mounted directory
- **THEN** HTTP GET to the image paths returns the files with appropriate MIME types

#### Scenario: No index.html
- **WHEN** the mounted directory has no `index.html`
- **THEN** HTTP GET to `http://localhost:8080/` returns a 404 response (no directory listing)

### Requirement: Port 8080 exposed
The image SHALL expose port 8080 for HTTP traffic.

#### Scenario: Container port
- **WHEN** the container is started with `-p 8080:8080`
- **THEN** the web server is accessible at `http://localhost:8080` from the host

### Requirement: Entrypoint displays banner and serving URL
The container entrypoint SHALL print a human-readable banner with the project name and serving URL before starting httpd.

#### Scenario: Startup banner
- **WHEN** the container starts
- **THEN** the output includes the text "Serving at http://localhost:8080"

#### Scenario: Entrypoint execs httpd
- **WHEN** the entrypoint script runs
- **THEN** it uses `exec` to replace itself with the httpd process so that signals are delivered directly to httpd

### Requirement: Graceful shutdown
The container SHALL respond to SIGTERM by stopping httpd cleanly.

#### Scenario: Podman stop
- **WHEN** `podman stop` sends SIGTERM to the container
- **THEN** httpd exits cleanly and the container stops

### Requirement: Document root at /var/www
The container WORKDIR and httpd document root SHALL be `/var/www`, where the project directory is mounted by Tillandsias.

#### Scenario: Volume mount
- **WHEN** the container is launched with `-v /path/to/project:/var/www:ro`
- **THEN** the project files are served by httpd


## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/build/cargo.md` — Cargo reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:web-image" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
