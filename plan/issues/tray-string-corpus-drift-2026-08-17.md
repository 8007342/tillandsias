# Tray string corpus drift — en.toml vs what the trays actually render

<!-- provenance: 792-77bt (slice 2 of 628-c7qd). Regenerate with
     scripts/check-tray-string-corpus-drift.sh --list -->
<!-- freshness: auditor=macos-tlatoanis-macbook-air-fable5 date=2026-08-17 verdict=updated scope=792-77bt corrected — production text only, quoted-literal match -->

```
tray-string-drift: en_keys=168 rendered=5 unmatched=163 rendered_pct=2
```

## How to read these numbers

Three methods were run and they disagree in a way worth stating:

| method | matches | note |
|---|---:|---|
| bare substring, whole files | 18 | counted comments, test code, and substrings (`Maintenance` inside `🔧 Maintenance`) |
| bare substring, production text | 13 | comments and `#[cfg(test)]` removed |
| quoted literal, production text (this script) | 5 | does not decode `\u{...}` escapes, so it under-counts |
| exact literal with escapes decoded (cross-check) | 9 | the closest to truth |

So `rendered` here is a LOWER bound and `unmatched` an UPPER bound. Every
method agrees on the only thing that decides 628-c7qd: **over 90% of the
corpus is not what the trays render.**

The first version of this report counted comments and test modules — including
a pin added the day before that asserts `APP_NAME == "Tillandsias"`, which the
next run then counted as the tray rendering that string. A measurement that reads
its own assertions is not a measurement; that is corrected here.

## Why this decides 628-c7qd's direction

628-c7qd requires the refactor to be BYTE-IDENTICAL at the surface while
resolving every string from this corpus. Both cannot hold. The corpus must be
regenerated FROM the shipped literals (code → toml), and each entry below is a
drift finding for **628-w9sm** to rule on — never fixed in passing
(spec:tray-ux governance).

## en.toml values whose quoted literal appears nowhere in production tray text

```
  root_terminal = "🛠️ Root"
  projects = "🏠 ~/src"
  cloud_projects = "☁️ Cloud"
  no_projects = "No projects detected"
  settings = "Settings"
  quit = "Quit Tillandsias"
  blooming = "Blooming"
  maintenance = "⛏️ Maintenance"
  stop = "🛑 Stop"
  serve_here = "🔗 Serve Here"
  serving = "🔗 Serving"
  seedlings = "🌱 Seedlings"
  language = "Language"
  credit = "by Tlatoāni"
  version = "Tillandsias v{version}"
  sign_in_github = "🔑 GitHub Login"
  attach_here_with_emoji = "🌱 Attach Here"
  attach_another_with_emoji = "🌱 Attach Another"
  clone_and_launch = "⬇️ Clone & Launch"
  signature_with_version = "v{version} — by Tlatoāni"
  verifying_environment = "Verifying environment …"
  building_one = "Building {image} …"
  building_many = "Building {images} …"
  ready_one = "{image} OK"
  environment_ready = "✅ Environment ready"
  github_unreachable = "GitHub unreachable — using cached list"
  label = "GitHub"
  login = "🔑 GitHub Login"
  login_refresh = "🔒 GitHub Login Refresh"
  loading = "Loading..."
  all_cloned = "All repos cloned locally"
  login_first = "Login to GitHub first"
  could_not_fetch = "Could not fetch repos"
  cloning = "Cloning {name}..."
  remote_projects = "Remote Projects"
  reset_credentials = "🔒 Claude Reset Credentials"
  already_serving = "Already serving — open http://localhost:{port}"
  in_progress = "⏳ Building {name}..."
  maintenance_setup = "⛏️ Setting up Maintenance..."
  completed = "✅ {name} ready"
  failed = "❌ {name} build failed"
  chip_browser_runtime = "Browser runtime"
  chip_enclave = "Enclave network"
  chip_proxy = "Proxy"
  chip_inference_engine = "Inference Engine"
  chip_router = "Router"
  chip_code_mirror = "Code Mirror"
  chip_git_service = "Git Service"
  chip_forge = "Development Environment"
  chip_web_server = "Web Server"
  chip_software_layer = "Software Layer"
  attaching = "Tillandsias — Attaching to {name}"
  checking_image = "Checking image... {tag}"
  ensuring_image = "Ensuring image is up to date..."
  image_ready = "✓ Image ready ({size})"
  starting_env = "Starting environment..."
  starting_terminal = "Starting terminal (fish shell)..."
  launching = "Launching... (Ctrl+C to stop)"
  env_stopped = "Environment stopped."
  waiting_setup = "Waiting for environment setup to complete..."
  preparing = "Tillandsias init — preparing development environment"
  already_ready = "✓ Development environment already ready"
  ready = "Ready."
  setup_in_progress = "⌛ Setup already in progress, waiting..."
  setup_timed_out = "✗ Setup timed out. If this persists, please reinstall from https://github.com/8007342/tillandsias"
  env_ready = "✓ Environment ready"
  waiting = "⌛ Waiting for setup to complete..."
  setting_up = "Setting up development environment..."
  first_run_note = "(This may take a few minutes on first run)"
  dev_env_ready = "✓ Development environment ready"
  ready_run = "Ready. Run: tillandsias"
  setup_failed = "✗ Setup failed: {error}"
  setup = "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
  env_not_ready = "Development environment not ready yet. Tillandsias will set it up automatically — please try again in a few minutes."
  install_incomplete = "Tillandsias installation may be incomplete. Please reinstall from https://github.com/8007342/tillandsias"
  podman_unavailable = "Podman is not available"
  no_podman = "Error: podman is not installed or not in PATH"
  genera_exhausted = "All genera exhausted for project {name}"
  terminal_failed = "Failed to open terminal: {error}"
  no_terminal = "No terminal emulator found (tried ptyxis, gnome-terminal, konsole, xterm)"
  already_running = "Already running — look for '{title}' in your windows"
  claude_credentials_cleared = "Claude credentials cleared. Next launch will prompt for authentication."
  forge_not_ready = "Setting up — please wait a moment."
  forge_ready = "Ready — you can now attach to any project."
  infrastructure_failed = "Setup encountered an issue. Some features may be slow."
  tools_updated = "Development tools have been updated. New environments will use the latest versions."
  title = "Tillandsias — disk usage report"
  images_label = "Images:"
  images_none = "Images:     (none)"
  images_no_podman = "Images:     (podman not available)"
  containers_label = "Containers:"
  containers_none = "Containers: (none)"
  containers_no_podman = "Containers: (podman not available)"
  nix_cache_label = "Nix cache:"
  nix_cache_present = "Nix cache:       {path} ({size})"
  nix_cache_not_present = "Nix cache:       (not present)"
  cargo_cache_label = "Cargo cache:"
  cargo_cache_present = "Cargo cache:     {path} ({size})"
  cargo_cache_not_present = "Cargo cache:     (not present)"
  binary_present = "Installed binary: {path} ({size})"
  binary_not_present = "Installed binary: (not installed at {path})"
  last_update = "Last update:      {entry}"
  no_update_log = "(no update log)"
  total = "Total (caches + binary): {size}"
  podman_note = "(Podman image storage is managed by podman — see 'podman system df')"
  title = "Tillandsias — artifact cleanup"
  complete = "Cleanup complete."
  nothing = "Nothing to clean."
  images_none_dangling = "Images:     no dangling images to remove"
  images_removed = "Images:     removed {count} dangling image(s)"
  images_no_podman = "Images:     (podman not available — skipped)"
  containers_none_stopped = "Containers: no stopped tillandsias containers"
  containers_removing = "Containers: removing {count} stopped container(s)..."
  container_removed = "  removed: {name}"
  container_failed = "  failed to remove: {name}"
  containers_no_podman = "Containers: (podman not available — skipped)"
  nix_cache_removed = "Nix cache:  removed {path} ({size})"
  nix_cache_failed = "Nix cache:  failed to remove {path}: {error}"
  nix_cache_not_present = "Nix cache:  (not present)"
  version = "Tillandsias v{version}"
  checking = "Checking for updates..."
  up_to_date = "Already up to date."
  available = "Update available: v{version}"
  downloading = "Downloading..."
  downloaded = "Downloaded ({size})"
  applying = "Applying update..."
  updated = "Updated to v{version}"
  restart_note = "Restart the application to use the new version."
  fetch_error = "Error: failed to fetch update manifest: {error}"
  parse_error = "Error: failed to parse update manifest: {error}"
  no_artifact = "Error: no update artifact found for platform '{platform}' in manifest"
  available_platforms = "Available platforms: {platforms}"
  manual_download = "Download the new version manually from:"
  download_error = "Error: download failed: {error}"
  apply_error = "Error: failed to apply update: {error}"
  image_ready = "✓ {name}: {tag} (ready)"
  building = "Building {name}..."
  waiting_for_build = "  Waiting for another build..."
  build_success = "✓ {name}: {tag}"
  build_failed = "✗ {name}: build failed (exit {code})"
  build_error = "✗ {name}: {error}"
  some_failed = "Some images failed to build. Run with --debug for details."
  failed_logs_header = "Failed build logs (--debug):"
  enclave_title = "Enclave images:"
  proxy_desc = "  ✓ proxy      — caching HTTPS proxy with domain allowlist"
  forge_desc = "  ✓ forge      — development environment"
  git_desc = "  ✓ git        — git mirror service (bare repos + daemon)"
  inference_desc = "  ✓ inference  — local LLM (ollama)"
  tools_overlay = "Building software layer (Claude Code, OpenSpec, OpenCode)..."
  tools_overlay_ready = "✓ Software layer ready"
  skipping = "↷ {name}: {tag} (already built, skipping)"
  title = "Tillandsias v{version}"
  os_label = "OS:"
  podman_label = "Podman:"
  podman_not_found = "not found"
  forge_ready = "{tag} (ready)"
  forge_update_needed = "update needed (current: {current}, expected: {expected})"
  forge_not_built = "not built (run: tillandsias init)"
  install_podman = "Install podman to use Tillandsias."
  log_invalid_pair = "Warning: Invalid log pair (expected module:level): {pair}"
  log_unknown_module = "Warning: Unknown log module: {module}. Valid modules: {valid}"
  log_invalid_level = "Error: Invalid log level: {level}. Valid levels: {valid}"
  flag_requires_value = "Error: {flag} requires a value"
tray-string-drift: en_keys=168 rendered=5 unmatched=163 rendered_pct=2
```
