# Proposal — cloudflare-login-and-fleet-vpn

Umbrella packet: `1505-sm2j` (milestone, desired_release v0.6). Research and
decision record: `plan/issues/cloudflare-login-fleet-vpn-design-2026-09-29.md`.

## Why

The operator's direction (2026-09-29): a `tillandsias --cloudflare-login`
"analogous to `--github-login`" (device flow + QR); every Tillandsias
instance signed in with the SAME Cloudflare account joins ONE private
network, "TILLANDSIAS-VPN", with every name normalized to Cloudflare's own
rules; and the purpose is to share ONE off-forge orchestrator with the fleet
— macuahuitl serving its Local Experts to every forge as FLEET EXPERTS.

Today every host is an island. The Local Experts (`tillandsias-plan
expert-serve` on `127.0.0.1:11436`, provider `tillandsias-experts` in
`opencode.json`) are rebuilt and served per host; floor-tier hosts (esme,
macneo) cannot build an index at all and answer `unsupported:` refusals
where a fat host has the answer. There is no credential for any Cloudflare
product in Vault, no network between hosts except GitHub, and no discovery
of a service another host offers.

Two facts from the research decide the shape and are not negotiable by
implementation:

1. Cloudflare does NOT offer the OAuth device authorization grant to
   third-party clients — only Authorization Code, with PKCE `S256` required
   for CLI/desktop apps. A QR code therefore cannot end at a loopback
   redirect on the host; the QR path needs a public relay page on an
   operator-owned domain, or a pasted code.
2. The product that puts every device of one account on one private network
   is Cloudflare Mesh (formerly WARP-to-WARP / WARP Connector), available on
   the Zero Trust Free plan; every participant runs the Cloudflare One
   Client (`warp-svc`, root), enrolled headlessly through a per-host service
   token in `mdm.xml`.

## What Changes

- **ADDED** capability `cloudflare-auth`: the PKCE login with three redirect
  receivers (loopback, QR-to-relay, paste), the Vault two-path bundle
  (`secret/cloudflare/token`, `secret/cloudflare/refresh`), a resident
  due-check rotation mirroring the GitHub one, `--cloudflare-logout`, and
  the fake Cloudflare server every fixture runs against.
- **ADDED** capability `fleet-vpn`: the `cloudflare_names` normalizer and
  the canonical name table; `tillandsias --fleet-vpn init|join|leave|status`;
  the Cloudflare One Client in a `tillandsias-warp` sidecar container
  sharing the router's network namespace on every platform (inside the
  Linux guest on macOS/Windows) — AMENDED 2026-09-29 by
  `openspec/changes/fleet-messaging-poc/` (operator: "inside the router
  likely", "FREE version only"); the host-daemon join packets 1505-bhsb and
  1505-g6zc and the proxy-mode research 1505-m63i are obsoleted by
  1506-t97c and 1506-euvq.
- **ADDED** capability `fleet-experts`: `expert-serve` bound to the Mesh IP
  behind a per-fleet bearer from Vault, the
  `fleet-experts.tillandsias-vpn.internal` hostname route, the
  `tillandsias-fleet-experts` provider in every forge, and the tray rows.
- Tray and CLI surfaces: `Cloudflare Login` beside `GitHub Login`
  (`MenuId::GITHUB_LOGIN` is the model), `Fleet VPN:` and `Fleet Experts:`
  status rows.

Nothing about `--github-login`, the GitHub bundle or its rotation changes.

## Impact

- Specs: three new capabilities (deltas under `specs/`). No existing
  requirement is modified; the tray rows are stated inside `fleet-vpn` and
  `fleet-experts` rather than as a MODIFIED `tray-menu` delta, because they
  are additive leaves.
- Code (by packet): `crates/tillandsias-headless` (a `cloudflare_oauth`
  module, a `cloudflare_names` module, `vault_bootstrap` siblings of the
  GitHub bundle functions, the `--cloudflare-login` / `--fleet-vpn` /
  `--fleet-experts` commands, tray rows), `crates/tillandsias-host-shell`
  (`MenuId`), `crates/tillandsias-plan` (`expert-serve --bind`, bearer
  check), `images/default/config-overlay/opencode/config.json` (provider),
  guest provisioning (`crates/tillandsias-vm-layer`, `tillandsias-windows-tray`
  WSL provisioning) for the headless client, `scripts/test-*.sh` fixtures.
- Operator: creates the OAuth client and the Zero Trust organization
  (checklist in the design note); owns the relay page's domain.
- Out of scope: any Cloudflare Tunnel to the public internet; Access
  applications; identity-based Gateway policies (service-token devices share
  one identity); host-native mesh on macOS/Windows.
