# Design — cloudflare-login-and-fleet-vpn

Umbrella packet: `1505-sm2j`. Code is cited by SYMBOL; nothing here is a
line number. Research, sources and the operator checklist:
`plan/issues/cloudflare-login-fleet-vpn-design-2026-09-29.md`.

## Context

What exists (read before implementing; none of it is re-filed):

- `run_github_device_login` (crates/tillandsias-headless main.rs): requests
  a device code through `curl` inside the git container, parses it with
  `parse_device_code_response` (refuses non-alphanumeric codes), renders the
  QR with `render_terminal_qr_in` (`qrcode` crate, colour tier from
  `qr_tier`), prints the code with `styled_user_code`, then streams the
  poll script from `device_poll_script` over `device_poll_exec_args` with a
  live `DevicePollView`. `LITMUS_PODMAN_MODE` stops it before polling.
  `GITHUB_APP_CLIENT_ID` is a public compile-time constant.
- `vault_bootstrap`: `GITHUB_TOKEN_PATH` / `GITHUB_REFRESH_PATH` (two paths
  because KV v2 policies are path-scoped, not field-scoped),
  `GitHubTokenBundle`, `GitHubTokenStore` (trait, so ordering rules are
  testable without Vault), `store_github_token_bundle` (refresh record
  first, then token record — the failure rule), `rotate_github_token_locked`,
  `spawn_github_token_rotation_scheduler` called from the Linux tray, from
  `ensure_enclave_for_project` and from `maybe_spawn_vsock_listener`
  (1489-8qd6 pins the three call sites), `write_github_token_to_vault`.
- Tray: `handle_github_login` launches `tillandsias --github-login` in a
  terminal via `launch_in_terminal`; `await_github_login_confirmation` waits
  for the stored-token signal; `MenuId::GITHUB_LOGIN` and the auth-gated
  menu body in `tillandsias-host-shell` `menu_state`.
- Experts: `tillandsias-plan expert-serve [--port N] [--root D]` serves
  `POST /v1/chat/completions` through `run_grounded` (spec
  `expert-serve-grounded-pipeline`, R1/R2); `experts-probe` reports the live
  tier; `opencode.json` provider `tillandsias-experts` at
  `http://127.0.0.1:11436/v1`; `.mcp.json` launches `forge-plan` and
  `project-info` over stdio from `images/default/config-overlay/mcp/`.
- Guests: macOS VM (`crates/tillandsias-vm-layer` `vz`), WSL2 distro
  (`tillandsias-windows-tray` `wsl_lifecycle`); both run the Linux
  `tillandsias-headless` binary as a service.
- Fixture style: `scripts/test-github-token-auto-rotation.sh` drives cargo
  tests over a stub store and a stub token endpoint; no network, no Vault.

## Decision 1 — the login is Authorization Code + PKCE with three receivers

Cloudflare offers no device grant (proposal, research §1). The flow:

1. `cloudflare_oauth::begin(client_id, redirect_uri, scopes) -> Pending`
   generates `state` (32 random bytes, base64url) and a PKCE verifier (43–128
   chars per RFC 7636), and builds the authorize URL with
   `code_challenge_method=S256`. Pure; unit-tested; the verifier never leaves
   the process.
2. The redirect is received by ONE of:
   - **loopback** (`--via loopback`, default when
     `require_desktop_user_session` would pass and a browser opener exists):
     `std::net::TcpListener` on `127.0.0.1:{48631,48632,48633}` (first free;
     all three are registered exactly, because the redirect URI must match
     port and path exactly), path `/tillandsias/cloudflare/callback`. The
     browser is opened on the authorize URL; the listener answers one
     request, checks `state`, and closes.
   - **qr** (`--via qr`, default without a desktop session): the QR
     (`render_terminal_qr_in`, unchanged) encodes the authorize URL whose
     `redirect_uri` is the operator's relay page
     `https://<relay-host>/tillandsias/cloudflare/callback`. The relay is a
     STATIC page: it reads `code` and `state` from its query string and
     shows them for paste. Optional second step (same packet, behind
     `TILLANDSIAS_CLOUDFLARE_RELAY_POLL_URL`): the page POSTs `(state, code)`
     to a Worker and the host polls `GET …/poll?state=` until it gets the
     code or the state expires (≤ 5 min). Either way the host, holding the
     verifier, does the exchange.
   - **paste** (`--via paste`): the operator pastes the code shown by the
     relay page; stdin must be a terminal (mirrors
     `select_github_login_input_mode`).
3. `cloudflare_oauth::exchange(pending, code) -> Bundle` POSTs the token
   endpoint with `grant_type=authorization_code`, `code_verifier`; refuses a
   `state` mismatch before any network call.
4. The bundle is written by `store_cloudflare_token_bundle` through a
   `CloudflareTokenStore` trait with the SAME ordering rule as
   `store_github_token_bundle` (refresh record first).

Trade-off, stated plainly: a QR login is only as private as the relay page.
The relay sees `code` and `state` — never a token, never the verifier — and
the code is single-use and useless without the verifier, so a compromised
relay can at most deny the login. Without an operator domain there is no QR
login; loopback and paste still work. The GitHub device-flow shape is kept
as an adapter: `cloudflare_oauth` reads
`https://dash.cloudflare.com/.well-known/openid-configuration` at login and,
if `grant_types_supported` ever contains
`urn:ietf:params:oauth:grant-type:device_code`, prints
`note:cloudflare-login:device-grant-available` so the switch is a packet,
not a discovery.

Endpoints are configuration, not constants: `TILLANDSIAS_CLOUDFLARE_BASE_URL`
(default `https://dash.cloudflare.com`) and
`TILLANDSIAS_CLOUDFLARE_API_BASE_URL` (default
`https://api.cloudflare.com/client/v4`), so the fake server (Decision 3) is
selected by environment exactly as `LITMUS_PODMAN_MODE` selects the litmus
stop. The `client_id` is a public constant `CLOUDFLARE_APP_CLIENT_ID`
supplied by the operator, overridable by `TILLANDSIAS_CLOUDFLARE_CLIENT_ID`
for the fake.

The login runs on the HOST binary, not inside the git container as the
GitHub one does: the loopback listener must be reachable by the host
browser, and no container needs the token.

## Decision 2 — the Vault contract mirrors the GitHub one; rotation is a sibling

Paths: `CLOUDFLARE_TOKEN_PATH = "secret/cloudflare/token"` holding
`access_token`, `expires_at`, `account_id`, `client_id`;
`CLOUDFLARE_REFRESH_PATH = "secret/cloudflare/refresh"` holding
`refresh_token`, `refresh_token_expires_at` (absent when Cloudflare does not
report it — lifetimes are undocumented), `client_id`. Policies: only the
host's own resident process reads the refresh path; forges never do; a
future fleet-experts client policy may read the token path.

Rotation: `spawn_cloudflare_token_rotation_scheduler` is a sibling of
`spawn_github_token_rotation_scheduler`, called from the same three entry
points (1489-8qd6's fixture pattern pins them), rotating when
`expires_at - now <= 30 min` under `rotate_cloudflare_token_locked`; a failed
rotation names `blocked:cloudflare-token-rotation-failed:<reason>`. No
generalization of the GitHub code is filed: two explicit siblings are
cheaper to read than one abstraction over two providers with different
lifetimes, and the GitHub code is under a live p0 (1461-8tyy).

`--cloudflare-logout` revokes at the revoke endpoint (best effort), deletes
both records, and leaves `fleet-vpn` membership untouched (the service token
is the host's mesh credential, not the OAuth token).

## Decision 3 — every fixture runs against a fake Cloudflare

`tillandsias-fake-cloudflare` (a `[[bin]]` under `crates/tillandsias-headless`
built only for tests, or a `#[cfg(test)]` helper spawned by fixtures — the
packet chooses; the contract is the HTTP surface) serves:

- `/.well-known/openid-configuration` (endpoints; `grant_types_supported`
  configurable so the device-grant adapter note is testable),
- `/oauth2/auth` (renders a consent page; a `?auto=approve` query completes
  the redirect immediately for loopback tests; `?auto=deny` returns
  `error=access_denied`),
- `/oauth2/token` (validates `code_verifier` against the stored challenge,
  single-use codes, issues `access_token` / `refresh_token` / `expires_in`;
  `grant_type=refresh_token` rotates; a `?fail=` knob returns
  `invalid_grant`),
- `/oauth2/revoke`, `/oauth2/userinfo`,
- the API routes `fleet-vpn init` needs: `GET /accounts`,
  `POST /accounts/{id}/access/service_tokens`, `DELETE …/service_tokens/{id}`,
  `POST /accounts/{id}/teamnet/virtual_networks`, the device-profile,
  split-tunnel and gateway-rule routes, each recording its calls to a JSON
  ledger the fixture asserts on.

It listens on `127.0.0.1:0` and prints its port; fixtures export the two
base URLs. The real App is never required by any gate.

## Decision 4 — names come from one normalizer and one table

`cloudflare_names` (pure module): `normalize_label(&str) -> Result<Label>`
(lowercase ASCII, `[a-z0-9-]`, no leading/trailing/double hyphen, ≤ 63) and
`normalize_display(&str) -> Result<Display>` (same alphabet, ≤ 255); typed so
a `Display` cannot be passed where a `Label` is required. Canonical
constructors: `network_name()` = `tillandsias-vpn`; `team_name(account_id)`
= `tillandsias-vpn-<acct8>`; `participant_name(hostname)` =
`tillandsias-<host>` truncated to fit 63; `service_route(service)` =
`<service>.tillandsias-vpn.internal`. The table and the rule sources live in
the design note; the module's doc comment cites them.

## Decision 5 — the network is Cloudflare Mesh; hubs run the daemon, spokes are measured

`tillandsias --fleet-vpn init` (needs the OAuth token; idempotent; every
call is a named step with `ok:` / `skip:` / `refused:` output): resolve the
account; ensure virtual network `tillandsias-vpn`; ensure the default device
profile uses MASQUE and Split Tunnels include `100.96.0.0/12`; ensure Gateway
proxy TCP+UDP on and one network policy allowing `100.96.0.0/12 → 100.96.0.0/12`
for the org; mint service token `tillandsias-<host>` (duration `8760h`,
rotated by `--fleet-vpn join --renew`) and store it at
`secret/cloudflare/mesh` (`client_id`, `client_secret`, `expires_at`,
`team_name`). The Zero Trust organization (team name) is created by the
operator in the dashboard; `init` refuses with
`refused:fleet-vpn:no-zero-trust-org:<team_name>` and prints the exact
dashboard step when it is absent (API creation is unverified).

`--fleet-vpn join` on **Linux bare metal** (a HUB or any host the operator
allows a daemon on): detect `warp-svc` (`systemctl is-enabled warp-svc`);
if absent, print the exact install step for the substrate (`dnf install
cloudflare-warp` on mutable Fedora; `rpm-ostree install cloudflare-warp`
then reboot on Silverblue — unverified against Silverblue, the packet's
first live arm measures it) and refuse `refused:fleet-vpn:client-absent`;
never install with sudo itself. Write `/var/lib/cloudflare-warp/mdm.xml`
(through a printed `sudo tee` the operator runs, or directly when root),
then verify `warp-cli --accept-tos registration show` and `status`, and
record the Mesh IP in Vault (`secret/cloudflare/mesh.mesh_ip`).

`--fleet-vpn join` on **macOS and Windows**: the HOST is not enrolled. The
guest (Linux VM / WSL2 distro, both supported node OSes) installs the client
during provisioning (`vz` provisioning recipe; WSL provisioning unit) and
receives the service token over the existing host→guest credential hand-over
(`set_in_vm_credentials` is the model); the guest's `tillandsias-headless`
writes `mdm.xml` and registers. The forges and the experts run in the guest,
so they are on the mesh; host-native tools are not (accepted trade-off).

`--fleet-vpn leave`: unregister (`warp-cli registration delete`), delete the
host's service token via the API, remove `mdm.xml`, clear
`secret/cloudflare/mesh`. `--fleet-vpn status`: one line per fact —
`org`, `client`, `registration`, `mesh_ip`, `route:<service>` — never a
guess: a fact that cannot be read is `unknown:<why>`.

Spokes without a daemon (research 1505-m63i): measure whether
`service_mode: proxy` inside a rootless podman container (no TUN, SOCKS on
`127.0.0.1:40000`) can reach a hub's Mesh IP and hostname route. Outcomes:
`reaches-mesh` (spokes go daemon-free), `registers-but-no-mesh`,
`cannot-register-unprivileged`, `package-refuses-container`. The result
selects between "spoke = proxy container" and "spoke = same as hub".

## Decision 6 — fleet experts are the local experts bound to the mesh behind a bearer

Hub: `tillandsias --fleet-experts serve` runs `tillandsias-plan expert-serve
--bind <mesh_ip> --port 11436 --bearer-file <path>`; `expert-serve` gains
`--bind` (default unchanged, `127.0.0.1`) and refuses any non-loopback bind
without a bearer (`refused:expert-serve:non-loopback-without-bearer`). The
bearer (32 random bytes) is minted once per account by `--fleet-experts
serve --mint` and stored at `secret/fleet/experts` (`bearer`,
`hub_hostname`, `url`); spokes receive it through the same
operator-mediated path as the GitHub token today (paste on the spoke or the
host→guest hand-over) — distributing it automatically over Cloudflare is
out of scope for v0.6. The hub advertises `fleet-experts.tillandsias-vpn.internal`
as a Mesh hostname route pointing at itself.

Spoke: `--fleet-experts status` resolves the route, GETs `/v1/models` with
the bearer, and prints `reachable:<url>:<index_digest>` or
`unreachable:<why>`. The forge overlay gains provider
`tillandsias-fleet-experts` (`baseURL`
`http://fleet-experts.tillandsias-vpn.internal:11436/v1`, `apiKey` from the
Vault path) beside `tillandsias-experts`; the local-experts agent prompt
says which one answered. Authorization is the bearer, not the network:
service-token devices share one Gateway identity, so Gateway cannot tell
hosts apart.

## Decision 7 — surfaces

CLI: `--cloudflare-login [--via loopback|qr|paste] [--debug]`,
`--cloudflare-logout`, `--fleet-vpn init|join|leave|status [--renew]`,
`--fleet-experts serve|status [--mint]`. Tray: `Cloudflare Login`
(`MenuId::CLOUDFLARE_LOGIN`, visible iff no Cloudflare bundle, launched
through `launch_in_terminal` like `handle_github_login`), `Fleet VPN:
joined <mesh_ip> | not joined | client absent`, `Fleet Experts: reachable |
unreachable | not configured`. The macOS and Windows trays render the same
rows from the same `menu_state` body.

## Risks

- Undocumented token lifetimes: rotation is driven by `expires_in` as
  reported; if absent, the bundle records no `expires_at` and the tray shows
  `expiry unknown` instead of guessing.
- Silverblue and the Cloudflare client are an unverified pair; the Linux
  join packet's first live arm is that measurement and its outcome is
  recorded in the packet, not assumed.
- The 50-node and 50-service-token account limits bound the fleet at 50
  participants; `init` prints the counts it read.
- A public App needs domain verification and is irreversible; the design
  recommends private first.
