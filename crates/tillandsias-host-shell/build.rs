//! Build script for the shared host-shell crate.
//!
//! Reads the workspace VERSION file and exposes it as `WORKSPACE_VERSION`
//! so [`crate::version()`] returns the release version (`0.2.260528.1`)
//! rather than the crate's static `Cargo.toml` `version = "0.1.0"`. The
//! crate versions don't get bumped per release; the repo-root VERSION
//! file is the single source of truth (the install/build scripts already
//! quote it).
//!
//! This is the shared structural fix windows-host asked for in
//! `plan/issues/tray-convergence-coordination.md` (2026-05-30T11:00Z ASK
//! block). With this in place, all three tray runtimes — Linux (via the
//! provisioning fetch path that consumes [`crate::version()`]), macOS,
//! and Windows — see the workspace VERSION. The windows-tray's contained
//! `fresh_menu_state()` override (commit 6eb026e0) becomes structurally
//! redundant; it can stay as defence-in-depth but is no longer required
//! for correct behaviour.
//!
//! Fallback: if `../../VERSION` is unreadable (source-tarball builds, CI
//! cross-checks without a checkout) the script falls back to
//! `CARGO_PKG_VERSION` so `env!("WORKSPACE_VERSION")` always resolves.
//!
//! @trace spec:vm-provisioning-lifecycle, spec:tray-app

fn main() {
    let manifest_dir_path =
        std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default());
    let version_file = manifest_dir_path.join("../../VERSION");
    let workspace_version = std::fs::read_to_string(&version_file)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rerun-if-changed=../../VERSION");
    println!("cargo:rustc-env=WORKSPACE_VERSION={workspace_version}");

    generate_locale_strings(&manifest_dir_path);
}

/// 792-cf5x — the string layer's build-time half.
///
/// Emits `locale_strings_generated.rs` into `OUT_DIR`: one `pub const` per
/// `locales/en.toml` key, plus the per-locale override table. Two properties
/// make this a GATE rather than a convenience:
///
/// 1. A key referenced in Rust that no longer exists in `en.toml` becomes a
///    name-resolution error — the missing key is unrepresentable rather than
///    merely detected. (Nothing references these consts yet; that is slice
///    3's job. The generator ships first so the mechanism is proven before a
///    single user-visible byte moves.)
/// 2. Every non-`en` locale's key set must be a SUBSET of `en`'s. A locale
///    carrying a key `en` lacks is unresolvable by construction — dead
///    weight that looks like translation coverage. This is not theoretical:
///    it caught `menu.status.ready` surviving in `de` and `es` after `en`
///    renamed it to `ready_one`.
///
/// Deliberately asymmetric: a key MISSING from a non-`en` locale is normal
/// (14 of 17 locales are ~25 keys behind and fall back to `en`), so only
/// EXTRA keys fail. A gate that demanded full coverage would fail every
/// build on day one and be switched off within the hour.
///
/// The compile-time embed is not a preference: `locales/*.toml` ships in
/// zero artifacts today — the macOS `.app` carries 7 files and no TOML, the
/// Windows staging carries the exe plus three `.ps1`, and the Linux embedded
/// asset table has 411 entries and none from `locales/`. Runtime loading
/// would require a packaging change in all three release paths, and on macOS
/// it would have to precede `codesign --deep --strict`.
fn generate_locale_strings(manifest_dir: &std::path::Path) {
    let locales_dir = manifest_dir.join("../../locales");
    let en_path = locales_dir.join("en.toml");
    println!("cargo:rerun-if-changed=../../locales");

    let en_src = match std::fs::read_to_string(&en_path) {
        Ok(s) => s,
        Err(e) => panic!(
            "792-cf5x: cannot read {}: {e}\n\
             The shared tray string layer is generated from that file; a build \
             without it would silently ship no strings.",
            en_path.display()
        ),
    };
    let en_doc: toml::Value = toml::from_str(&en_src)
        .unwrap_or_else(|e| panic!("792-cf5x: {} is not valid TOML: {e}", en_path.display()));
    let mut en_keys: Vec<(String, String)> = Vec::new();
    flatten(&en_doc, String::new(), &mut en_keys);
    en_keys.sort();

    // Every other locale must be a subset. Collect ALL offenders before
    // failing: reporting one key per build turns a five-minute fix into five
    // builds.
    let mut offenders: Vec<String> = Vec::new();
    let mut entries: Vec<std::path::PathBuf> = std::fs::read_dir(&locales_dir)
        .map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    entries.sort();
    for path in entries {
        if path.extension().and_then(|s| s.to_str()) != Some("toml") {
            continue;
        }
        let stem = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or_default();
        if stem == "en" {
            continue;
        }
        let Ok(src) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(doc) = toml::from_str::<toml::Value>(&src) else {
            panic!("792-cf5x: {} is not valid TOML", path.display());
        };
        let mut keys: Vec<(String, String)> = Vec::new();
        flatten(&doc, String::new(), &mut keys);
        for (k, _) in &keys {
            if !en_keys.iter().any(|(ek, _)| ek == k) {
                offenders.push(format!(
                    "  {stem}.toml carries `{k}`, which en.toml does not define"
                ));
            }
        }
    }
    if !offenders.is_empty() {
        panic!(
            "792-cf5x: locale key sets diverged from en.toml:\n{}\n\n\
             en.toml defines the key set. A key only a translation carries can \
             never be resolved, so it is dead weight that reads as coverage. \
             Either add the key to en.toml or delete it from the translation.\n\
             (A key MISSING from a translation is fine — it falls back to en.)",
            offenders.join("\n")
        );
    }

    // No inner attribute here: the file is `include!`d INTO a module body,
    // where `#![...]` is a hard error. The consts are `pub`, so they need no
    // dead-code exemption anyway.
    let mut out = String::from(
        "// @generated by tillandsias-host-shell/build.rs (792-cf5x). Do not edit.\n\n",
    );
    for (key, value) in &en_keys {
        out.push_str(&format!(
            "/// `{key}` from locales/en.toml\npub const {}: &str = {};\n",
            const_name(key),
            escape(value)
        ));
    }
    out.push_str(&format!(
        "\n/// Number of keys en.toml defines — pinned so a corpus that silently \
         empties cannot pass as healthy.\npub const EN_KEY_COUNT: usize = {};\n",
        en_keys.len()
    ));

    let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR is always set for build scripts");
    let dest = std::path::Path::new(&out_dir).join("locale_strings_generated.rs");
    std::fs::write(&dest, out)
        .unwrap_or_else(|e| panic!("792-cf5x: cannot write {}: {e}", dest.display()));
}

fn flatten(value: &toml::Value, prefix: String, out: &mut Vec<(String, String)>) {
    let Some(table) = value.as_table() else {
        return;
    };
    for (k, v) in table {
        let key = if prefix.is_empty() {
            k.clone()
        } else {
            format!("{prefix}.{k}")
        };
        match v {
            toml::Value::String(s) => out.push((key, s.clone())),
            toml::Value::Table(_) => flatten(v, key, out),
            // Non-string scalars are not user-visible strings; ignore rather
            // than guess at a rendering for them.
            _ => {}
        }
    }
}

fn const_name(key: &str) -> String {
    key.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .collect()
}

fn escape(value: &str) -> String {
    // Rust string literal with everything non-obvious escaped, so an emoji or
    // a quote in a translation cannot break the generated file.
    let mut s = String::from("\"");
    for c in value.chars() {
        match c {
            '"' => s.push_str("\\\""),
            '\\' => s.push_str("\\\\"),
            '\n' => s.push_str("\\n"),
            '\r' => s.push_str("\\r"),
            '\t' => s.push_str("\\t"),
            c => s.push(c),
        }
    }
    s.push('"');
    s
}
