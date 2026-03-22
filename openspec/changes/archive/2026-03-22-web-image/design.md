## Context

Tillandsias has a "default" forge image (`images/default/Containerfile`) based on Fedora Minimal with Nix, OpenCode, Node, git, and other dev tools. This image is designed for development — it is large and includes everything needed to build software. However, once a static web project is built, it only needs a tiny HTTP server to serve HTML/JS/CSS/images. There is no runtime image for this use case.

Alpine Linux ships with busybox, but the default busybox build does not include the httpd applet. The `busybox-extras` package adds it. One `apk add` is all that is needed. The resulting image is still under 10MB.

**Constraints:**
- Must be as small as possible — every MB matters for ephemeral containers
- Must serve static files with zero configuration
- Must expose port 8080 (Tillandsias web convention)
- Must work with rootless podman and the project's security defaults
- Must not require any build step — just mount and serve

## Goals / Non-Goals

**Goals:**
- Tiny Alpine-based image with busybox httpd serving static files
- Entrypoint that prints a human-friendly banner and execs httpd
- Works with `--image web` CLI flag
- Project directory mounted as document root at `/var/www`

**Non-Goals:**
- CGI, PHP, or any dynamic content
- TLS/HTTPS (local development only)
- Reverse proxy, load balancing, or caching headers
- Custom httpd configuration files
- Multi-stage builds or compiled assets

## Decisions

### D1: Alpine Linux as Base Image

**Choice:** `docker.io/library/alpine:latest`

**Why:** Alpine is the smallest general-purpose Linux distribution (~5MB). It uses musl libc and busybox, which includes a built-in httpd server. No package installation needed — busybox httpd is available out of the box.

**Alternatives considered:**
- `scratch` — no shell, no debugging ability, cannot run entrypoint.sh
- `busybox` image — similar size but Alpine has a package manager for future extensibility
- `nginx:alpine` — ~40MB, massive overkill for static file serving
- `python:alpine` + `python -m http.server` — ~50MB, Python runtime overhead for a trivial task

### D2: Busybox httpd as Web Server

**Choice:** `httpd -f -p 8080 -h /var/www` (provided by `busybox-extras` package)

Flags:
- `-f`: foreground mode (required for container process management)
- `-p 8080`: listen on port 8080
- `-h /var/www`: document root

**Why:** Alpine's default busybox does not include httpd, but the `busybox-extras` package adds it with a single `apk add` (~150KB). Serves static files correctly including proper MIME types for HTML, JS, CSS, images. No configuration file needed.

**Alternatives considered:**
- `python -m http.server` — requires Python installation, 10x the image size
- `darkhttpd` — excellent minimal server but requires `apk add`, adds a dependency
- `lighttpd` — overkill, requires config file
- `nginx` — massive overkill for local static file serving

### D3: Root User Inside Container

**Choice:** Run httpd as root inside the container.

**Why:** The container is already sandboxed by rootless podman with `--cap-drop=ALL` and `--security-opt=no-new-privileges`. Adding a non-root user inside the container adds complexity (UID mapping, volume permission issues with `--userns=keep-id`) for zero security benefit — the container root has no capabilities and cannot escalate.

**Alternatives considered:**
- Non-root user (like the forge image's `forge` user) — creates volume permission issues when mounting project directories, requires UID alignment, adds Containerfile complexity for no security gain inside an already-sandboxed container.

### D4: Entrypoint Script with Banner

**Choice:** A simple `entrypoint.sh` that prints a banner with the project name and URL, then execs httpd.

**Why:** Users need immediate feedback about what is happening and where to access their app. The banner provides this. Using `exec` ensures httpd replaces the shell process, so signals (SIGTERM from podman stop) go directly to httpd.

### D5: /var/www as Document Root

**Choice:** WORKDIR and document root at `/var/www`.

**Why:** Standard convention for web servers. The project directory is mounted here by Tillandsias when launching the container. Clear, predictable, no surprises.

## Risks / Trade-offs

**[Busybox httpd MIME type coverage]** Busybox httpd handles common MIME types (html, js, css, images) but may not cover exotic types (wasm, webp, avif). Mitigation: acceptable for MVP. If needed later, a `/etc/mime.types` file can be added.

**[No directory listing by default]** Busybox httpd does not serve directory listings unless an `index.html` exists. If a project has no `index.html`, the user sees a 404. Mitigation: this is correct behavior for serving web apps. Directory listing would be a security concern.

**[No live reload]** This is a static file server, not a dev server. File changes require a browser refresh. Mitigation: this is expected for a runtime image. Dev servers with live reload belong in the forge image.
