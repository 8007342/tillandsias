# Web servers inside the Tillandsias forge

You are running inside a **Tillandsias forge container**
(`TILLANDSIAS_HOST_KIND=forge`; your project is `$TILLANDSIAS_PROJECT`).
Two distinct web flows exist — pick by the user's intent:

1. **Iterating on a dev server** ("run my app", hot reload, debugging) —
   run the framework's dev server *inside the forge*, following the strict
   conventions below.
2. **Hosting/publishing the project** ("host this project", "serve this
   locally", "publish this") — do **NOT** run a server in the forge.
   A web service lives in a **sibling container** on the enclave, managed
   by the host. Delegate through the Tillandsias MCP tools (the
   `host-browser` MCP server carries them):

   - `publish_local {"category": "WEB"}` — the host launches
     `tillandsias-<project>-web` serving your project's worktree and
     returns `https://www.<project>.localhost` for the user. Idempotent:
     re-publishing replaces the container, same URL.
   - `service_status {}` — the published service's state.
   - `service_stop {"category": "WEB"}` — stop it and remove its route.

   Safety model: the host attributes the project from **your session**
   (never from the request), so you can only ever publish the project you
   are working in. You cannot widen mounts, ports, or categories from in
   here — that is by design; don't try to work around it with raw podman
   (there is no podman in the forge) or port publishing.

   Publishing is **local-only by default** (`*.localhost`, loopback).
   Public sharing via Cloudflare tunnels is a planned capability — when a
   user asks to share publicly today, publish locally and tell them the
   public-share flow is coming.

When the user asks you to run a dev server (Flutter web, Vite, Next.js,
Storybook, Jupyter, an HTTP API, etc.) the convention is **strict**.
Follow it exactly. Don't improvise hostnames or port numbers.

## URL the user opens

```
http://<project>.<service>.localhost/
```

- `<project>` — the project's directory name (e.g., `lakanoa`,
  `java`). You can read it from the `TILLANDSIAS_PROJECT` env var.
- `<service>` — the kind of server (see "Service ports" below).
- Port `80` is **always** implicit. Never include a port in the URL
  you give the user.

Examples:

```
http://lakanoa.flutter.localhost/
http://java.opencode.localhost/
http://thinking-service.vite.localhost/
http://my-api.next.localhost/
```

## How to bind the server inside the forge

Bind to **`0.0.0.0` on the conventional port for that service**. Never
bind to `localhost` or `127.0.0.1`:

- `localhost` inside the forge container points at the *container's
  own loopback*, not the host. The Tillandsias router can't reach it.
- `0.0.0.0` accepts connections from the enclave network — the only
  network the forge can be reached on. The enclave is firewalled off
  from the user's LAN by the host network namespace, so binding
  `0.0.0.0` is **not** an external exposure.

### Service ports (use these exactly)

| `<service>`   | Internal port | Recommended launch flags |
|---------------|---------------|--------------------------|
| `opencode`    | 4096          | (handled by entrypoint) |
| `flutter`     | 8080          | `flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080` |
| `vite`        | 5173          | `vite --host 0.0.0.0 --port 5173` |
| `next`        | 3000          | `next dev -H 0.0.0.0 -p 3000` |
| `storybook`   | 6006          | `storybook dev -h 0.0.0.0 -p 6006` |
| `webpack`     | 8080          | `webpack-dev-server --host 0.0.0.0 --port 8080` |
| `jupyter`     | 8888          | `jupyter notebook --ip 0.0.0.0 --port 8888` |
| `streamlit`   | 8501          | `streamlit run app.py --server.address 0.0.0.0 --server.port 8501` |
| `python-http` | 8000          | `python -m http.server 8000 --bind 0.0.0.0` |

If the framework you need isn't in this list, pick the framework's
default port and tell the user: "I'm running it as
`<project>.<framework>.localhost` — you can adjust the alias if you
want." The router accepts arbitrary `<service>` segments by convention.

### Example: Flutter web

User asks: "Run my Flutter app."

You should:

```bash
cd /home/forge/src/$TILLANDSIAS_PROJECT
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080
```

And tell the user:

> Flutter web running. Open
> `http://$TILLANDSIAS_PROJECT.flutter.localhost/` in your browser.

Substitute the actual project name in the URL. **Do not** print
`http://localhost:8080` — that URL is meaningless to the human.

## Self-testing the server from inside the forge

If you want to verify the server is up before telling the user, use
`curl` from inside the forge:

```bash
curl -fsS http://$TILLANDSIAS_PROJECT.flutter.localhost/
```

The forge has `HTTP_PROXY=http://proxy:3128` set, and the proxy
recognises `*.localhost` as enclave-internal traffic. The request goes
through the proxy to the router and back to the right container. You
do not need to do anything special — `curl` and friends pick up the
proxy automatically.

## Things you must NOT do

- **Never** publish container ports to the host with `-p <port>:<port>`
  or `--publish`. The Tillandsias router handles all host-side access.
  Adding `-p` would expose the server outside the enclave.
- **Never** suggest `http://localhost:<port>` to the user — that URL
  refers to the container's loopback, not the host's, and the user
  can't reach it.
- **Never** bind to `127.0.0.1` inside the container — same reason.
- **Never** include a port number in the URL you give the user. Always
  port 80 (implicit).
- **Never** open external firewall ports, modify `/etc/hosts`, or ask
  the user to. The `*.localhost` routing is automatic.

## Why this works

`*.localhost` resolves to `127.0.0.1` by RFC 6761 (hardcoded in
Chromium M64+, Firefox 84+, systemd-resolved v245+). The router binds
to `127.0.0.1:80` on the host. So `myproject.flutter.localhost:80`
hits the router on the user's loopback only — never reachable from
their LAN, never reachable from the internet, never going through any
external DNS resolver.
