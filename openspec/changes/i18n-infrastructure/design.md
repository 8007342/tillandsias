## Context

Tillandsias has approximately 150 unique user-facing strings spread across:

1. **Rust tray app** (`src-tauri/src/`): ~80 strings in menu labels, notifications, CLI output, error messages
2. **Shell scripts** (`images/default/`, `scripts/`, `gh-auth-login.sh`, `claude-api-key-prompt.sh`): ~50 strings in banners, install messages, prompts
3. **Build scripts** (`build.sh`, `build-image.sh`): ~20 strings (developer-facing, lower priority)

The i18n system must work across two very different runtimes (compiled Rust binary, POSIX shell scripts) without introducing heavy dependencies. The project already uses TOML for configuration and embeds files at compile time via `include_str!`.

**Constraints:**
- Zero new runtime dependencies preferred (no ICU, no gettext shared library)
- Must work offline (no locale downloads at runtime)
- Must work inside containers (forge image ships with locale files)
- Embedded in binary at compile time (no filesystem locale files on host)
- Shell scripts run inside containers where locale files can be on disk
- AJ never configures locale -- it must be detected automatically

## Goals / Non-Goals

**Goals:**
- Extract all user-facing strings from Rust code into keyed string tables
- Extract all user-facing strings from container shell scripts into sourced variable files
- Detect locale from OS environment at startup
- English as default fallback when locale is not detected or not supported
- Spanish as proof-of-concept second language
- Template interpolation for dynamic values (project names, versions, paths)
- Compile-time embedding of locale files (Rust side)
- Runtime loading from disk (shell script side, inside containers)

**Non-Goals:**
- Right-to-left (RTL) language support (not needed for English/Spanish)
- Plural forms beyond simple singular/plural (no CLDR integration)
- Locale-specific date/number formatting (not needed -- Tillandsias shows minimal dates)
- Developer-facing strings (build.sh, debug output) are NOT localized
- Localizing the `--help` text (stays English for searchability)
- Third-party translation management platforms (Crowdin, Transifex)
- Complete Spanish translation in this phase (proof-of-concept subset only)

## Decisions

### D1: TOML String Tables (Rust) -- No New Dependencies

**Choice:** Use TOML files for Rust-side string tables, parsed at compile time with `include_str!` and the existing `toml` crate.

```toml
# locales/en.toml
[menu]
quit = "Quit Tillandsias"
attach_here = "Attach Here"
root_terminal = "Root"
blooming = "Blooming"
maintenance = "Maintenance"
projects = "Projects"
no_projects = "No projects detected"
settings = "Settings"
version = "Tillandsias v{version}"
credit = "by Tlatoani"

[menu.github]
login = "GitHub Login"
login_refresh = "GitHub Login Refresh"
loading = "Loading..."
all_cloned = "All repos cloned locally"
login_first = "Login to GitHub first"
could_not_fetch = "Could not fetch repos"
cloning = "Cloning {name}..."

[menu.build]
in_progress = "Building {name}..."
maintenance_setup = "Setting up Maintenance..."
completed = "{name} ready"
failed = "{name} build failed"

[cli]
attaching = "Attaching to {name}"
checking_image = "Checking image... {tag}"
image_ready = "Image ready ({size})"
starting_env = "Starting environment..."
starting_terminal = "Starting terminal (fish shell)..."
launching = "Launching... (Ctrl+C to stop)"
env_stopped = "Environment stopped."

[errors]
setup = "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
env_not_ready = "Development environment not ready yet. Tillandsias will set it up automatically -- please try again in a few minutes."
install_incomplete = "Tillandsias installation may be incomplete. Please reinstall from https://github.com/8007342/tillandsias"
podman_unavailable = "Podman is not available"
no_terminal = "No terminal emulator found (tried ptyxis, gnome-terminal, konsole, xterm)"

[notifications]
already_running = "Already running -- look for '{title}' in your windows"
claude_key_saved = "Claude API key saved successfully"

[init]
preparing = "Tillandsias init -- preparing development environment"
already_ready = "Development environment already ready"
env_ready = "Environment ready"
ready_run = "Ready. Run: tillandsias"
setup_in_progress = "Setup already in progress, waiting..."
waiting = "Waiting for setup to complete..."
setting_up = "Setting up development environment..."
first_run_note = "(This may take a few minutes on first run)"
setup_failed = "Setup failed: {error}"
setup_timed_out = "Setup timed out. If this persists, please reinstall from https://github.com/8007342/tillandsias"
```

**Why TOML over other formats:**
- Already a dependency (`toml` crate used for `config.toml` parsing)
- Hierarchical keys match the string organization (menu.*, cli.*, errors.*)
- Human-readable and editable for translators
- Can be parsed at compile time via `include_str!` + `toml::from_str()`

**Alternatives considered:**
- **`fluent-rs` (Mozilla Fluent)**: Powerful (plurals, gender, selectors) but adds 3 new crates, learning curve for translators, overkill for ~150 strings. Could be adopted later if locale complexity grows.
- **`rust-i18n`**: Macro-based, requires proc-macro, adds compile-time complexity. Good DX but opinionated.
- **`gettext-rs`**: Requires `libintl` shared library, problematic in AppImage/container environments.
- **JSON string table**: No comments, no multi-line strings. TOML is superior for human editing.
- **Hardcoded HashMap**: Works but not editable by translators, no standard format.

### D2: Sourced Variable Files (Shell Scripts)

**Choice:** Use sourced shell variable files for shell script localization.

```bash
# images/default/locales/en.sh
L_INSTALLING_OPENCODE="Installing OpenCode..."
L_INSTALLED_OPENCODE="  ✓ OpenCode installed"
L_INSTALLING_CLAUDE="Installing Claude Code..."
L_INSTALLED_CLAUDE="  ✓ Claude Code installed"
L_INSTALL_FAILED_CLAUDE="  ✗ Claude Code install failed"
L_BANNER_FORGE="tillandsias forge"
L_BANNER_PROJECT="project:"
L_BANNER_AGENT="agent:"
L_AGENT_NOT_AVAILABLE="%s not available. Starting bash."
L_UNKNOWN_AGENT="Unknown agent '%s'. Starting bash."
```

Scripts load their locale via:
```bash
LOCALE="${LANG%%_*}"  # "en" from "en_US.UTF-8"
LOCALE_FILE="/etc/tillandsias/locales/${LOCALE}.sh"
[ -f "$LOCALE_FILE" ] || LOCALE_FILE="/etc/tillandsias/locales/en.sh"
source "$LOCALE_FILE"
```

**Why sourced variables over gettext .po:**
- Zero dependencies (no `gettext` binary needed in container)
- Shell-native pattern -- just variable expansion
- Easy to maintain for ~50 strings
- Templates use printf-style `%s` substitution (already familiar in shell)

**Alternatives considered:**
- **gettext `.po` files + `envsubst`/`gettext`**: Standard but requires gettext tools in the container image, adding image size. Overkill for the string count.
- **JSON with `jq`**: Requires `jq` in the image, fragile quoting, not shell-native.
- **Inline case statements**: No separate file for translators, not maintainable.

### D3: Locale Detection

**Choice:** Detect locale from OS environment variables in priority order.

**Rust (tray app / CLI):**
```rust
fn detect_locale() -> &'static str {
    // Check in priority order (POSIX standard)
    for var in ["LC_ALL", "LC_MESSAGES", "LANG", "LANGUAGE"] {
        if let Ok(val) = std::env::var(var) {
            let lang = val.split('_').next().unwrap_or("en");
            let lang = lang.split('.').next().unwrap_or("en");
            if is_supported(lang) {
                return lang;
            }
        }
    }
    // macOS-specific: read AppleLanguages
    #[cfg(target_os = "macos")]
    if let Ok(output) = std::process::Command::new("defaults")
        .args(["read", "-g", "AppleLanguages"])
        .output()
    {
        // Parse first language from plist array
    }
    "en" // fallback
}
```

**Shell (inside containers):**
```bash
LOCALE="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
LOCALE="${LOCALE%%_*}"  # Strip region: "en_US.UTF-8" -> "en"
LOCALE="${LOCALE%%.*}"  # Strip encoding: "en.UTF-8" -> "en"
```

**Why this order:** POSIX specifies `LC_ALL` overrides all others, then `LC_MESSAGES` for user-facing text, then `LANG` as the default. `LANGUAGE` is a GNU extension that allows fallback chains (e.g., `es:en`). On macOS, `LANG` is often not set by GUI apps; `AppleLanguages` is the canonical source.

### D4: Template Interpolation

**Choice:** Simple `{key}` placeholder replacement using `str::replace()`.

```rust
fn t(key: &str) -> String {
    let template = STRINGS.get(key).unwrap_or(key);
    template.to_string()
}

fn t_with(key: &str, vars: &[(&str, &str)]) -> String {
    let mut result = t(key);
    for (name, value) in vars {
        result = result.replace(&format!("{{{name}}}"), value);
    }
    result
}

// Usage:
let label = t_with("menu.build.in_progress", &[("name", "Forge")]);
// -> "Building Forge..."
```

**Why not a real template engine:** The interpolation needs are trivial -- named placeholders with string values. No conditionals, no loops, no type formatting. `str::replace()` is zero-dependency and handles the use case completely.

### D5: Compile-Time Embedding

**Choice:** Embed all locale TOML files at compile time. Parse once at startup (or lazily on first access).

```rust
const EN_TOML: &str = include_str!("../../locales/en.toml");
const ES_TOML: &str = include_str!("../../locales/es.toml");

static STRINGS: LazyLock<HashMap<String, String>> = LazyLock::new(|| {
    let locale = detect_locale();
    let toml_str = match locale {
        "es" => ES_TOML,
        _ => EN_TOML,
    };
    parse_flat_toml(toml_str)
});
```

**Why compile-time over runtime loading:** The Rust binary must work without any filesystem locale files. AppImages, macOS .app bundles, and Windows .exe files must be self-contained. Embedding at compile time also means the binary integrity covers locale files -- no tampering possible.

### D6: Phased Rollout

**Phase 1 (this change):**
- Infrastructure: `i18n.rs` module, locale detection, TOML parsing, template interpolation
- String extraction: English string table (`locales/en.toml`) with all ~80 Rust strings
- Shell locale files: `images/default/locales/en.sh` with ~50 shell strings
- Proof-of-concept Spanish: `locales/es.toml` and `images/default/locales/es.sh` with ~20 key strings translated

**Phase 2 (future):**
- Complete Spanish translation
- Community translation guide
- Additional languages based on user demand
- Possible migration to `fluent-rs` if plural/gender complexity grows

## Risks / Trade-offs

**[String count drift]** New features add strings. Developers may forget to add keys to all locale files. Mitigation: CI check that all keys in `en.toml` exist in `es.toml` (values can be empty/fallback).

**[Translation quality]** Machine translation is worse than no translation. Mitigation: Only ship human-reviewed translations. The developer is bilingual English/Spanish, so the proof-of-concept language has a native speaker.

**[Compile-time cost]** Adding 2 TOML files to `include_str!` is negligible.

**[Template injection]** If `{project_name}` contains `{version}`, nested replacement could corrupt strings. Mitigation: Single-pass replacement (not recursive). Project names come from filesystem directory names which cannot contain `{` or `}`.

## Open Questions

- Should the `--help` usage text be localized? It is typically left in English for searchability and Stack Overflow compatibility. Recommend: keep English.
- Should build script output (`build.sh`, `build-image.sh`) be localized? These are developer-facing. Recommend: no, leave English.
- Should the forge-welcome.sh tips be localized? These are user-facing inside the container. Recommend: yes, Phase 2.
