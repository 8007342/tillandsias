# Cloudflare login, TILLANDSIAS-VPN and fleet experts: research and design (milestone 1505-sm2j)

- classification: research + design
- filed: 2026-09-29 (linux/macuahuitl, design-lead session, worktree
  `worktree-agent-ae9525e76ba6c53c8` off linux-next `552af2544`)
- status: designed — packets filed under `plan/index.d/`; nothing implemented
- change: `openspec/changes/cloudflare-login-and-fleet-vpn/`
- desired release: v0.6 (v0.5 is full)
- companion (v0.7): `plan/issues/coding-expert-research-2026-09-29.md`

## Operator intent (verbatim, 2026-09-29)

1. `tillandsias --cloudflare-login`, analogous to `--github-login` (device
   flow + QR). The operator will create a Cloudflare App with a small set of
   permissions.
2. Every instance signed in with the SAME Cloudflare account joins ONE
   private network, "TILLANDSIAS-VPN"; normalize every name per Cloudflare's
   own rules; say exactly what the public App needs.
3. Purpose: share ONE off-forge orchestrator with the whole fleet, e.g.
   macuahuitl serving its Local Experts as FLEET EXPERTS.

## Research answers

### 1. Does Cloudflare offer the OAuth device authorization grant? NO.

Cloudflare's own OAuth-client documentation states, verbatim: "Cloudflare
does not support Client Credentials, Implicit, Resource Owner Password
Credentials, Device Authorization, or other OAuth grant types for third-party
clients." The only supported grant is Authorization Code; for "browser-based,
mobile, desktop, or CLI" apps PKCE is "Required, `S256`" and the token
endpoint auth method is `none`.

- https://developers.cloudflare.com/fundamentals/oauth/create-an-oauth-client/
- https://developers.cloudflare.com/changelog/post/2026-06-03-public-oauth-clients/
  (self-managed OAuth clients; private by default, public after domain
  verification)
- https://developers.cloudflare.com/api/resources/iam/subresources/oauth_clients/methods/create
  (`grant_types` enum is exactly `authorization_code`, `refresh_token`;
  `token_endpoint_auth_method` enum `none | client_secret_basic |
  client_secret_post`; scopes are dot-delimited, colon-delimited refused;
  `openid`/`offline_access` are added automatically)

Endpoints (SECONDARY source, a practitioner write-up; the implementer MUST
confirm them from `https://dash.cloudflare.com/.well-known/openid-configuration`
before hard-coding): authorize `https://dash.cloudflare.com/oauth2/auth`,
token `https://dash.cloudflare.com/oauth2/token`, revoke
`https://dash.cloudflare.com/oauth2/revoke`, userinfo
`https://dash.cloudflare.com/oauth2/userinfo`. Same source: the redirect URI
must match a registered one exactly "including scheme, host, port, path, and
whether there is a trailing slash"; loopback `http://127.0.0.1:<port>/…` is
accepted for desktop/CLI apps; custom schemes (`myapp://`) are rejected.
- https://www.ubitools.com/cloudflare-oauth-client/ (secondary)

Token lifetimes: NOT documented on any page read (unverified). The design
treats them as unknown and reads `expires_in` from the token response, the
same way the GitHub bundle records `expires_at`.

Wrangler precedent: Cloudflare's own CLI uses Authorization Code + PKCE with
a browser and a loopback redirect, and refresh tokens.
- https://blog.cloudflare.com/wrangler-oauth/

CONSEQUENCE. A QR code cannot carry a loopback redirect: the phone that
scans it is redirected to `127.0.0.1` ON THE PHONE, not on the host. The
design below therefore has three receivers for the same PKCE flow (loopback,
relay page, manual paste) and states the trade-off in the change's design.md.
The GitHub device-flow shape (`run_github_device_login`,
`parse_device_code_response`, `device_poll_script`) is kept as a future
adapter: if the well-known document ever lists
`urn:ietf:params:oauth:grant-type:device_code`, the login switches to it
without changing the Vault contract.

### 2. Which product puts all devices of one account on one private network?

**Cloudflare Mesh** inside a Zero Trust organization. Cloudflare's docs:
"Cloudflare Mesh was previously known as WARP Connector and peer-to-peer
connectivity." Participants "can communicate by IP over TCP, UDP, or ICMP,
including device-to-device connections"; each enrolled participant receives
a private Mesh IP from `100.96.0.0/12` by default. The get-started page
requires "a Zero Trust organization" with "an active subscription, including
the Free plan" — so Mesh is available on the Free plan.

- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/get-started/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/private-net/peer-to-peer/
  (redirects to Mesh)
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/guides/connect-client-devices/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/features/routes/

Two participant kinds:
- **Client device** — Windows, macOS, Linux, iOS, Android running the
  Cloudflare One Client, enrolled interactively (identity provider) or, for
  headless devices, "Service Auth enrollment with managed deployment
  parameters".
- **Mesh node** — "run the Cloudflare One Client in headless mode on Linux";
  supported: "RHEL 9, RHEL 10, Debian 12, Debian 13, Fedora 43, Fedora 44,
  Ubuntu 22.04 LTS, Ubuntu 24.04 LTS, Ubuntu 26.04 LTS"; can advertise CIDR
  and hostname routes for things that cannot run the client.

Requirements that the join packets must set: device profile on MASQUE
("Cloudflare Mesh requires that the Mesh node's device profile is configured
to use MASQUE"; WireGuard disables hostname routes); Split Tunnels must route
`100.96.0.0/12` through Cloudflare; Gateway proxy on for TCP and UDP (ICMP for
diagnostics); Traffic+DNS mode ("DNS-only mode cannot carry Mesh traffic");
Windows may need a firewall rule for `100.96.0.0/12`.

**A client daemon is needed on every participant.** `warp-svc` runs as root;
headless enrollment is a service token written to `mdm.xml`
(`organization`, `auth_client_id`, `auth_client_secret`, `service_mode:
warp`, `auto_connect: 1`, `onboarding: false`) at `/var/lib/cloudflare-warp/mdm.xml`
(Linux), `/Library/Application Support/Cloudflare/mdm.xml` (macOS, manual
placement documented as working without an MDM), `C:\ProgramData\Cloudflare\mdm.xml`
(Windows). Service-token devices appear as
`non_identity@<team-name>.cloudflareaccess.com` and "don't support
identity-provider-based policies" — so FLEET EXPERTS needs application-level
auth, not Gateway identity.
- https://developers.cloudflare.com/cloudflare-one/tutorials/deploy-client-headless-linux/
- https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/mdm-deployment/
- https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/mdm-deployment/parameters/

Platform verdicts:
- Linux mutable (Fedora Workstation): supported node OS; `dnf install
  cloudflare-warp` from `pkg.cloudflareclient.com` (EPEL required on RHEL).
- Linux immutable (Silverblue): NOT mentioned anywhere (unverified);
  expected path is `rpm-ostree install cloudflare-warp` + reboot. The
  toolbox-first rule cannot carry this tool: the client owns a TUN device and
  runs as a root system service. This is the one host daemon the design
  asks for, and only on hosts that must be reachable (hubs); see the spoke
  research packet 1505-m63i for the daemon-free alternative.
- macOS and Windows: the host OS needs NO client. The project's Linux guest
  (Virtualization.framework VM / WSL2 distro) is a supported Linux node OS
  and runs the headless client; the mesh is reachable from the guest and its
  containers, which is where the forges and the experts live. Trade-off:
  host-native tools on macOS/Windows cannot reach the mesh; accepted for
  v0.6.
- Inside Linux VM guests generally: supported (headless Linux node).

Limits (official account-limits page): Mesh nodes 50/account, service tokens
50/account, virtual networks 1,000, tunnels 1,000, device profiles 30,
Gateway network policies 500. Free-plan seat count: 50 users (Cloudflare's
plans page did not render for the fetch; the 50-user figure is from
secondary sources and the community forum — treat as unverified-official).
Whether a service-token enrolled device consumes a seat: unverified.
- https://developers.cloudflare.com/cloudflare-one/account-limits/
- https://community.cloudflare.com/t/50-user-limit-on-free-plan/546057 (secondary)

Local proxy mode (`service_mode: proxy`, SOCKS5/HTTP on `127.0.0.1:40000`,
MASQUE only, Windows/Linux/macOS) exists; whether it carries Mesh traffic and
whether it runs unprivileged inside a rootless container is unverified —
that is packet 1505-m63i's multi-outcome measurement.
- https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/

### 3. Naming rules found (and where none is documented)

| Object | Documented rule | Source |
|---|---|---|
| Zero Trust team name | the `<team-name>` label of `<team-name>.cloudflareaccess.com`; "Use the name of your organization without spaces"; changeable unless dashboard SSO is on; a deleted org's name is permanently reserved | getting-started FAQ; learning path |
| Virtual network `name` | string, maxLength 256 | API: virtual_networks/create |
| Tunnel `name` | "A user-friendly name for a tunnel" — no length or pattern documented (unverified) | API: tunnels/cloudflared/create |
| Service token `name` | "The name of the service token" — no constraint documented (unverified) | API: access/service_tokens/create |
| OAuth `client_name` | "Human-readable name of the OAuth client" — no constraint documented (unverified) | API: iam/oauth_clients/create |
| Mesh hostname route | "Must be less than 255 characters"; a single `*` allowed only as a full DNS label; leading/trailing dots trimmed | Mesh routes page |
| Mesh node name | entered in the wizard; constraint not documented (unverified) | Mesh get-started |
| Device name in the dashboard | not documented; assumed the OS hostname (unverified) | — |

Normalization the change adopts (`cloudflare_names` module, packet
1505-iky3): every name Tillandsias mints is a DNS-label-safe string —
lowercase ASCII `[a-z0-9-]`, no leading or trailing hyphen, no double
hyphen — because that is the strictest rule any Cloudflare object above
imposes (the team name is literally a DNS label), and one alphabet keeps the
same string valid everywhere. Two length classes: `Label` (≤ 63, RFC 1035,
for team name, node/device/host labels and hostname-route labels) and
`Display` (≤ 255, for virtual network, tunnel, service token and OAuth
client names). The canonical names:

| Thing | Canonical | Class |
|---|---|---|
| the network (virtual network + route suffix) | `tillandsias-enclave-vpn` | Display / Label |
| Zero Trust team name | `tillandsias-enclave-vpn-<github_login>` (the operator's GitHub login, normalized; public, unique, ≤ 39 chars so it fits 63; `-2`, `-3`… on a collision, reported; never an account id or email) | Label |
| a participant (node, device, service token) | `tillandsias-<host>` where `<host>` is the normalized OS hostname, truncated so the whole label ≤ 63 | Label |
| a service's hostname route | `<service>.tillandsias-enclave-vpn.internal` (e.g. `fleet-experts.tillandsias-enclave-vpn.internal`) | Label per component |
| the OAuth App (operator-entered) | `Tillandsias` | Display |

`.internal` is used as the suffix because Mesh hostname routes are private
names resolved by Gateway; a public TLD would collide with real DNS.

## Design summary (details in the change's design.md)

- **Login** — `tillandsias --cloudflare-login`: Authorization Code + PKCE
  (S256), `state` = 32 random bytes, verifier never leaves the host process.
  Three receivers of the redirect, chosen by `--via loopback|qr|paste`
  (default: loopback when a desktop session and a browser exist, else qr):
  - loopback: listener on `127.0.0.1:<one of the registered ports>`;
    opens the browser; exact-match redirect URI.
  - qr: the QR encodes the authorize URL (public data only) with the
    RELAY redirect `https://<operator-domain>/tillandsias/cloudflare/callback`;
    the relay page shows `code` for paste, and optionally posts `(state,
    code)` to a Worker the host polls. The host exchanges the code with its
    verifier. The relay never sees a token and cannot use the code.
  - paste: the operator pastes the `code` printed by the relay page.
  Result bundle written to Vault as `secret/cloudflare/token`
  (`access_token`, `expires_at`, `account_id`, `client_id`) and
  `secret/cloudflare/refresh` (`refresh_token`, `client_id`) — the same
  two-path split as `GITHUB_TOKEN_PATH` / `GITHUB_REFRESH_PATH`, for the
  same policy reason. Rotation reuses the resident due-check shape of
  1461-8tyy / 1489-8qd6 (`spawn_github_token_rotation_scheduler` is the
  model; a Cloudflare sibling is added, not a generalization).
- **Fake server** — every login/bootstrap test runs against
  `tillandsias-fake-cloudflare` (a test binary in `crates/tillandsias-headless`
  serving `/oauth2/auth`, `/oauth2/token`, `/.well-known/openid-configuration`
  and the handful of `api.cloudflare.com/client/v4` routes the bootstrap
  calls) selected by `TILLANDSIAS_CLOUDFLARE_BASE_URL` /
  `TILLANDSIAS_CLOUDFLARE_API_BASE_URL`; no packet needs the real App.
- **Fleet VPN** — `tillandsias --fleet-vpn init|join|leave|status`. `init`
  (once per account, with the OAuth token) ensures the normalized virtual
  network, the MASQUE device profile, the split-tunnel include, the Gateway
  network policy for `100.96.0.0/12` inside the org, and mints ONE service
  token per host (`tillandsias-<host>`); `join` writes `mdm.xml` and
  registers the client; `leave` revokes this host's token and unregisters.
  The Zero Trust org itself (team name) is created by the operator in the
  dashboard — creating it via the API is unverified (open question).
- **Fleet experts** — the hub host runs `tillandsias-plan expert-serve`
  bound to its Mesh IP behind a per-fleet bearer stored in Vault
  (`secret/fleet/experts`), advertises `fleet-experts.tillandsias-enclave-vpn.internal`
  as a hostname route, and every spoke's forge gets a
  `tillandsias-fleet-experts` provider next to the local one; the tray shows
  reachability. Service-token devices share one identity, so the bearer is
  the authorization, not the network.

## What the public Cloudflare App needs (operator checklist)

1. Dashboard: account → Manage Account → OAuth clients → Create client
   (needs Super Administrator / Administrator / "OAuth Client Write").
2. Client name `Tillandsias`; response type `code`; grant types
   `authorization_code` + `refresh_token`; token endpoint auth method `None`
   (PKCE S256). No client secret exists or is needed.
3. Redirect URLs (exact match, so every port is its own entry):
   `http://127.0.0.1:48631/tillandsias/cloudflare/callback`,
   `http://127.0.0.1:48632/tillandsias/cloudflare/callback`,
   `http://127.0.0.1:48633/tillandsias/cloudflare/callback`, and the relay
   `https://<operator-domain>/tillandsias/cloudflare/callback`.
4. Scopes: pick from the dashboard's catalogue (`GET /oauth/scopes` needs a
   token; names below are the permission names the docs say scopes mirror
   and are UNVERIFIED as scope ids): User Details Read; Account Settings
   Read; Access: Service Tokens Write; Cloudflare One Networks Write (or
   Cloudflare Tunnel Write) for virtual networks and routes; Zero Trust
   Gateway Write (network policies, device profile / split tunnel); Devices
   Read; WARP Connector / Mesh Write. Mark everything except User Details
   Read as optional so a spoke that only logs in can decline the rest.
5. Visibility: PRIVATE is enough for a fleet that all signs in with the
   operator's own account ("Private clients can only be authorized by
   members of the parent Cloudflare account"). PUBLIC (any Cloudflare user)
   additionally requires a logo, a Client URL, and DNS TXT domain
   verification `cloudflare_oauth_client_publisher=<code>` on that domain;
   the domain cannot change afterwards and public→private is irreversible.
   Recommendation: start private; go public only when other operators
   should run their own fleets.
6. A Zero Trust organization on the Free plan with team name
   `tillandsias-enclave-vpn-<github_login>`; Gateway proxy TCP+UDP on; default device
   profile on MASQUE; Split Tunnels include `100.96.0.0/12`; Mesh enabled.
7. Hand the implementers: the `client_id` (public, embeddable like
   `GITHUB_APP_CLIENT_ID`), the registered redirect URIs, the team name, and
   the relay page's URL.

## Operator ruling on names (2026-09-29, relayed by the coordinator)

Supersedes the first canonical table (`tillandsias-vpn`,
`tillandsias-vpn-<acct8>`); the table above already reads the ruled names.

- Zero Trust TEAM name (the globally unique `<team>.cloudflareaccess.com`
  label): `tillandsias-enclave-vpn-<github_username>`, normalized by
  `cloudflare_names`; no Cloudflare account id or email in any name; on a
  collision suffix `-2`, `-3`… and report it
  (`note:fleet-vpn:team-name-suffixed:<name>`).
- Virtual NETWORK name (account-scoped): `tillandsias-enclave-vpn`. The
  route suffix follows it: `<service>.tillandsias-enclave-vpn.internal`
  (design inference, not part of the ruling).
- Cloudflare App: PRIVATE (operator-only) first; public later, revisions
  expected.
- Never delete the Zero Trust organization in tests or tooling: a deleted
  organization's team name is permanently reserved (Cloudflare FAQ).
- Applied by an amendment fragment on 1505-iky3 (the normalizer) and
  1505-6w7d (init), not by a new packet: both rows are `ready` and
  unimplemented, so the correction is a field flip plus an event, and the
  fake (1505-svve) gains a never-DELETE assertion on the organization route
  through 1505-6w7d's fixture.

## Open questions for the operator

1. Do you own a domain to host the relay page (needed for QR login; also
   the Client URL if the App ever goes public)?
2. ANSWERED 2026-09-29: no host daemon anywhere; the client runs in a
   rootless sidecar beside the router (milestone 1506-3xu7).
3. ANSWERED 2026-09-29: private App first.
4. Should macOS/Windows hosts join through their Linux guest only (host
   tools off-mesh), as designed, or do you want the host-native client too?
5. ANSWERED 2026-09-29: team `tillandsias-enclave-vpn-<github_login>`,
   network `tillandsias-enclave-vpn`.

## Provenance

Every source above was fetched on 2026-09-29 from public documentation; no
Cloudflare API was called with credentials and no account was created. The
`GET /oauth/scopes` catalogue answered HTTP 400 without a token and is
therefore unverified. Repository facts were read at linux-next `552af2544`:
`run_github_device_login`, `parse_device_code_response`, `device_poll_script`,
`render_terminal_qr_in`, `GITHUB_APP_CLIENT_ID` (crates/tillandsias-headless
main.rs); `GITHUB_TOKEN_PATH`, `GITHUB_REFRESH_PATH`, `GitHubTokenBundle`,
`store_github_token_bundle`, `GitHubTokenStore` (vault_bootstrap.rs);
`handle_github_login`, `await_github_login_confirmation` (tray/mod.rs);
`MenuId::GITHUB_LOGIN` (tillandsias-host-shell menu_state.rs); `expert-serve`
and `run_grounded` (tillandsias-plan); `.mcp.json`, `opencode.json`
(`tillandsias-experts` provider on `127.0.0.1:11436`).
