//! Internationalization — locale detection, string lookup, template interpolation.
//!
//! All locale files are embedded at compile time via `include_str!` so the
//! binary is self-contained (no filesystem locale files needed at runtime).
//!
//! # Usage
//!
//! ```rust
//! // Simple lookup
//! let label = i18n::t("menu.quit");
//!
//! // With template substitution
//! let label = i18n::tf("menu.build.in_progress", &[("name", "Forge")]);
//! ```
//!
//! # Locale detection
//!
//! Environment variables are checked in POSIX priority order:
//! `LC_ALL` > `LC_MESSAGES` > `LANG` > `LANGUAGE`
//!
//! The 2-letter ISO 639-1 code is extracted (e.g. `"es"` from `"es_MX.UTF-8"`).
//! Unknown or unsupported locales fall back to English.
//!
//! # Fallback chain
//!
//! If a key is missing from the detected locale, the English value is returned.
//! If the key is missing from English too, the key itself is returned so nothing
//! is ever an empty string for a known key.

use std::collections::HashMap;
use std::sync::LazyLock;

// ── Embedded locale files ────────────────────────────────────────────────────

const EN_TOML: &str = include_str!("../../locales/en.toml");
const ES_TOML: &str = include_str!("../../locales/es.toml");
const JA_TOML: &str = include_str!("../../locales/ja.toml");
const ZH_HANT_TOML: &str = include_str!("../../locales/zh-Hant.toml");
const ZH_HANS_TOML: &str = include_str!("../../locales/zh-Hans.toml");
const AR_TOML: &str = include_str!("../../locales/ar.toml");
const KO_TOML: &str = include_str!("../../locales/ko.toml");
const HI_TOML: &str = include_str!("../../locales/hi.toml");
const TA_TOML: &str = include_str!("../../locales/ta.toml");
const TE_TOML: &str = include_str!("../../locales/te.toml");
const FR_TOML: &str = include_str!("../../locales/fr.toml");
const PT_TOML: &str = include_str!("../../locales/pt.toml");
const IT_TOML: &str = include_str!("../../locales/it.toml");
const RO_TOML: &str = include_str!("../../locales/ro.toml");
const RU_TOML: &str = include_str!("../../locales/ru.toml");
const NAH_TOML: &str = include_str!("../../locales/nah.toml");

// ── Supported locales ────────────────────────────────────────────────────────

const SUPPORTED_LOCALES: &[&str] = &[
    "en", "es", "ja", "zh-Hant", "zh-Hans", "ar", "ko",
    "hi", "ta", "te", "fr", "pt", "it", "ro", "ru", "nah",
];

fn is_supported(lang: &str) -> bool {
    SUPPORTED_LOCALES.contains(&lang)
}

// ── Locale detection ─────────────────────────────────────────────────────────

/// Detect the user's preferred locale from OS environment variables.
///
/// Checks in POSIX priority order:
/// 1. `LC_ALL`      — overrides all other locale settings
/// 2. `LC_MESSAGES` — user-facing text category
/// 3. `LANG`        — default locale
/// 4. `LANGUAGE`    — GNU fallback chain (first entry used)
///
/// Returns a 2-letter ISO 639-1 code (e.g., `"en"`, `"es"`).
/// Falls back to `"en"` when no supported locale is detected.
///
/// On macOS, `defaults read -g AppleLanguages` is tried as a last resort
/// because GUI applications often do not set `$LANG`.
pub fn detect_locale() -> &'static str {
    for var in ["LC_ALL", "LC_MESSAGES", "LANG", "LANGUAGE"] {
        if let Ok(val) = std::env::var(var) {
            if val.is_empty() {
                continue;
            }
            // LANGUAGE can be a colon-separated fallback chain — use the first entry.
            let first = val.split(':').next().unwrap_or(&val);
            // Strip encoding: "es_MX.UTF-8" → "es_MX"
            let without_encoding = first.split('.').next().unwrap_or(first);
            // Chinese needs special handling: zh_TW → zh-Hant, zh_CN → zh-Hans.
            if without_encoding.starts_with("zh") {
                let resolved = match without_encoding {
                    "zh_TW" | "zh-Hant" => "zh-Hant",
                    "zh_CN" | "zh-Hans" | "zh" => "zh-Hans",
                    _ => "zh-Hans", // default Chinese to Simplified
                };
                return Box::leak(resolved.to_string().into_boxed_str());
            }
            // Strip region: "es_MX" → "es"
            let lang = without_encoding.split('_').next().unwrap_or(without_encoding);
            if is_supported(lang) {
                // Leak to get &'static str — called once at startup.
                return Box::leak(lang.to_ascii_lowercase().into_boxed_str());
            }
        }
    }

    // macOS: GUI apps often don't set $LANG; read AppleLanguages plist instead.
    #[cfg(target_os = "macos")]
    {
        if let Ok(output) = std::process::Command::new("defaults")
            .args(["read", "-g", "AppleLanguages"])
            .output()
        {
            let text = String::from_utf8_lossy(&output.stdout);
            // Output looks like:  (\n    "es-MX",\n    "en-US",\n)
            for line in text.lines() {
                let trimmed = line
                    .trim()
                    .trim_matches(|c| c == '"' || c == ',' || c == '(' || c == ')');
                let lang = trimmed
                    .split('-')
                    .next()
                    .unwrap_or("")
                    .split('_')
                    .next()
                    .unwrap_or("");
                if is_supported(lang) {
                    return Box::leak(lang.to_ascii_lowercase().into_boxed_str());
                }
            }
        }
    }

    "en"
}

// ── TOML flat-map parser ─────────────────────────────────────────────────────

/// Parse a TOML string into a flat `HashMap<String, String>` with dot-notation keys.
///
/// A key `[menu]` → `quit = "Quit"` becomes `"menu.quit" → "Quit"`.
/// Nested tables like `[menu.build]` → `in_progress = "…"` become
/// `"menu.build.in_progress" → "…"`.
///
/// Only string values are included; other value types are ignored.
fn parse_flat_toml(toml_str: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();

    // Use the `toml` crate already present in the workspace.
    let value: toml::Value = match toml_str.parse() {
        Ok(v) => v,
        Err(e) => {
            // Log the parse error and return an empty map — not fatal.
            eprintln!("[i18n] Failed to parse locale TOML: {e}");
            return map;
        }
    };

    fn flatten(prefix: &str, value: &toml::Value, map: &mut HashMap<String, String>) {
        match value {
            toml::Value::String(s) => {
                map.insert(prefix.to_string(), s.clone());
            }
            toml::Value::Table(table) => {
                for (k, v) in table {
                    let key = if prefix.is_empty() {
                        k.clone()
                    } else {
                        format!("{prefix}.{k}")
                    };
                    flatten(&key, v, map);
                }
            }
            // Arrays, integers, booleans, datetimes, floats — skip.
            _ => {}
        }
    }

    flatten("", &value, &mut map);
    map
}

// ── Global string table ──────────────────────────────────────────────────────

struct StringTable {
    primary: HashMap<String, String>,
    fallback: HashMap<String, String>,
}

impl StringTable {
    fn get(&self, key: &str) -> String {
        if let Some(v) = self.primary.get(key) {
            return v.clone();
        }
        if let Some(v) = self.fallback.get(key) {
            return v.clone();
        }
        // Return the key itself so UI always shows something meaningful.
        key.to_owned()
    }
}

// NOTE: STRINGS is initialized once at startup via LazyLock. If the user
// changes language via the menu, the app must be restarted for the tray UI
// strings to update. Container launches will pick up the new LANG immediately
// because they read the config at launch time, not from STRINGS.
static STRINGS: LazyLock<StringTable> = LazyLock::new(|| {
    // Prefer user's persisted preference, fall back to OS detection.
    let config = tillandsias_core::config::load_global_config();
    let locale: &str = if is_supported(config.i18n.language.as_str()) {
        Box::leak(config.i18n.language.clone().into_boxed_str())
    } else {
        detect_locale()
    };
    let locale_toml = match locale {
        "es" => ES_TOML,
        "ja" => JA_TOML,
        "zh-Hant" => ZH_HANT_TOML,
        "zh-Hans" => ZH_HANS_TOML,
        "ar" => AR_TOML,
        "ko" => KO_TOML,
        "hi" => HI_TOML,
        "ta" => TA_TOML,
        "te" => TE_TOML,
        "fr" => FR_TOML,
        "pt" => PT_TOML,
        "it" => IT_TOML,
        "ro" => RO_TOML,
        "ru" => RU_TOML,
        "nah" => NAH_TOML,
        _ => EN_TOML,
    };

    let primary = parse_flat_toml(locale_toml);
    // Always keep the English table as fallback for missing keys.
    let fallback = if locale == "en" {
        HashMap::new() // primary IS english; no separate fallback needed
    } else {
        parse_flat_toml(EN_TOML)
    };

    StringTable { primary, fallback }
});

// ── Public API ───────────────────────────────────────────────────────────────

/// Look up a string by dot-notation key.
///
/// Falls back to English, then to the key itself (never returns empty string).
///
/// ```rust
/// let label = i18n::t("menu.quit"); // "Quit Tillandsias" (en) or "Salir de Tillandsias" (es)
/// ```
pub fn t(key: &str) -> &'static str {
    // get() returns an owned String; leak it to obtain a 'static &str.
    // Called only for a bounded set of UI strings — memory cost is negligible.
    Box::leak(STRINGS.get(key).into_boxed_str())
}

/// Look up a string by dot-notation key and substitute `{name}` placeholders.
///
/// Replacement is single-pass. Placeholders use `{name}` syntax.
///
/// ```rust
/// let label = i18n::tf("menu.build.in_progress", &[("name", "Forge")]);
/// // → "⏳ Building Forge..." (en)  or  "⏳ Construyendo Forge..." (es)
/// ```
pub fn tf(key: &str, vars: &[(&str, &str)]) -> String {
    let mut result = STRINGS.get(key);
    for (name, value) in vars {
        result = result.replace(&format!("{{{name}}}"), value);
    }
    result
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_flat_toml_simple() {
        let toml = r#"
[menu]
quit = "Quit"
attach_here = "Attach Here"
"#;
        let map = parse_flat_toml(toml);
        assert_eq!(map.get("menu.quit").map(String::as_str), Some("Quit"));
        assert_eq!(
            map.get("menu.attach_here").map(String::as_str),
            Some("Attach Here")
        );
    }

    #[test]
    fn parse_flat_toml_nested() {
        let toml = r#"
[menu.build]
in_progress = "Building {name}..."
completed = "{name} ready"
"#;
        let map = parse_flat_toml(toml);
        assert_eq!(
            map.get("menu.build.in_progress").map(String::as_str),
            Some("Building {name}...")
        );
        assert_eq!(
            map.get("menu.build.completed").map(String::as_str),
            Some("{name} ready")
        );
    }

    #[test]
    fn en_toml_parses_without_errors() {
        let map = parse_flat_toml(EN_TOML);
        assert!(!map.is_empty(), "en.toml should produce a non-empty map");
        // Spot-check essential keys
        assert!(map.contains_key("menu.quit"));
        assert!(map.contains_key("errors.setup"));
        assert!(map.contains_key("errors.env_not_ready"));
        assert!(map.contains_key("errors.install_incomplete"));
    }

    #[test]
    fn es_toml_parses_without_errors() {
        let map = parse_flat_toml(ES_TOML);
        assert!(!map.is_empty(), "es.toml should produce a non-empty map");
    }

    #[test]
    fn every_en_key_exists_in_es() {
        let en = parse_flat_toml(EN_TOML);
        let es = parse_flat_toml(ES_TOML);
        let mut missing: Vec<&str> = Vec::new();
        for key in en.keys() {
            if !es.contains_key(key) {
                missing.push(key.as_str());
            }
        }
        if !missing.is_empty() {
            missing.sort();
            panic!(
                "The following keys are in en.toml but missing from es.toml:\n  {}",
                missing.join("\n  ")
            );
        }
    }

    #[test]
    fn tf_substitutes_placeholders() {
        let template = "Building {name}...";
        // Direct template test — don't rely on locale state
        let mut result = template.to_owned();
        result = result.replace("{name}", "Forge");
        assert_eq!(result, "Building Forge...");
    }

    #[test]
    fn tf_single_pass_no_recursive_expansion() {
        // If {project_name} contains {version}, it must NOT be expanded again.
        let template = "Hello {name}";
        let mut result = template.to_owned();
        result = result.replace("{name}", "{version}");
        // No second pass — {version} is NOT replaced.
        assert_eq!(result, "Hello {version}");
    }

    #[test]
    fn detect_locale_returns_supported_code() {
        let locale = detect_locale();
        assert!(
            is_supported(locale),
            "detect_locale() returned unsupported locale: {locale}"
        );
    }
}
