# 1651-5t7n: a browser window reaches only its own project

Host: lenovinha (Fedora Silverblue, podman 5.8.7, Wayland session). Date: 2026-10-13.

Both runs below use the 1649-xqet live harness on a **private podman store**:
- a scratch CA in a private HOME;
- the real router image as `tillandsias-router`, with routes for project
  `demo` and project `other`;
- stand-in dev servers for both projects.

The harness then runs
`browser_open::tests::live_browser_open_runs_the_container_on_its_own_network`.

In both runs, the operator's inference, dev-inference and router containers,
the operator's network list, the netavark runtime dir and
`$XDG_RUNTIME_DIR/tillandsias/browser` were unchanged before and after
(`*/op-*`).

## Red: the 1649-xqet tree, with the escapes turned into assertions

`red/`: branch head d4caa5b13 (#391), with the probe's escape checks asserted.
The router joins the window's network directly. From inside the window
container:

| probe | result |
|---|---|
| `raw-own-project`: SNI and Host `www.demo.localhost` | 200 `PREVIEW-DEMO` |
| `raw-sni-other-project`: SNI and Host `www.other.localhost` | **200 `PREVIEW-OTHER`** |
| `raw-host-other-project`: SNI `www.demo.localhost`, Host `www.other.localhost` | **200 `PREVIEW-OTHER`** |
| `net-router-plaintext`: TCP to `router:8080` | **reach** |

The test failed (rc 101) on its first new assertion, the plaintext reach.

## Green: the per-window forwarder plus `strict_sni_host`

`green/`: `harness.sh.txt` layers this branch's `images/router/base.Caddyfile`
onto the router image. That is the same COPY that `images/router/Containerfile`
does.

- **Window network:** its members are exactly the window and
  `tillandsias-browser-fwd-<id>`. The router is not on it.
- **Forwarder:**
  - It sits on the window network (alias `router`) and on the router's
    network.
  - It publishes nothing (`ports=[]`).
  - It dials the router by IP, so it never resolves `router`, which on the
    window's network is itself.
- **Window:**
  - It has no TCP listener.
  - No chrome process appeared on the host.
  - Its own request reached the demo dev server.
- **Chromium**, run with the window's own flags:
  - The preview route renders `PREVIEW-DEMO`.
  - `http://web.demo.localhost:8080/` now gives `ERR_EMPTY_RESPONSE`: there is
    no plaintext route.
  - Every other name and IP gives `ERR_NAME_NOT_RESOLVED`.
- **Raw probes:**

| probe | result |
|---|---|
| `raw-own-project` | 200 `PREVIEW-DEMO` (control) |
| `raw-sni-other-project` | `ECONNRESET`: the forwarder refused the SNI |
| `raw-host-other-project` | **421**: Caddy `strict_sni_host` |
| `net-router-plaintext` | `ECONNREFUSED` |

- **Close:** the window, the forwarder and the window network are all gone.

## Design notes

- **Forwarder.** It is `crates/tillandsias-headless/src/browser_window_forwarder.js`,
  run as `node -e` from the chromium-framework image. That image already has
  node, so no image change is needed.
  - It reads the first TLS record and takes the SNI from the ClientHello.
  - It passes the bytes on untouched only when the SNI ends in
    `.<project>.localhost`.
  - It closes the connection on plaintext, a missing SNI, another project, or
    a malformed hello.
- **Second network.** The forwarder joins the router's network with
  `podman network connect` after it starts, because ContainerSpec's passthrough
  allowlist refuses a second `--network`. It dials upstream only per
  connection, so the order is safe.
- **Router.** `strict_sni_host on` is set in the router's global `servers`
  block. It applies only to TLS connections; the `:8080` http ingress is
  unaffected. The litmus checks `reverse-proxy-internal`, `local-web-preview`
  and `enclave-network` stay green.
- **Resolver.** The rules are now
  `MAP *.<p>.localhost router:8443, MAP * ~NOTFOUND`: there is no plaintext
  mapping. `browser.open` still admits `http://<svc>.<p>.localhost:8080` URLs,
  and such a window opens but cannot load. Whether the allowlist should refuse
  plaintext URLs in container mode is left to the coordinator.
