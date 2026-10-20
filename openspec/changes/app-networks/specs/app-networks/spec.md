## ADDED Requirements

### Requirement: every launched app runs on its own throw-away internal network

When Tillandsias launches an app container (a local web preview, a toolchain session, or any later app kind), it SHALL create a podman network named `tillandsias-app-<app>` with `--internal` and the label `tillandsias.app-network=<app>` immediately before the app's `podman run`, SHALL attach the app to that network and to no other, and SHALL remove the network with `podman network rm -f` on the same path that stops the app. At tray start, every network carrying the label with no attached container SHALL be removed. An app container SHALL NOT be attached to `tillandsias-enclave` or `tillandsias-egress`.

#### Scenario: an app is launched and stopped

- **WHEN** a preview app `web` is launched
- **THEN** `podman network create --internal --label tillandsias.app-network=web tillandsias-app-web` runs before the app's `podman run`, and the run carries `--network tillandsias-app-web` only
- **AND** stopping the app removes the network, and `podman network ls --filter label=tillandsias.app-network=web` is empty afterwards

#### Scenario: a crashed tray left networks behind

- **WHEN** the tray starts and a labelled app network exists with no attached container
- **THEN** it is removed and one line names it

### Requirement: an app declares one of three egress postures and the proxy is the only exit

Every app launch SHALL declare an egress posture: `none`, `allowlist` (with a list of destination domains), or `open`. In `none` the proxy SHALL NOT be connected to the app network and no proxy environment SHALL be injected. In `allowlist` and `open` the proxy SHALL be connected to the app network for the app's lifetime, the app SHALL receive the proxy environment, and the proxy SHALL hold an ACL keyed on the app network's source subnet: in `allowlist` allowing only the declared destinations, in `open` allowing every destination the proxy's TLS policy permits. No posture SHALL attach an app to a NAT network. A launch that declares no posture SHALL be refused with `refused:app-network:posture-missing`.

#### Scenario: no internet for this app

- **WHEN** an app is launched with posture `none`
- **THEN** `curl https://example.com` inside the app fails to connect, the proxy has no leg on the app network, and `HTTP_PROXY` is unset in the app

#### Scenario: internet to the safe list only

- **WHEN** an app is launched with posture `allowlist` and domains `[.pypi.org]`
- **THEN** `curl https://pypi.org/simple/` through the injected proxy returns 200 and `curl https://example.com` is denied by the proxy with a TCP_DENIED log line naming the app's ACL

#### Scenario: two apps cannot borrow each other's allowlist

- **WHEN** app `a` allows `.pypi.org` and app `b` allows nothing
- **THEN** a request from `b`'s subnet to `pypi.org` is denied, and `a` cannot reach `b`'s network address

### Requirement: the router is the app's only multi-homed neighbour and never gains egress

The router SHALL be connected to each live app network with `podman network connect` when the app starts and disconnected when it stops, so the app's hostname routes are served from the router's existing listener. The router SHALL NOT be attached to `tillandsias-egress`, and a guard SHALL refuse a `network connect` of `tillandsias-egress` into the router or any app container. The host and the browser window reach the app only through the router.

#### Scenario: the browser window reaches an app with posture none

- **WHEN** an app with posture `none` is routed as `https://web.<project>.localhost`
- **THEN** a browser window opened on that URL renders it through the window forwarder and the router, while the app itself still cannot reach the internet

### Requirement: an enclave member reaches a shared LAN service through the router and a per-service proxy ACL, never the LAN

When a fleet peer that proved the same Cloudflare-login identity announces a shared service (`inference`, `nix-cache`, `build`, `git-mirror`) on the LAN, the host SHALL route the enclave's existing alias for that service to the peer through the router, and the proxy SHALL allow that one peer address and port for that service only. A peer that has not proved the identity SHALL be ignored and counted. When the peer stops announcing, the alias SHALL fall back to the local container and one status line SHALL say so. The git mirror SHALL NOT be announced or consumed on the LAN while its push transport is unauthenticated.

#### Scenario: a forge uses macuahuitl's inference

- **WHEN** macuahuitl announces `inference` with a valid identity proof and a forge on lenovinha calls `http://inference:11434/api/tags`
- **THEN** the request is answered by macuahuitl's ollama through the router, and a request to any other LAN address from the forge is denied by the proxy

#### Scenario: an unproved announcer is ignored

- **WHEN** a `_tillandsias._tcp` record arrives whose identity proof does not verify
- **THEN** no alias changes and `discovery_ignored` increments
