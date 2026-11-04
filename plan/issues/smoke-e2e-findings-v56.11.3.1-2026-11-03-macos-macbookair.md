# v56.11.3.1 e2e smoke — macos PASS (published tray app: install, signature, Ready, forge prompt, clean quit) (2026-11-03)

- run_start: 2026-11-03T13:43:44Z
- evidence_dir: target/smoke-e2e on tlatoanis-macbook-air (previous runs archived under _archived-pre-v56.11.3.1/)
- forge_lane_outcome: completed one-turn prompt. The agent (OpenCode, big-pickle) answered `PONG`, exit 0. The host was signed in, not reset, so this is not a cold-host run.
- signature_verification: cosign:verified:1/1

Release under test: v56.11.3.1 (prerelease, from the new release workflow), tag commit bf1668fd1df1b3363b826d083f060234cd2e1d0c. Installed from the PUBLISHED asset with `TILLANDSIAS_VERSION=v56.11.3.1`, not from a local build. It contains #783, #797, #801, #815, #819 and #859 (each one's merge commit is an ancestor of the tag).

Scope, as the coordinator asked: a tray-app smoke on the operator's workstation. The VM and Vault were NOT reset, so the operator's sign-ins were kept; this is not the clean-room curl-install reset.

```
1 install          PASS  install_exit=0; "tillandsias-tray 56.11.3.1 (git bf1668fd1, built 2026-11-03T13:37:58Z)"; CFBundleVersion 56.11.3.1
2 signature        PASS  cosign:verified:1/1 on tillandsias-tray-56.11.3.1-macos-arm64.tar.gz
  checksum         PASS  sha256 967b27ba946a8fad09df1525f3eaf2979098e822375d496264fef33350dd3556 = SHA256SUMS-macos = the installer's logged hash
3 tray launch      PASS  the installer launched the app; push subscription 13:45:00Z; 39 cloud projects 13:45:37Z; phase=Ready 13:45:45Z (93 s); no rebuild, no delivery error
3 forge + prompt   PASS  `tillandsias-tray --cloud 8007342/tillandsias --opencode --prompt "Reply with exactly the word PONG and nothing else."`: proxy ready-earlier, mirror seeded, forge up, the agent answered PONG, exit 0 in 301 s
4 clean quit       PASS  SIGTERM to the tray: exited in 16 s, "guest reported a clean power-off (token matched)", "Quit: VM drained cleanly"; no VM process left. The CLI forge run also ended with no VM process left.
```

How step 3 was driven: the forge was launched through the release tray binary's CLI cloud lane (#751), not the menu, because this host does no GUI scripting. The CLI cannot run beside a live tray, so step 4's quit came before it. Both use the same in-guest launch path (`tillandsias-headless --cloud <owner/repo> --opencode`). The menu's own forge click was not exercised.

Note for the release workflow, not a defect in this artifact: the release was created at 13:13:33Z, but the macOS assets were uploaded at 13:40:06Z, after a 13:37:58Z build. So for about 27 minutes the published prerelease had no macOS assets. The signature and checksum confirm the uploaded asset is the CI-signed one.

## Ledger claims

- EXERCISED: #797 (the tray delivers Vault credentials; it reached Ready with no delivery error), #783 and #769 (a warm CLI boot unseals), #751 (the CLI `--cloud` form), 1922-lrdy (proxy `ready-earlier`), and clean power-off on quit.
- NOT CHECKED: #815, the Antigravity sign-in keystrokes (needs an Antigravity launch with no token, driven by the operator); #801, the guest OS upgrade (applies on a fresh provision only; this VM was provisioned by the dev build and already runs kernel 7.2.13); #819, the Cloudflare host callback (no sign-in was run); `image.generate`.
