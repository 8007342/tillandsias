# Windows v0.4.260728.1: login gate never clears — vault epoch skew + stale guest stack

- **Date:** 2026-07-28
- **Class:** bug bundle (release install regression; guest vault state machine; tray UX)
- **Discovered by:** operator (Tlatoāni) live report on the Windows host after
  `irm .../install-windows.ps1 | iex` of the freshly released v0.4.260728.1;
  root-caused by agent audit in the live guest (journal + vault storage + code)
- **Host evidence:** WSL distro `tillandsias` (hostname Yolanda), journal
  2026-07-28 13:30–14:16 PDT; tray `v0.4.260728.1` at
  `%LOCALAPPDATA%\Programs\Tillandsias`; guest headless `v0.3.260724.1`
- **Relates to:** order 383 (generate-root self-heal), order 276 (login
  transition sentinel), order 282 (guest-binary embed),
  `macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md`,
  `bug(macos-vault)` 25eb3b2a (vault-data guest-local)

## Operator-visible symptoms

1. GitHub token is never remembered — every tray session prompts for the PAT
   again (git name/email DO persist — they live in a plain file).
2. After a login console prints `GitHub authentication complete for 8007342`,
   the tray menu stays login-gated forever; remote projects never load.
3. Cloud submenu shows "(no repos)" while the fetch is still in flight
   (no loading state).
4. Every agent leaf (Claude/Codex/OpenCode/Antigravity) re-runs the
   interactive GitHub login flow instead of launching.

## Root-cause chain (confirmed in the live guest)

1. **Release install reuses a stale guest stack.** The v0.4.260728.1 tray
   drove a WSL distro provisioned 2026-07-24: guest headless `v0.3.260724.1`,
   proxy/vault images `0.3.260724.1`. `tillandsias-headless-fetch.service`
   only "ensures present", never upgrades. Tray↔guest version skew ⇒ every
   guest bug fixed 07-24→07-28 resurfaced. (The menu's "(Update Pending)"
   marker is detection-only.)
2. **Vault storage wiped on nearly every boot (old guest code).** Journal
   shows `first boot: running vault operator init` at 13:33, 13:37, 13:46 and
   13:51 — each guest boot re-initialized `/root/.cache/tillandsias/vault-data`
   because the boot-time partial-init check found no Shamir share (share
   fallback-file persistence only landed on the service path in later code).
   Every re-init discards the KV, including any stored GitHub token ⇒
   "prompts every time".
3. **Share epoch skew wedges the resident service.** After the 13:57 epoch
   finally persisted a share file, the *service* still received the host
   keychain's share from a PREVIOUS storage epoch via DeliverCredentials, and
   `heal_stale_root_token` only ever tried that FIRST valid candidate:
   `generate-root` aborts with `error decrypting using seal shamir: cipher:
   message authentication failed` in an endless loop (14:01→14:12+). The
   service's vault access stays dead ⇒ login-state probes always report
   logged-out ⇒ LoginStatePush never fires ⇒ login gate never clears — while
   each interactive login console (which read the guest-local share file)
   healed and printed success. Operator saw success + a tray that disagreed.
4. **UX gap:** empty cloud-projects submenu rendered "(no repos)" from cold
   start with no "loading" state.

## Fixes landed on windows-next (this audit, 2026-07-28)

- `vault_bootstrap`: `heal_stale_root_token` now iterates ALL share
  candidates (host-delivered → host keychain → guest fallback file, deduped)
  and falls through on generate-root rejection; the WINNING share is
  persisted to the guest share fallback file and the in-memory credentials,
  so later boots/heals converge on the storage-matching share.
- `menu_state`: `cloud_projects_loaded` distinguishes "(loading repos…)"
  from a confirmed-empty "(no repos)" (operator-approved UX change,
  requested live 2026-07-28); Windows tray flips it on the first
  CloudProjectsPush/refresh reply and resets it on logout.
- Local build restaged `target-guest/` x86_64 guest headless at
  v0.4.260728.1 (was stale from Jul 16/22 — `embedded_guest_headless_matches_
  workspace_version` catches this at test time).

## Still open (release lane — needs its own packets)

- [ ] **Guest upgrade on release install:** a newer tray must upgrade an
      existing distro's headless binary (and container images) instead of
      driving a version-skewed guest. Detection exists ("Update Pending");
      remediation does not.
- [ ] **Release artifact freshness:** verify the published Windows zip embeds
      a guest headless matching the release VERSION (CI half of order 282);
      the field guest was 0.3.260724.1 under a 0.4.260728.1 tray.
- [ ] Windows column of the order-455 matrix stays open until a local-build
      attended smoke passes on this host.

## Repro (release binary, before fixes)

1. On a host with a Jul-24-era `tillandsias` distro, install v0.4.260728.1
   via `install-windows.ps1` and launch the tray.
2. Run GitHub Login from the menu; paste a valid PAT; observe
   "authentication complete for <user>".
3. Observe the menu stays login-gated; `journalctl -u tillandsias-headless`
   in the guest shows the `cipher: message authentication failed`
   generate-root loop; restart the guest and observe the vault re-init +
   fresh PAT prompt.
