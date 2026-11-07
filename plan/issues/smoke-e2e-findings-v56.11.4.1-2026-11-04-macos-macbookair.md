# v56.11.4.1 e2e smoke — macos PASS on install, signature, tray Ready and quit; the forge prompt was BLOCKED by OpenCode's usage limit (2026-11-04)

- run_start: 2026-11-04T07:51:55Z
- evidence_dir: target/smoke-e2e on tlatoanis-macbook-air (previous runs archived under _archived-pre-v56.11.4.1/)
- forge_lane_outcome: forge STARTED. The agent's one turn was refused by the provider: `blocked:provider-usage-limit:provider=opencode:retry_after=2026-11-05T07:58:37Z`. No reply was produced. The lane did not end; it was stopped at the 20-minute bound (finding below).
- signature_verification: cosign:verified:1/1

Release under test: v56.11.4.1 (prerelease, the stable candidate with the proxy CA fixes), tag commit d55a07b5f747252a5453ef9519bf624aceb1b408. Installed from the PUBLISHED asset with `TILLANDSIAS_VERSION=v56.11.4.1`. Scope: a tray-app smoke on the operator's workstation, not reset; sign-ins were kept.

**Verdict for promotion: the coordinator decides.**
- Every Tillandsias step passed, including bringing the forge up through the proxy.
- The one agent turn could not run, because OpenCode's free model was over its usage limit. That limit is outside Tillandsias, and the product reported it correctly.
- Separately, the lane then failed to end on its own.

```
1 install          PASS  install_exit=0; "tillandsias-tray 56.11.4.1 (git d55a07b5f, built 2026-11-04T07:47:05Z)"; CFBundleVersion 56.11.4.1
2 signature        PASS  cosign:verified:1/1 on tillandsias-tray-56.11.4.1-macos-arm64.tar.gz
  checksum         PASS  sha256 289abb6288795d545677c6132398d88382894281948b398be18971e5bc96b167 = SHA256SUMS-macos = the installer's logged hash
3 tray launch      PASS  push subscription 07:52:46Z; 39 cloud projects 07:53:22Z; phase=Ready 07:53:30Z (92 s); no rebuild, no delivery error
3 forge up         PASS  `--cloud 8007342/tillandsias --opencode --prompt "…PONG…"`: proxy `ready-earlier` (07:57:35Z, through the new proxy CA), mirror seeded (07:57:50Z), forge banner, agent started (big-pickle)
3 one prompt       BLOCKED  `[forge] provider usage limit reached, retry after 2026-11-05T07:58:37Z (opencode)`; no reply
4 clean quit       PASS  SIGTERM to the tray: exited in 17 s, "guest reported a clean power-off (token matched)", "Quit: VM drained cleanly"
```

The release workflow published the release at 07:27:15Z, but the macOS asset was built at 07:47:05Z, so the prerelease had no macOS asset for about 20 minutes. This is the same pattern as v56.11.3.1. The signature and checksum confirm the asset is the CI-signed one.

## Ledger claims

- EXERCISED: the proxy CA fixes (the forge reached `ready-earlier` through the proxy, and the mirror seeded); #797 (Ready with no delivery error); clean power-off; 1941-rlim's limit report (named provider and `retry_after`).
- NOT CHECKED: an agent reply (provider limit); the menu launch (no GUI scripting); #815 Antigravity sign-in; #819 Cloudflare callback.

### Work Packet: smoke-finding/provider-usage-limit-does-not-end-the-lane

- id: `smoke-finding/provider-usage-limit-does-not-end-the-lane`
- owner_host: any
- capability_tags: [forge, opencode, provider-limit]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.11.4.1`
- evidence:
  - `03-forge-prompt.log`: `blocked:provider-usage-limit:provider=opencode:retry_after=2026-11-05T07:58:37Z` at about 07:58Z. Nothing followed until the smoke's 20-minute bound (`BOUND-EXCEEDED`, 08:12Z).
  - The host CLI process (`tillandsias-tray --cloud … --opencode --prompt …`) and its VM were still running, and exited only on SIGTERM.
  - 1941-rlim's own title says a usage limit "ends the lane". With a one-shot `--prompt`, it did not.
- repro:
  - With OpenCode's free model over its limit: `tillandsias-tray --cloud 8007342/tillandsias --opencode --prompt hi`. The process never exits.
- next_action: >
    Make a one-shot `--prompt` lane exit with a named non-zero status after the
    provider-limit line, then stop the VM cleanly, and add a test that a
    limit-blocked one-shot lane returns. A long-running interactive lane may
    keep holding; this is about one-shot runs.
- events:
  - type: discovered
    ts: `2026-11-04T08:15:00Z`
    agent_id: `macos-tlatoanis-macbook-air-claude-20261012t100000z`
    host: macos
