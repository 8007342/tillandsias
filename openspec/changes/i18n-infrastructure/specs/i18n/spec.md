## Capability: i18n

Internationalization infrastructure for Tillandsias. Provides locale detection, string lookup by key, template interpolation, and English/Spanish string tables for both Rust and shell script contexts.

## Requirements

### R1: Locale is detected automatically from OS environment

Detection priority (POSIX standard):
1. `LC_ALL` (overrides everything)
2. `LC_MESSAGES` (user-facing text category)
3. `LANG` (default locale)
4. `LANGUAGE` (GNU fallback chain, e.g., `es:en`)
5. macOS: `defaults read -g AppleLanguages` (GUI apps may not set `LANG`)

The detected locale is the 2-letter ISO 639-1 code (e.g., `en`, `es`), extracted by stripping the region and encoding from the raw value (e.g., `es_MX.UTF-8` -> `es`).

### R2: English is always the fallback

If the detected locale is not supported, English is used. If a specific key is missing from a non-English locale file, the English value is used. The system MUST never produce an empty string for a known key.

### R3: String tables use TOML format (Rust side)

Locale files live at `locales/{lang}.toml`. They are embedded at compile time via `include_str!`. Keys are dot-separated hierarchical paths matching the code organization:

```
menu.quit
menu.build.in_progress
errors.setup
cli.attaching
init.preparing
```

### R4: String tables use sourced variables (Shell side)

Locale files live at `images/default/locales/{lang}.sh`. Variables are prefixed with `L_` to avoid collisions. Files are sourced at the top of each script after locale detection.

### R5: Template interpolation uses `{name}` syntax

Dynamic values are inserted via named placeholders: `{project_name}`, `{version}`, `{error}`. Replacement is single-pass (no recursive expansion). The `t_with(key, vars)` function accepts a slice of `(name, value)` pairs.

### R6: Locale files are compile-time embedded (Rust) and image-embedded (Shell)

- Rust: `include_str!` bakes locale TOML into the binary. No filesystem access at runtime.
- Shell: Locale `.sh` files are baked into the container image during `nix build`. No network access at runtime.

### R7: Spanish is the proof-of-concept second language

`locales/es.toml` and `images/default/locales/es.sh` contain human-translated Spanish for a representative subset of strings (at minimum: menu labels, build chips, error messages, welcome banner). Keys not yet translated fall back to English per R2.

### R8: No new runtime dependencies

The TOML crate (`toml`) is already a dependency. No additional crates are added for i18n. String lookup uses a `HashMap<String, String>` populated at startup from the parsed TOML. Shell scripts use native variable expansion.

## Verification

- `cargo test --workspace` passes
- A test verifies every key in `en.toml` exists in `es.toml` (value may be empty for fallback)
- `LANG=es_MX.UTF-8 tillandsias --stats` shows Spanish output for translated keys
- `LANG=en_US.UTF-8 tillandsias --stats` shows English output
- Unsetting LANG entirely falls back to English
- Container entrypoint respects `$LANG` for install/banner messages
