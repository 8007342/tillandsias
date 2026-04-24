# tasks

## 1. Fix overlay schema + lock providers

- [x] `images/default/config-overlay/opencode/config.json`: replace
  `provider.ollama.api_url` with `provider.ollama.options.baseURL =
  "http://inference:11434/v1"`.
- [x] Add `enabled_providers: ["ollama"]`.
- [x] Add `default_agent: "build"`.

## 2. Apply overlay in entrypoint

- [x] `images/default/entrypoint-forge-opencode-web.sh`: after the tools
  overlay gate, copy `/home/forge/.config-overlay/opencode/config.json` ->
  `/home/forge/.config/opencode/config.json` and the `tui.json` equivalent.
  Add `@trace spec:opencode-web-session, spec:layered-tools-overlay` comments.

## 3. Enable webview devtools unconditionally

- [x] `src-tauri/src/webview.rs`: remove the `#[cfg(debug_assertions)]` gate
  around `.devtools(true)` so the inspector is available in release builds.
  Add an `@trace spec:opencode-web-session` comment explaining the choice.

## 4. Build + verify

- [x] `./build.sh --check` passes.
- [ ] `./build.sh --release --install` produces a new AppImage and forge
  image.
- [ ] New proxy image unchanged (no allowlist touch in this change).

## 5. Smoke test (user-driven, requires GUI)

- [ ] Launch the new AppImage. Attach a project in web mode.
- [ ] Press F12 in the OpenCode Web window — inspector must open.
- [ ] In a shell: `curl http://127.0.0.1:<port>/config | jq
  '.provider.ollama.options.baseURL'` returns `"http://inference:11434/v1"`.
- [ ] In a shell: `curl http://127.0.0.1:<port>/config/providers | jq
  '.providers[].id'` returns exactly `"ollama"`.
- [ ] UI loads with dark theme immediately (no light-theme flash).

## 6. Spec convergence + archive

- [x] `openspec validate opencode-web-config-isolation` passes.
- [ ] `/opsx:verify opencode-web-config-isolation` after smoke test.
- [ ] `/opsx:archive opencode-web-config-isolation`, bump version, commit with
  trace footer.
