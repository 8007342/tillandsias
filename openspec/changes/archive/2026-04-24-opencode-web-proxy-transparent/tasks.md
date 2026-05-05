# tasks

## 1. Broaden forge NO_PROXY

- [x] `crates/tillandsias-core/src/container_profile.rs` — in `forge_profile()`,
  update both `NO_PROXY` and `no_proxy` env entries from
  `"localhost,127.0.0.1,git-service"` to
  `"localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy"`.
  Add `@trace spec:opencode-web-session, spec:proxy-container` on the line.

## 2. Add NO_PROXY to inference profile

- [x] `crates/tillandsias-core/src/container_profile.rs` — in
  `inference_profile()`, append two env entries for `NO_PROXY` and `no_proxy`
  with value
  `"localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service"`.
  Add `@trace spec:inference-container, spec:proxy-container`.

## 3. Extend Squid allowlist

- [x] `images/proxy/allowlist.txt` — add three lines under the AI/ML section:
  `.models.dev`, `.openrouter.ai`, `.helicone.ai`. Keep alphabetical within the
  section if present; otherwise append. Ensure no bare-domain duplicates.

## 4. Update launch.rs test expectations

- [x] `src-tauri/src/launch.rs` tests that assert the exact NO_PROXY string
  (around lines 1091, 1126) — update to the new superset value. Keep the test
  intent: NO_PROXY contains the enclave bypass list.

## 5. Rebuild the proxy image

- [x] Run `scripts/build-image.sh proxy` to pick up the new allowlist.
- [x] Confirm the produced image tag is `tillandsias-proxy:v<FULL_VERSION>`.
- [x] No forge image rebuild required; profile changes take effect on next
  container launch.

## 6. Cheatsheet

- [x] `docs/cheatsheets/opencode-proxy-egress.md` — new cheatsheet documenting:
  - Which env vars OpenCode / Bun honour (table: var → effect → source).
  - The NO_PROXY rule (intra-enclave bypass; external traffic proxied).
  - How to add a new provider (allowlist + config snippet).
  - Links to Bun and OpenCode docs used in the research.
  - `@trace spec:opencode-web-session, spec:proxy-container,
    spec:inference-container`.

## 7. Smoke test (manual — user-driven, requires GUI)

- [x] Run `./build.sh --test` (all tests pass).
- [x] New AppImage installed to `~/Applications/Tillandsias.AppImage` via
  `./build.sh --release --install`. New proxy image tagged
  `tillandsias-proxy:v0.1.160.197`.
- [ ] USER: launch the AppImage, attach a project in web mode, send 3 prompts.
- [ ] USER: tail the proxy log during the session:
  `podman logs -f tillandsias-proxy 2>&1 | grep TCP_DENIED`. Expect zero output
  for `models.dev`, `inference:11434`, `0.0.0.0:11434`, and the selected
  provider.

## 8. Spec convergence + archive (after smoke test)

- [x] `openspec validate opencode-web-proxy-transparent` — passes.
- [ ] Run `/opsx:verify opencode-web-proxy-transparent` — confirm convergence.
- [ ] Archive via `/opsx:archive opencode-web-proxy-transparent`, bump changes with
  `./scripts/bump-version.sh --bump-changes`, commit with trace footer.
