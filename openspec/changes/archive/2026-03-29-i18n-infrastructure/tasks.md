## String Inventory

Complete inventory of user-facing strings organized by source file and i18n key.

### Rust Tray App Strings (~80)

#### menu.rs — Tray Menu Labels

| Line | Current String | Proposed Key |
|------|----------------|--------------|
| 124-130 | `"{name}/ — Attach Here"` | `menu.src_attach_here` |
| 139 | `"🛠️ Root"` | `menu.root_terminal` |
| 191 | `"Quit Tillandsias"` | `menu.quit` |
| 220 | `"Podman is not available"` | `errors.podman_unavailable` |
| 250 | `"Projects"` | `menu.projects` |
| 254 | `"No projects detected"` | `menu.no_projects` |
| 268 | `"🌱 Attach Here"` | `menu.attach_here` |
| 273 | `"⛏️ Maintenance"` | `menu.maintenance` |
| 291 | `"Settings"` | `menu.settings` |
| 297 | `"🔒 GitHub Login Refresh"` | `menu.github.login_refresh` |
| 299 | `"🔑 GitHub Login"` | `menu.github.login` |
| 301 | `"GitHub"` | `menu.github` |
| 323 | `"Tillandsias v{version}"` | `menu.version` |
| 328 | `"by Tlatoāni"` | `menu.credit` |
| 349 | `"Cloning {name}..."` | `menu.github.cloning` |
| 360 | `"Loading..."` | `menu.github.loading` |
| 371 | `"Login to GitHub first"` | `menu.github.login_first` |
| 373 | `"Could not fetch repos"` | `menu.github.could_not_fetch` |
| 406 | `"All repos cloned locally"` | `menu.github.all_cloned` |
| 437 | `"🌱 Seedlings"` | `menu.seedlings` |
| 447 | `"📌 {name}"` | `menu.agent_selected` |
| 460 | `"🔒 Claude Login Refresh"` | `menu.claude.login_refresh` |
| 462 | `"🔑 Claude Login"` | `menu.claude.login` |
| 510 | `"{flower} Blooming"` | `menu.blooming` |
| 528 | `"⛏️ Maintenance"` (idle) | `menu.maintenance` (reuse) |
| 550 | `"⛏️ Setting up Maintenance..."` | `menu.build.maintenance_setup` |
| 552 | `"⏳ Building {name}..."` | `menu.build.in_progress` |
| 555 | `"✅ {name} ready"` | `menu.build.completed` |
| 556 | `"❌ {name} build failed"` | `menu.build.failed` |

#### handlers.rs — Notifications and Error Messages

| Line | Current String | Proposed Key |
|------|----------------|--------------|
| 552 | `"Already running — look for '{title}' in your windows"` | `notifications.already_running` |
| 554 | `"Tillandsias"` (notification title) | `app.name` |
| 566 | `"All genera exhausted for project {name}"` | `errors.genera_exhausted` |
| 624 | `"Development environment not ready yet..."` | `errors.env_not_ready` |
| 641, 651, 1235, 1243 | `"Tillandsias is setting up..."` | `errors.setup` |
| 705 | `"Failed to open terminal: {error}"` | `errors.terminal_failed` |
| 900, 1064 | `"Development environment not ready yet..."` | `errors.env_not_ready` (reuse) |
| 1259, 1281 | `"Tillandsias installation may be incomplete..."` | `errors.install_incomplete` |
| 1327 | `"Claude API key saved successfully"` | `notifications.claude_key_saved` |

#### init.rs — Init Command Output

| Line | Current String | Proposed Key |
|------|----------------|--------------|
| 13 | `"Tillandsias init — preparing development environment"` | `init.preparing` |
| 20 | `"✓ Development environment already ready"` | `init.already_ready` |
| 22 | `"Ready."` | `init.ready` |
| 28 | `"⌛ Setup already in progress, waiting..."` | `init.setup_in_progress` |
| 31 | `"✗ Setup timed out..."` | `init.setup_timed_out` |
| 35 | `"✓ Environment ready"` | `init.env_ready` |
| 47 | `"⌛ Waiting for setup to complete..."` | `init.waiting` |
| 59 | `"Setting up development environment..."` | `init.setting_up` |
| 60 | `"(This may take a few minutes on first run)"` | `init.first_run_note` |
| 71 | `"✓ Development environment ready"` | `init.dev_env_ready` |
| 73 | `"Ready. Run: tillandsias"` | `init.ready_run` |
| 78 | `"✗ Setup failed: {error}"` | `init.setup_failed` |

#### runner.rs — CLI Attach Output

| Line | Current String | Proposed Key |
|------|----------------|--------------|
| 36 | `"Waiting for environment setup to complete..."` | `cli.waiting_setup` |
| 275 | `"Tillandsias — Attaching to {name}"` | `cli.attaching` |
| 281 | `"Checking image... {tag}"` | `cli.checking_image` |
| 294 | `"Error: podman is not installed or not in PATH"` | `errors.no_podman` |
| 307 | `"Ensuring image is up to date..."` | `cli.ensuring_image` |
| 318 | `"✓ Image ready ({size})"` | `cli.image_ready` |
| 320 | `"✗ Development environment not ready yet..."` | `errors.env_not_ready` |
| 357 | `"Starting terminal (fish shell)..."` | `cli.starting_terminal` |
| 359 | `"Starting environment..."` | `cli.starting_env` |
| 376 | `"Launching... (Ctrl+C to stop)"` | `cli.launching` |
| 390 | `"Environment stopped."` | `cli.env_stopped` |

#### cleanup.rs — Stats and Clean Output

| Line | Current String | Proposed Key |
|------|----------------|--------------|
| 104 | `"Tillandsias — disk usage report"` | `stats.title` |
| 126 | `"Images:     (none)"` | `stats.images_none` |
| 134 | `"Images:     (podman not available)"` | `stats.images_no_podman` |
| 151 | `"Containers: (none)"` | `stats.containers_none` |
| 159 | `"Containers: (podman not available)"` | `stats.containers_no_podman` |
| 195 | `"Total (caches + binary): {size}"` | `stats.total` |
| 196 | `"(Podman image storage is managed by podman...)"` | `stats.podman_note` |
| 206 | `"Tillandsias — artifact cleanup"` | `clean.title` |
| 283 | `"Cleanup complete."` | `clean.complete` |
| 285 | `"Nothing to clean."` | `clean.nothing` |

#### update_cli.rs — Update Command Output

| Line | Current String | Proposed Key |
|------|----------------|--------------|
| 87 | `"Tillandsias v{version}"` | `update.version` |
| 88 | `"Checking for updates..."` | `update.checking` |
| 113 | `"Already up to date."` | `update.up_to_date` |
| 117 | `"Update available: v{version}"` | `update.available` |
| 144 | `"Downloading..."` | `update.downloading` |
| 155 | `"Downloaded ({size})"` | `update.downloaded` |
| 158 | `"Applying update..."` | `update.applying` |
| 169 | `"Updated to v{version}"` | `update.updated` |
| 170 | `"Restart the application to use the new version."` | `update.restart_note` |

### Shell Script Strings (~50)

#### images/default/entrypoint.sh

| Line | Current String | Proposed Key |
|------|----------------|--------------|
| 50 | `"Installing OpenCode..."` | `L_INSTALLING_OPENCODE` |
| 62 | `"  done OpenCode ..."` | `L_INSTALLED_OPENCODE` |
| 73 | `"Installing Claude Code..."` | `L_INSTALLING_CLAUDE` |
| 78 | `"  done Claude Code installed"` | `L_INSTALLED_CLAUDE` |
| 80 | `"  Claude Code install failed"` | `L_INSTALL_FAILED_CLAUDE` |
| 88 | `"Installing OpenSpec..."` | `L_INSTALLING_OPENSPEC` |
| 116 | `"tillandsias forge"` | `L_BANNER_FORGE` |
| 128 | `"Claude Code not available. Starting bash."` | `L_AGENT_NOT_AVAILABLE` |

#### images/default/forge-welcome.sh

| Line | Current String | Proposed Key |
|------|----------------|--------------|
| 74 | `"🌱 Tillandsias Forge"` | `L_WELCOME_TITLE` |
| 76 | `"Project"` | `L_WELCOME_PROJECT` |
| 77 | `"Forge"` | `L_WELCOME_FORGE` |
| 79 | `"Mounts"` | `L_WELCOME_MOUNTS` |
| 89 | `"Project at /home/forge/src/{name}"` | `L_WELCOME_PROJECT_AT` |
| 46-66 | Tips array (20 entries) | `L_TIP_1` through `L_TIP_20` |

#### scripts/install.sh

| Line | Current String | Proposed Key |
|------|----------------|--------------|
| 28 | `"Tillandsias Installer"` | `L_INSTALLER_TITLE` |
| 38 | `"Finding latest release..."` | `L_FINDING_RELEASE` |
| 41 | `"Cannot reach GitHub API."` | `L_CANNOT_REACH_GITHUB` |
| 64 | `"Installing AppImage to ~/.local/bin/ (no root required)..."` | `L_INSTALLING_APPIMAGE` |
| 83 | `"✓ Installed AppImage to..."` | `L_INSTALLED_APPIMAGE` |
| 236 | `"Run: tillandsias"` | `L_RUN_TILLANDSIAS` |

#### scripts/uninstall.sh

| Line | Current String | Proposed Key |
|------|----------------|--------------|
| 21 | `"Tillandsias Uninstaller"` | `L_UNINSTALLER_TITLE` |
| 27 | `"✓ Removed binary"` | `L_REMOVED_BINARY` |
| 66 | `"Tillandsias uninstalled."` | `L_UNINSTALLED` |

---

## Tasks

### 1. Create i18n infrastructure (Rust)

- [ ] 1.1 Create `src-tauri/src/i18n.rs` with: `detect_locale()`, `t(key)`, `t_with(key, vars)`, TOML parsing
- [ ] 1.2 Create `locales/en.toml` with all ~80 Rust-side string keys (complete English)
- [ ] 1.3 Create `locales/es.toml` with proof-of-concept subset (~20 key strings in Spanish)
- [ ] 1.4 Add `mod i18n;` to `main.rs`
- [ ] 1.5 Wire `include_str!("../../locales/en.toml")` and `include_str!("../../locales/es.toml")` in `i18n.rs`

### 2. Create i18n infrastructure (Shell scripts)

- [ ] 2.1 Create `images/default/locales/en.sh` with all ~50 shell string variables
- [ ] 2.2 Create `images/default/locales/es.sh` with proof-of-concept subset (~15 strings)
- [ ] 2.3 Add locale sourcing to `images/default/entrypoint.sh` (detect `$LANG`, source locale file)
- [ ] 2.4 Add locale sourcing to `images/default/forge-welcome.sh`
- [ ] 2.5 Update `flake.nix` / Containerfile to include locale files in the image

### 3. Replace hardcoded strings in Rust (menu.rs)

- [ ] 3.1 Replace all menu label literals with `i18n::t("menu.*")` calls
- [ ] 3.2 Replace `build_chip_label()` literals with `i18n::t_with("menu.build.*", ...)`
- [ ] 3.3 Replace settings submenu labels with `i18n::t("menu.settings.*")`

### 4. Replace hardcoded strings in Rust (handlers.rs)

- [ ] 4.1 Replace notification messages with `i18n::t()` / `i18n::t_with()`
- [ ] 4.2 Replace error messages with `i18n::t("errors.*")`

### 5. Replace hardcoded strings in Rust (CLI commands)

- [ ] 5.1 Replace `init.rs` messages with `i18n::t("init.*")`
- [ ] 5.2 Replace `runner.rs` messages with `i18n::t("cli.*")`
- [ ] 5.3 Replace `cleanup.rs` messages with `i18n::t("stats.*")` / `i18n::t("clean.*")`
- [ ] 5.4 Replace `update_cli.rs` messages with `i18n::t("update.*")`

### 6. Replace hardcoded strings in shell scripts

- [ ] 6.1 Replace `entrypoint.sh` echo statements with `$L_*` variables
- [ ] 6.2 Replace `forge-welcome.sh` labels with `$L_*` variables
- [ ] 6.3 Replace `install.sh` messages with `$L_*` variables (optional -- may stay English)
- [ ] 6.4 Replace `uninstall.sh` messages with `$L_*` variables (optional -- may stay English)

### 7. Locale detection and wiring

- [ ] 7.1 Implement `detect_locale()` in `i18n.rs` with `LC_ALL` > `LC_MESSAGES` > `LANG` > `LANGUAGE` priority
- [ ] 7.2 Add macOS `defaults read -g AppleLanguages` fallback
- [ ] 7.3 Pass detected locale to containers via `-e LANG=...` in podman run args (if not already inherited)

### 8. CI key completeness check

- [ ] 8.1 Add a test or script that verifies every key in `en.toml` exists in `es.toml` (value can be empty = fallback to English)

### 9. Verification

- [ ] 9.1 `cargo build --workspace` compiles
- [ ] 9.2 `cargo test --workspace` passes
- [ ] 9.3 Set `LANG=es_MX.UTF-8`, launch tray -- verify Spanish labels appear
- [ ] 9.4 Set `LANG=en_US.UTF-8`, launch tray -- verify English labels appear
- [ ] 9.5 Unset `LANG`, launch tray -- verify English fallback
- [ ] 9.6 Enter forge container, verify entrypoint uses locale-appropriate messages
- [ ] 9.7 Enter forge container with `LANG=es_MX.UTF-8`, verify Spanish welcome message
