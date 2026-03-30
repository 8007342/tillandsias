## Context

The `tillandsias-web` image exists and works. It was built as part of the `2026-03-22-web-image` change:
- `flake.nix` defines `web-image` output: Alpine-based, busybox, httpd on port 8080
- `images/web/entrypoint.sh` prints a banner and execs `httpd -f -p 8080 -h /var/www`
- `build-image.sh` accepts `web` as an argument and builds/loads the image
- `runner.rs::image_tag()` already resolves `"web"` to `"tillandsias-web:latest"`

What is missing: no UI surface (tray menu item or CLI flag) to launch a web container, no handler function, no container profile, and no document root detection logic.

**Constraints:**
- Must use the existing `tillandsias-web` image (no image changes)
- Must follow the same security model as forge containers (rootless, `--cap-drop=ALL`, etc.)
- Must NOT mount any secrets (no gh, no git, no claude, no API keys)
- Must only bind to localhost (no external network access)
- Must auto-detect the document root if possible

## Goals / Non-Goals

**Goals:**
- "Serve Here" in tray project submenu
- `tillandsias --web <path>` in CLI mode
- Auto-detect document root: check for `public/`, `dist/`, `build/`, `_site/` subdirectories; fall back to project root
- Show URL in terminal output and optionally open browser
- Web container appears in tray with a distinct icon (not a plant — maybe a globe or link emoji)

**Non-Goals:**
- Live reload or file watching (not a dev server)
- HTTPS/TLS (local development only)
- Custom httpd configuration
- CGI, PHP, or any dynamic content
- Reverse proxy to a backend service
- Multiple simultaneous web servers per project

## Decisions

### D1: Document root detection order

**Choice:** Check subdirectories in this order:
1. `<project>/public/` — Hugo, Rails, Vite default
2. `<project>/dist/` — Webpack, Parcel, Rollup default
3. `<project>/build/` — Create React App default
4. `<project>/_site/` — Jekyll, Eleventy default
5. `<project>/out/` — Next.js static export
6. `<project>/` — fallback to project root

Mount the first directory that exists. If none exist, mount the project root.

**Why:** These are the most common static output directories across web frameworks. Detecting automatically means the user never has to configure anything. Mounting `dist/` instead of the project root avoids exposing source code, node_modules, etc.

**Override:** Per-project config can specify `web.document_root = "custom/"` to override detection.

### D2: Port allocation

**Choice:** Web containers use port 8080 by default, incrementing if occupied (8081, 8082, ...). The port range is separate from forge containers (which use 3000-3019).

**Why:** Port 8080 is the conventional HTTP development port. Separating from the forge port range avoids conflicts when a forge and web container run simultaneously for the same project.

**Override:** Per-project config can specify `web.port = 9090`.

### D3: Container naming

**Choice:** `tillandsias-<project>-web` — no genus allocation. Only one web container per project.

**Why:** Web containers are stateless file servers. There is no reason to run two identical httpd instances for the same project. The simplified name (no genus) makes it clear this is a different container type.

### D4: Tray icon for web containers

**Choice:** Use the link emoji (chain links) for web container menu items: `"🔗"`.

**Why:** Distinct from plant emojis (forge) and tool emojis (maintenance). Immediately communicates "web link" to the user. Available on all platforms.

### D5: Browser open behavior

**Choice:** After the container starts, print the URL (`http://localhost:<port>`) to the terminal. Do NOT auto-open the browser.

**Why:** Auto-opening browsers is intrusive and breaks headless/SSH workflows. The URL is displayed clearly — the user can click or copy it. A future enhancement could add `web.auto_open = true` to project config.

### D6: Web container security — zero secrets

**Choice:** The web container profile mounts ZERO secrets:
- No gh directory
- No git config
- No Claude directory
- No API keys
- No cache directory

Only the document root is mounted, read-only.

**Why:** A file server has no use for credentials. Mounting secrets into a web container violates the principle of least privilege. Even though the container is sandboxed, there is no reason to give httpd access to GitHub tokens.

## Architecture

```
Tray Menu:
  My Project >
    🌿 Attach Here         (forge container)
    🐚 Maintenance          (terminal container)
    🔗 Serve Here           (web container)        <-- NEW
    Stop / Destroy

CLI:
  tillandsias <path>        (forge, default)
  tillandsias --bash <path> (terminal)
  tillandsias --web <path>  (web container)        <-- NEW
```

## Risks / Trade-offs

**[Document root detection heuristic]** The detection order may not match every framework. Mitigation: The fallback is always the project root. Per-project config provides an explicit override.

**[No live reload]** Users accustomed to `npm run dev` with hot reload will find a static file server limiting. Mitigation: This is intentional. The web container is for previewing build output, not for development. The forge container is where `npm run dev` belongs.

**[Port conflicts with host services]** Port 8080 may be occupied by other services. Mitigation: Auto-increment to the next available port. Print the actual port in the terminal output.
