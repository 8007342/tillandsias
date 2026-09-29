## ADDED Requirements

### Requirement: every Cloudflare name Tillandsias mints comes from one normalizer

A pure module `cloudflare_names` SHALL provide `normalize_label` (lowercase
ASCII `[a-z0-9-]`, no leading, trailing or doubled hyphen, at most 63
characters — the DNS-label rule that the Zero Trust team name, Mesh
hostname-route labels and participant names are subject to) and
`normalize_display` (same alphabet, at most 255 characters — the largest
documented cap, 256 for a virtual network name, minus one for safety), with
distinct result types so a `Display` cannot be passed where a `Label` is
required. It SHALL provide the canonical constructors `network_name()` =
`tillandsias-vpn`, `team_name(account_id)` = `tillandsias-vpn-<first 8 hex
of the account id>`, `participant_name(hostname)` = `tillandsias-<normalized
hostname>` truncated to 63, and `service_route(service)` =
`<service>.tillandsias-vpn.internal`. Any input that normalizes to the empty
string SHALL be refused, never defaulted.

#### Scenario: a hostname with spaces and case becomes a label

- **WHEN** `participant_name("Tlatoani's MacBook Air")` is called
- **THEN** it returns `tillandsias-tlatoanis-macbook-air`

#### Scenario: the network name is fixed

- **WHEN** `network_name()` is called on any host
- **THEN** it returns `tillandsias-vpn`

#### Scenario: an over-long hostname is truncated to a valid label

- **WHEN** `participant_name` is given a 100-character hostname
- **THEN** the result is at most 63 characters, ends in `[a-z0-9]`, and
  re-normalizes to itself

### Requirement: fleet-vpn init is idempotent and names its steps

`tillandsias --fleet-vpn init` SHALL, using the stored Cloudflare bundle:
resolve the account; verify the Zero Trust organization `team_name(account)`
exists and otherwise refuse with `refused:fleet-vpn:no-zero-trust-org:<team_name>`
naming the dashboard step; ensure the virtual network `tillandsias-vpn`;
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
- **THEN** stdout is `refused:fleet-vpn:no-zero-trust-org:tillandsias-vpn-<acct8>`
  followed by the dashboard step, and no service token is minted

### Requirement: joining on Linux bare metal writes the managed file and proves registration

`tillandsias --fleet-vpn join` on a Linux host SHALL detect the Cloudflare
One Client service; when absent it SHALL print the install step for the
substrate (`dnf install cloudflare-warp` on mutable Fedora, `rpm-ostree
install cloudflare-warp` then reboot on an ostree host) and refuse with
`refused:fleet-vpn:client-absent`, never installing with elevated
privileges itself. When present it SHALL produce `/var/lib/cloudflare-warp/mdm.xml`
with `organization` = the team name, `auth_client_id` / `auth_client_secret`
from `secret/cloudflare/mesh`, `service_mode` `warp`, `auto_connect` `1`,
`onboarding` `false`, verify `warp-cli --accept-tos registration show` and
`status`, and record the Mesh IP at `secret/cloudflare/mesh.mesh_ip`.
`--fleet-vpn leave` SHALL delete the registration, delete this host's
service token through the API, remove the managed file and clear
`secret/cloudflare/mesh`. `--fleet-vpn status` SHALL print one fact per line
(`org`, `client`, `registration`, `mesh_ip`, `route:<service>`) and print
`unknown:<why>` for any fact it cannot read.

#### Scenario: an absent client is a printed step

- **WHEN** `--fleet-vpn join` runs with no `warp-svc` on PATH
- **THEN** it exits non-zero with `refused:fleet-vpn:client-absent` and
  the printed step names the package manager of the running substrate

#### Scenario: join with a fake warp-cli lands the managed file

- **WHEN** `--fleet-vpn join` runs with a fake `warp-cli` that reports a
  registration and a Mesh IP
- **THEN** the managed file contains the team name and the token client id
  and not the OAuth access token
- **AND** `secret/cloudflare/mesh.mesh_ip` equals the fake's reported IP

### Requirement: macOS and Windows join through the Linux guest

On macOS and Windows the host operating system SHALL NOT be enrolled;
`--fleet-vpn join` SHALL provision the Cloudflare One Client inside the
Linux guest (Virtualization.framework VM, WSL2 distro), hand the service
token to the guest over the existing host-to-guest credential channel, have
the guest's `tillandsias-headless` write the managed file and register, and
relay `status` to the host tray. The guest SHALL be the Mesh participant;
the design accepts that host-native tools on these platforms are not on the
mesh.

#### Scenario: the guest holds the registration

- **WHEN** `--fleet-vpn status` runs on a joined macOS or Windows host
- **THEN** `registration` and `mesh_ip` are the guest's values and `client`
  reads `guest`

### Requirement: the daemon-free spoke is measured, not assumed

Before any spoke is designed without the host daemon, a research packet
SHALL run the Cloudflare One Client in `service_mode` `proxy` inside a
rootless container on a Linux host and record exactly one of
`reaches-mesh`, `registers-but-no-mesh`, `cannot-register-unprivileged`,
`package-refuses-container` against a hub's Mesh IP and hostname route, with
the regime (client version, podman version, kernel) attached.

#### Scenario: the outcome is one of four named tokens

- **WHEN** the measurement script finishes
- **THEN** its last stdout line is `outcome:<one of the four tokens>` and
  the preceding lines carry the regime

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
