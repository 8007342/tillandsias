# 1649-xqet: browser.open runs the chromium-framework container

Host: lenovinha (Fedora Silverblue, podman 5.8.7, Wayland session). Date: 2026-10-12.
Every container run here used a **private podman store** under
`target/work/` (graphroot, runroot and tmp_dir private; real
`XDG_RUNTIME_DIR` kept for netavark/aardvark). The operator's
tillandsias-inference, tillandsias-dev-inference and tillandsias-router
(id, start, health, network name:IP:MAC), the operator's network list, the
netavark runtime dir and `$XDG_RUNTIME_DIR/tillandsias/browser` were recorded
before and after each run. All were unchanged (`live/op-*`, `spike/op-*`).

## Pre-fix (red), trunk adc8d7303

`prefix-red/`: trunk's server is built as the tray builds it
(`with_project_label(.., None)`). `TILLANDSIAS_BROWSER_BIN` and
`TILLANDSIAS_CHROMIUM_BIN` are unset, and HOME has no Chromium.

| URL | trunk answer |
|---|---|
| `https://www.demo.localhost:18443/` | `URL_NOT_ALLOWED: port must be 8080 (got Some(18443))` |
| `http://web.demo.localhost:8080/` | `BROWSER_UNAVAILABLE: bundled chromium not yet downloaded` |

## Spike: what Chromium and podman actually do

`spike/`: a throwaway router stand-in (node, TLS) runs on an `--internal`
network. Chromium in the installed chromium-framework image v56.9.27.2 runs
headless. `browse-verdicts.txt` is derived from the raw DOM dumps and stderr.
`run2-summary.txt` is the second run. The first run's summary file was
overwritten, but its per-URL outputs are still the `browse-*` rows. `spike.sh.txt`
is the second-run version of the script.

- **The MAP rule remaps the port.**
  `MAP *.demo.localhost router:8443, MAP * ~NOTFOUND` sends `:18443` (and
  any port, e.g. `:9999`) to `router:8443`. Matching ignores case.
- **The catch-all also covers IP literals.**
  - `http://1.1.1.1/` and `https://router:8443/` both end in
    `ERR_NAME_NOT_RESOLVED`.
  - So does `127.0.0.1:9222` (the page cannot reach DevTools).
- **SPKI pin: the CA works only when the server sends it in the chain.**
  - A leaf-only server with a CA pin gives `ERR_CERT_AUTHORITY_INVALID`.
  - A leaf pin works.
  - A full chain (leaf, then CA) with the CA pin works.
  - No pin gives `ERR_CERT_AUTHORITY_INVALID`.

  Hence the router now publishes the preview leaf as a full chain, and the
  window pins the CA, which survives leaf rotation.
- **Chromium binds DevTools to `127.0.0.1` inside the container even with
  `--remote-debugging-address=0.0.0.0`** (listener `0100007F:2406`).
  A host-side CDP path would need a relay. None ships (see "No CDP from the host").
- **The host can reach a port published from a container that is only on an
  `--internal` network.**

## Post-fix (green), live

`live/`: `harness.sh.txt` sets up a private store with:
- a scratch enclave CA in a private HOME;
- the real router image (v56.9.27.2, retagged v56.10.12.1) as
  `tillandsias-router`, with the product's route shapes for project `demo` and
  project `other`;
- stand-in dev servers for both projects, each logging every request;
- the installed chromium-framework image, unchanged and retagged.

It then runs
`browser_open::tests::live_browser_open_runs_the_container_on_its_own_network`,
which drives the real `browser.open` path (`TrayBrowserContainers`). The test
pins the preview port, because the real runtime dir's router state is not ours
to write. Reading `preview-tls-port` is `local_web_preview::tls_port`, which is
unchanged.

**Criterion (a): met.**
- `browser.open https://www.demo.localhost:18443/` returns a window.
- `podman ps` shows `tillandsias-browser-demo-<id>` on
  `tillandsias-browser-net-<id>` alone, with **no published port**. The
  window has **no TCP listener** (`/proc/net/tcp` is empty of LISTEN rows),
  and Chromium gets no DevTools port.
- No chrome process appeared in the host's mount namespace (before `[]`,
  after `[]`).
- On close, the container and the network are gone, and the router is
  detached from the network.

**Criterion (b), browser and network level: met.**
- The window itself loaded the preview route: the demo dev server logged
  `GET / host=www.demo.localhost:18443`.
- A headless Chromium inside the window container, run with the window's own
  `--host-resolver-rules` and SPKI pin (read from its command line):
  - renders `PREVIEW-DEMO` at the preview URL and at
    `http://web.demo.localhost:8080/`;
  - gets `ERR_NAME_NOT_RESOLVED` for `www.other.localhost:18443`,
    `example.com`, `1.1.1.1` and the host LAN IP.
- At the network level from the container:
  - the router is reachable;
  - the other project's dev server is unresolved;
  - the external name is unresolved;
  - the external IP, the host LAN IP and `host.containers.internal` are
    unreachable (`ENETUNREACH`).

**Residual, measured and not asserted.** A process inside the container
that bypasses Chromium can send `router:8443` the SNI and Host
`www.other.localhost`. It gets **200 `PREVIEW-OTHER`**. The shared router
routes by Host/SNI across every project. The coordinator scoped (b) to the
browser and network level for this row. The p1 follow-up is a per-window
SNI-bound forwarder plus `strict_sni_host`, dropping the http:8080 mapping.

**Criterion (c): met.** Shown by unit tests:
- `browser_open_admits_the_preview_tls_port_and_refuses_other_localhost_ports`;
- `without_a_preview_listener_the_preview_port_is_refused`.

Those tests show:
- the preview URL is admitted;
- `:18444`, `:8443`, http on `:18443`, another project on `:18443`, and
  `127.0.0.1:18443` are refused;
- with no preview listener, `:18443` is refused.

## No CDP from the host, by design

An earlier revision of this branch relayed the container's DevTools port to a
host-loopback port. It worked (`Chrome/154` answered `/json/version`), but it
was a new host TCP listener that handed full control of the window, cookies
included, to every local process. At the coordinator's direction it was
removed. Dev-mode CDP will reach a window only through a per-lane Unix socket
that the tray brokers (the dev-mode broker row).

`browser.screenshot`, `click` and `type` have never worked against any
Chromium. `CdpSession` writes NUL-terminated JSON to the DevTools HTTP port,
which is the `--remote-debugging-pipe` framing, not WebSocket. So nothing
loses function. That row also fixes the framing.
