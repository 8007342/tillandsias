## 1. Document Root Detection

- [ ] 1.1 Add `detect_document_root(project_path: &Path) -> PathBuf` function to `tillandsias-core` — checks for `public/`, `dist/`, `build/`, `_site/`, `out/` subdirectories in order, falls back to project root
- [ ] 1.2 Add `web.document_root` field to `ProjectConfig` for explicit override
- [ ] 1.3 Write unit tests: directory with `dist/` returns `dist/`, directory with nothing returns project root, explicit config overrides detection

## 2. Web Container Profile

- [ ] 2.1 Add `web()` built-in profile to `container_profile.rs`: entrypoint `/entrypoint.sh`, image `tillandsias-web:latest`, mount document_root at `/var/www:ro`, port 8080, no secrets, no env
- [ ] 2.2 Add `web.port` field to `ProjectConfig` for port override
- [ ] 2.3 Write unit tests: web profile produces correct args, no secrets mounted, read-only document root

## 3. Tray Menu Integration

- [ ] 3.1 Add "Serve Here" menu item to project submenus (alongside "Attach Here" and "Maintenance")
- [ ] 3.2 Use chain link emoji for web containers in the menu: `"🔗 Serve Here"`
- [ ] 3.3 Add `handle_serve_here()` handler in `handlers.rs`: detect document root, build web profile, launch container, print URL

## 4. CLI Mode

- [ ] 4.1 Add `--web` flag to CLI argument parser
- [ ] 4.2 Wire `--web` to use the web profile in `runner.rs`
- [ ] 4.3 Print `Serving at http://localhost:<port>` after successful launch

## 5. Container Lifecycle

- [ ] 5.1 Web containers use naming convention `tillandsias-<project>-web` (no genus allocation)
- [ ] 5.2 Don't-relaunch guard: if a web container for this project is already running, notify and skip
- [ ] 5.3 Web containers appear in tray state with `ContainerType::Web` and link emoji
- [ ] 5.4 Stop/Destroy actions work for web containers (reuse existing handlers)

## 6. Image Build Wiring

- [ ] 6.1 Ensure `build-image.sh web` is called when web image is missing (same pattern as forge auto-build in `handle_attach_here`)
- [ ] 6.2 Add web image staleness detection (currently only forge is auto-built)
- [ ] 6.3 Add `BuildProgressEvent` messages for web image build: "Building web server..." / "Web server ready"

## 7. Test

- [ ] 7.1 `cargo test --workspace` — all tests pass
- [ ] 7.2 Manual test: create a project with `public/index.html`, click "Serve Here", verify httpd serves the file
- [ ] 7.3 Manual test: `tillandsias --web <path>` — verify web container launches and URL is printed
- [ ] 7.4 Manual test: verify web container has NO access to secrets (no gh dir, no git config, no claude dir, no API key)
- [ ] 7.5 Manual test: verify port conflict handling — start two web containers, confirm different ports
- [ ] 7.6 Manual test: Stop web container from tray, verify it stops cleanly
