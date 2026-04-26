## 1. Code

- [ ] 1.1 In `src-tauri/src/browser.rs::build_subdomain_url`, change the format string from `format!("http://{host_label}.opencode.localhost:8080/")` to `format!("http://opencode.{host_label}.localhost:8080/")`.
- [ ] 1.2 Update the doc-comment block above `build_subdomain_url` to reflect the new ordering and the future-services rationale.
- [ ] 1.3 In `src-tauri/src/handlers.rs::regenerate_router_caddyfile` (~line 1024-1029), change the `snippet.push_str` format from `"{project}.opencode.localhost:80 { ... reverse_proxy tillandsias-{project}-forge:4096 ... }"` to `"opencode.{project}.localhost:80 { ... reverse_proxy tillandsias-{project}-forge:4096 ... }"`. The reverse-proxy target is unchanged.

## 2. Tests

- [ ] 2.1 Update `browser.rs::tests::build_subdomain_url_has_opencode_subdomain_port_8080_no_path` — expected URL becomes `http://opencode.thinking-service.localhost:8080/`.
- [ ] 2.2 Update `build_subdomain_url_uses_rootless_port_8080` — assert URL ends with `.localhost:8080/` and starts with `http://opencode.`.
- [ ] 2.3 Update `build_subdomain_url_lowercases_mixed_case_project` — `MyProject` → `http://opencode.myproject.localhost:8080/`.
- [ ] 2.4 Update `build_subdomain_url_sanitizes_invalid_label_chars` — `My App/sub` → `http://opencode.my-app-sub.localhost:8080/`.

## 3. Cheatsheet update

- [ ] 3.1 In `cheatsheets/agents/opencode.md`, update URL examples under the "Tillandsias-specific path" table from `<project>.opencode.localhost` to `opencode.<project>.localhost`. Cheatsheet still carries DRAFT banner — provenance retrofit happens later.

## 4. In-flight change cleanup

- [ ] 4.1 The `fix-router-loopback-port` change (in flight, not yet archived) used the `<project>.opencode.localhost:8080` shape. Update its `specs/opencode-web-session/spec.md` to use the new shape so the two changes are consistent. Both changes can land independently; the URL flip is purely string-shape.

## 5. Build + verify

- [ ] 5.1 `cargo check --workspace` — clean.
- [ ] 5.2 `cargo test -p tillandsias --bin tillandsias browser` — all four updated tests green.
- [ ] 5.3 No runtime change to verify beyond the test pass; URL is purely a string. Live verification happens on the next `./build.sh --install` cycle.
