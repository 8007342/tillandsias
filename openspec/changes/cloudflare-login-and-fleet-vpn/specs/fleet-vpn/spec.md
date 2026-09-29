## ADDED Requirements

### Requirement: every Cloudflare name Tillandsias mints comes from one normalizer

A pure module `cloudflare_names` SHALL provide `normalize_label` (lowercase
ASCII `[a-z0-9-]`, no leading, trailing or doubled hyphen, at most 63
characters — the DNS-label rule that the Zero Trust team name, Mesh
hostname-route labels and participant names are subject to) and
`normalize_display` (same alphabet, at most 255 characters — the largest
documented cap, 256 for a virtual network name, minus one for safety), with
distinct result types so a `Display` cannot be passed where a `Label` is
required. It SHALL provide the canonical constructors (operator ruling
2026-09-29, superseding the earlier `tillandsias-vpn` / `tillandsias-vpn-<acct8>`
table) `network_name()` = `tillandsias-enclave-vpn`,
`team_name(github_login, suffix)` = `tillandsias-enclave-vpn-<normalized
GitHub login>` with `-2`, `-3`… appended when `suffix` is greater than 1
(the GitHub login is public, unique and at most 39 characters, so the label
fits 63; no Cloudflare account id or email ever appears in a name),
`participant_name(hostname)` = `tillandsias-<normalized hostname>` truncated
to 63, and `service_route(service)` =
`<service>.tillandsias-enclave-vpn.internal` (the route suffix follows the
network name). Any input that normalizes to the empty string SHALL be
refused, never defaulted.

#### Scenario: the team name is the GitHub login, suffixed only on collision

- **WHEN** `team_name("BullonCito", 1)` and `team_name("BullonCito", 2)` are called
- **THEN** they return `tillandsias-enclave-vpn-bulloncito` and `tillandsias-enclave-vpn-bulloncito-2`

#### Scenario: a hostname with spaces and case becomes a label

- **WHEN** `participant_name("Tlatoani's MacBook Air")` is called
- **THEN** it returns `tillandsias-tlatoanis-macbook-air`

#### Scenario: the network name is fixed

- **WHEN** `network_name()` is called on any host
- **THEN** it returns `tillandsias-enclave-vpn`

#### Scenario: an over-long hostname is truncated to a valid label

- **WHEN** `participant_name` is given a 100-character hostname
- **THEN** the result is at most 63 characters, ends in `[a-z0-9]`, and
  re-normalizes to itself

### Requirement: fleet-vpn init is idempotent and names its steps

`tillandsias --fleet-vpn init` SHALL, using the stored Cloudflare bundle:
resolve the account; obtain the GitHub login from `--github-user <login>` or,
absent that, from the stored GitHub bundle's user; read the account's Zero
Trust organization and accept it iff its team name is
`team_name(login, n)` for some n, printing
`note:fleet-vpn:team-name-suffixed:<name>` when n is greater than 1;
otherwise refuse with `refused:fleet-vpn:no-zero-trust-org:<team_name>`
naming the dashboard step (create the organization by hand with that exact
team name; on a collision take the next suffix and report it). Neither
`init`, `leave` nor any fixture SHALL delete or rename a Zero Trust
organization: a deleted organization's team name is permanently reserved;
the fake's ledger SHALL never record a DELETE on the organization route; ensure the virtual network `tillandsias-enclave-vpn`;
ensure the default device profile uses MASQUE and its Split Tunnels route
`100.96.0.0/12` through Cloudflare; ensure the Gateway proxy is on for TCP and
UDP and one network policy allows `100.96.0.0/12` to `100.96.0.0/12`; mint a
service token named `participant_name(hostname)` with duration `8760h` and
store `client_id`, `client_secret`, `expires_at`, `team_name` at
`secret/cloudflare/mesh`. Every step SHALL print exactly one of
`ok:fleet-vpn:<step>`, `skip:fleet-vpn:<step>:exists` or
`refused:fleet-vpn:<step>:<why>`, and the command SHALL print the account's
Mesh node and service-token counts it read. The API base SHALL come from
`TILLANDSIAS_CLOUDFLARE_API_BASE_URL`.

#### Scenario: a second init writes nothing

- **WHEN** `--fleet-vpn init` runs twice against the fake
- **THEN** the second run prints only `skip:` lines
- **AND** the fake's ledger records no write between the two runs' markers

#### Scenario: a missing organization is a dashboard remedy, not a stack trace

- **WHEN** the fake reports no Zero Trust organization
- **THEN** stdout is `refused:fleet-vpn:no-zero-trust-org:tillandsias-enclave-vpn-<github_login>`
  followed by the dashboard step, and no service token is minted

#### Scenario: a suffixed organization is accepted and reported

- **WHEN** the fake's organization is named `tillandsias-enclave-vpn-<github_login>-2`
- **THEN** init prints `note:fleet-vpn:team-name-suffixed:tillandsias-enclave-vpn-<github_login>-2` and continues

#### Scenario: the organization is never deleted

- **WHEN** `--fleet-vpn leave` and every fixture in this change run against the fake
- **THEN** the fake's ledger holds no DELETE or rename on the organization route

### Requirement: the Cloudflare One Client runs in a sidecar beside the router, never on a host OS

AMENDED 2026-09-29 (1506-3xu7): this requirement replaces the earlier
"joining on Linux bare metal writes the managed file", "macOS and Windows
join through the Linux guest" and "the daemon-free spoke is measured"
requirements of this delta.

`tillandsias --fleet-vpn join` SHALL NOT install, start or configure any
process on the host operating system. It SHALL write `mdm.xml`
(`organization` = the team name, `auth_client_id` / `auth_client_secret`
from `secret/cloudflare/mesh`, `service_mode` `warp`,
`warp_tunnel_protocol` `masque`, `auto_connect` `1`, `onboarding` `false`)
into a named volume, launch the `tillandsias-warp` container from
`images/warp/` sharing the router's network namespace
(`--network container:tillandsias-router`) with exactly `--cap-drop=ALL`,
`--cap-add=NET_ADMIN`, `--device /dev/net/tun`,
`--sysctl net.ipv4.conf.all.src_valid_mark=1`, `--userns=keep-id`,
`--user 0`, `--read-only`, and no other capability or device; verify
`warp-cli --accept-tos registration show` and `status` through `podman
exec`; and record the Mesh IP at `secret/cloudflare/mesh.mesh_ip` and in
`plan/fleet/peers/<host>.yaml`. The sidecar's launch arguments SHALL come
from a dedicated `warp` profile in `container_spec`, never from a generic
capability pass-through. `--fleet-vpn leave` SHALL remove the container and
the volume, delete this host's service token through the API and clear
`secret/cloudflare/mesh`. `--fleet-vpn status` SHALL print one fact per line
(`org`, `client`, `registration`, `mesh_ip`, `route:<service>`) read from
the sidecar and print `unknown:<why>` for any fact it cannot read. On macOS
and Windows the guest's router SHALL host the same sidecar and the guest
headless SHALL perform the join; the host tray relays `status` with
`client` reading `guest`. `init` SHALL print the account plan it read,
SHALL call no billing or subscription route, and SHALL refuse
`refused:fleet-vpn:paid-feature:<step>` for any step whose answer names a
paid feature.

#### Scenario: join launches exactly the sidecar profile

- **WHEN** `--fleet-vpn join` runs with a fake `podman` on PATH that records its arguments
- **THEN** the recorded `run` carries `--network container:tillandsias-router`, `--cap-drop=ALL`, `--cap-add=NET_ADMIN`, `--device /dev/net/tun` and `--userns=keep-id`, and no `--privileged`, no other `--cap-add` and no other `--device`
- **AND** no `sudo`, `systemctl` or `/var/lib/cloudflare-warp` path is touched on the host

#### Scenario: join with a fake warp-cli records the Mesh IP twice

- **WHEN** the fake sidecar's `warp-cli` reports a registration and a Mesh IP
- **THEN** `secret/cloudflare/mesh.mesh_ip` and `plan/fleet/peers/<host>.yaml` `mesh_ip` both equal the reported IP and `mdm.xml` in the volume carries the token client id and not the OAuth access token

#### Scenario: the guest holds the registration

- **WHEN** `--fleet-vpn status` runs on a joined macOS or Windows host
- **THEN** `registration` and `mesh_ip` are the guest's values and `client` reads `guest`

### Requirement: the rootless sidecar is measured before join depends on it

Before `--fleet-vpn join` is wired to the sidecar, a research packet SHALL
run the Cloudflare One Client in WARP mode inside the `tillandsias-warp`
container beside a running router on a Linux host and record exactly one of
`mesh-ip-acquired`, `tun-denied-rootless`, `firewall-refused`,
`package-refuses-container`, `registers-no-mesh-ip`, with the regime
(client version, podman version, kernel, host) attached. Proxy mode SHALL
NOT be measured: the Mesh documentation excludes it.

#### Scenario: the outcome is one of five named tokens

- **WHEN** the measurement script finishes
- **THEN** its last stdout line is `outcome:<one of the five tokens>` and the preceding lines carry the regime

### Requirement: the tray shows the network and the login

The tray body SHALL carry a `Cloudflare Login` item (`MenuId::CLOUDFLARE_LOGIN`)
visible only while no Cloudflare bundle is stored, launching
`tillandsias --cloudflare-login` in a terminal the way `GitHub Login` does,
and a `Fleet VPN:` row reading `joined <mesh_ip>`, `not joined` or `client
absent`. macOS and Windows SHALL render the same rows from the same menu
body.

#### Scenario: the login row hides once stored

- **WHEN** the stored-bundle signal fires after a login
- **THEN** the next menu render has no `Cloudflare Login` row and the
  `Fleet VPN:` row is present
