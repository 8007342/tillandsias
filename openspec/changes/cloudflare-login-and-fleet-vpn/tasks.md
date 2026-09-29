# Tasks — cloudflare-login-and-fleet-vpn

Packet orders in brackets; dependency order top to bottom. Each task's
closure is the fixture named in its packet's `verifiable_closure`.

## 1. Test substrate (no real App needed) [1505-svve, sonnet]

- [ ] 1.1 `tillandsias-fake-cloudflare`: OpenID discovery, `/oauth2/auth`
      (`?auto=approve|deny`), `/oauth2/token` (PKCE S256 check, single-use
      codes, refresh rotation, `?fail=invalid_grant`), `/oauth2/revoke`,
      `/oauth2/userinfo`; listens on `127.0.0.1:0`, prints its port.
- [ ] 1.2 The API routes `fleet-vpn init` needs, each appending to a JSON
      call ledger the fixtures read.
- [ ] 1.3 `scripts/test-fake-cloudflare.sh`: self-test of the fake (a wrong
      verifier is refused; a code is single-use).

## 2. OAuth core [1505-kyx8, sonnet]

- [ ] 2.1 `cloudflare_oauth::{begin, exchange, refresh, revoke}` as pure
      functions over an injected HTTP client; verifier/state generation.
- [ ] 2.2 Discovery read with the `note:cloudflare-login:device-grant-available`
      output when the well-known document lists the device grant.
- [ ] 2.3 `scripts/test-cloudflare-oauth-core.sh` over the fake.

## 3. Names [1505-iky3, sonnet]

- [ ] 3.1 `cloudflare_names::{normalize_label, normalize_display}` and the
      typed `Label` / `Display`.
- [ ] 3.2 Canonical constructors `network_name`, `team_name`,
      `participant_name`, `service_route`; the table from the design note in
      the module doc.
- [ ] 3.3 Property tests: every output re-normalizes to itself; length caps;
      refusals for empty results.

## 4. Vault bundle and rotation [1505-iysn, opus]

- [ ] 4.1 `CLOUDFLARE_TOKEN_PATH`, `CLOUDFLARE_REFRESH_PATH`,
      `CloudflareTokenBundle`, `CloudflareTokenStore`,
      `store_cloudflare_token_bundle` (refresh first).
- [ ] 4.2 `rotate_cloudflare_token_locked`,
      `spawn_cloudflare_token_rotation_scheduler` from the three entry
      points; `blocked:cloudflare-token-rotation-failed:<reason>`.
- [ ] 4.3 Vault policy files: only the host resident process reads the
      refresh path; forge policies read neither.
- [ ] 4.4 `scripts/test-cloudflare-token-rotation.sh` (five arms mirroring
      `test-github-token-auto-rotation.sh` plus the three-entry-point
      mutation arms of 1489-8qd6).

## 5. The login command [1505-kc5f, opus]

- [ ] 5.1 `--cloudflare-login --via loopback`: listener on the registered
      ports, browser open, state check, exchange, Vault write, the stored
      signal the tray waits on. (Done except the tray signal: there is no
      tray-side Cloudflare waiter yet — that is 1505-hfim's row.)
- [x] 5.2 `--via qr`: QR of the authorize URL with the relay redirect;
      paste prompt; optional relay poll behind
      `TILLANDSIAS_CLOUDFLARE_RELAY_POLL_URL`.
- [x] 5.3 `--via paste`; terminal requirement mirrored from
      `select_github_login_input_mode`.
- [x] 5.4 `--cloudflare-logout`.
- [x] 5.5 `LITMUS_PODMAN_MODE` stop before any exchange, as for GitHub.
- [ ] 5.6 `scripts/test-cloudflare-login.sh` driving the real binary
      against the fake for loopback (auto-approve), paste and deny.
      (Deny, state, qr, litmus and the refusals drive the real binary; the
      STORING arms — loopback approve, paste — run the same `login()`
      in-process with the in-memory Vault seam, because the binary's only
      store is the live Vault and no env switch may select another.)
- [x] 5.7 The static relay page (`assets/cloudflare-relay/index.html`) and
      its one test (renders `code` from the query string, never calls out).

## 6. Fleet VPN bootstrap [1505-6w7d, opus]

- [ ] 6.1 `--fleet-vpn init`: account resolve, org presence check with the
      dashboard remedy, virtual network, MASQUE profile, split-tunnel
      include, Gateway proxy + network policy, per-host service token,
      `secret/cloudflare/mesh`.
- [ ] 6.2 Idempotency: a second run is all `skip:`; the fake's ledger shows
      zero writes.
- [ ] 6.3 `scripts/test-fleet-vpn-init.sh`.

## 7. Join / leave / status per platform

- [ ] 7.1 Linux bare metal [1505-bhsb, opus]: client detection, printed
      install step per substrate, `mdm.xml` write, `warp-cli` verification,
      Mesh IP in Vault, `leave`, `status`; `scripts/test-fleet-vpn-join-linux.sh`
      with a fake `warp-cli` on PATH; first live arm on a Silverblue host
      recorded in the packet.
- [ ] 7.2 macOS/Windows through the guest [1505-g6zc, opus]: client in the
      guest provisioning recipes; service token hand-over; guest-side join;
      `status` relayed to the host tray.
- [ ] 7.3 Spoke research [1505-m63i, sonnet]: proxy-mode-in-rootless-container
      measurement with four named outcomes; result recorded in the packet
      and the design note.

## 8. Fleet experts

- [ ] 8.1 Serve [1505-br88, opus]: `expert-serve --bind --bearer-file`
      with the non-loopback refusal; `--fleet-experts serve [--mint]`;
      hostname route; `scripts/test-fleet-experts-serve.sh` (a request
      without the bearer on a non-loopback bind is 401; loopback without a
      bearer still answers).
- [ ] 8.2 Discovery and client [1505-wteh, sonnet]: `--fleet-experts status`;
      the `tillandsias-fleet-experts` provider in the forge overlay;
      `scripts/test-fleet-experts-client.sh`.

## 9. Surfaces [1505-hfim, sonnet]

- [ ] 9.1 `MenuId::CLOUDFLARE_LOGIN`, `Cloudflare Login` row and the
      auth-gated visibility; `Fleet VPN:` and `Fleet Experts:` rows in
      `menu_state`.
- [ ] 9.2 Linux tray handler mirroring `handle_github_login`; macOS and
      Windows render the same body (existing expect-order tests extended).
- [ ] 9.3 Usage text for every new flag.

## 10. Milestone close [1505-sm2j]

- [ ] 10.1 Every child completed or superseded; deltas synced to
      `openspec/specs/`; the design note's open questions carry the
      operator's answers.
