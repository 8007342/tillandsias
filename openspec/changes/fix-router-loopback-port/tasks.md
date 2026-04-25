## 1. Code

- [ ] 1.1 In `src-tauri/src/handlers.rs`, change the router publish line (currently `127.0.0.1:80:80` at ~`handlers.rs:902`) to `127.0.0.1:8080:80`. Add inline comment citing rootless podman + `ip_unprivileged_port_start`.
- [ ] 1.2 In `src-tauri/src/browser.rs::build_subdomain_url`, change the formatted URL from `http://{host_label}.opencode.localhost/` to `http://{host_label}.opencode.localhost:8080/`. Update the doc-comment to explain the port.

## 2. Tests

- [ ] 2.1 Update `browser.rs::tests::build_subdomain_url_no_ip_no_bare_localhost_no_port` — invert the no-port assertion to require `:8080/`. Rename to `build_subdomain_url_uses_rootless_port_8080`.
- [ ] 2.2 Update `build_subdomain_url_has_opencode_subdomain_no_port_no_path` to assert exact equality `http://thinking-service.opencode.localhost:8080/`.
- [ ] 2.3 Update `build_subdomain_url_lowercases_mixed_case_project` and `build_subdomain_url_sanitizes_invalid_label_chars` to expect the `:8080` suffix.

## 3. Cheatsheet + docs

- [ ] 3.1 Search `docs/cheatsheets/` for any `opencode.localhost` URL examples; update to `:8080`.
- [ ] 3.2 Same for `cheatsheets/agents/opencode.md` and `cheatsheets/runtime/networking.md` — add a one-line note about the `:8080` host port.

## 4. Build + verify

- [ ] 4.1 `cargo check --workspace` — clean.
- [ ] 4.2 `cargo test -p tillandsias --bin tillandsias browser` — updated tests green.
- [ ] 4.3 `./build.sh --install` — install the new build locally.
- [ ] 4.4 Manual: launch tray, attach a project, confirm browser opens `http://<project>.opencode.localhost:8080/` and the page loads.
- [ ] 4.5 Manual: `podman ps` shows `tillandsias-router` with port mapping `127.0.0.1:8080->80/tcp`. `curl -fsS http://<project>.opencode.localhost:8080/ -o /dev/null -w '%{http_code}\n'` returns a non-error code.
