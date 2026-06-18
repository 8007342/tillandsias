// tillandsias-cheatsheet-tools — Rust replacements for the cheatsheet
// maintenance scripts that previously embedded Python heredocs. Per the
// no-Python-runtime policy (methodology.yaml), repository tooling must be Rust.
//
// Subcommands:
//   tiers [--quiet] [--strict]   tier-aware cheatsheet frontmatter validation
//                                (faithful port of scripts/check-cheatsheet-tiers.sh's
//                                 former Python implementation)
//
// @trace spec:cheatsheets-license-tiered

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("tiers") => cmd_tiers(&args[1..]),
        Some(other) => {
            eprintln!("unknown subcommand: {other}");
            eprintln!("usage: tillandsias-cheatsheet-tools tiers [--quiet] [--strict]");
            ExitCode::from(2)
        }
        None => {
            eprintln!("usage: tillandsias-cheatsheet-tools tiers [--quiet] [--strict]");
            ExitCode::from(2)
        }
    }
}

fn repo_root() -> PathBuf {
    // Prefer git toplevel; fall back to the binary's ../.. like the shell wrapper.
    if let Ok(out) = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        && out.status.success()
    {
        let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !s.is_empty() {
            return PathBuf::from(s);
        }
    }
    // Fall back to current dir; the wrapper always runs from the repo root.
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn cmd_tiers(args: &[String]) -> ExitCode {
    let mut quiet = false;
    let mut strict = false;
    for a in args {
        match a.as_str() {
            "--quiet" => quiet = true,
            "--strict" => strict = true,
            _ => {
                eprintln!("usage: tillandsias-cheatsheet-tools tiers [--quiet] [--strict]");
                return ExitCode::from(2);
            }
        }
    }
    // Environment overrides mirror the former shell/python interface.
    let show_notes = std::env::var("SHOW_NOTES").ok().as_deref() == Some("1");

    let root = repo_root();
    let cheatsheets_dir = root.join("cheatsheets");
    let flake_path = root.join("flake.nix");
    let containerfile_path = root.join("images/default/Containerfile");

    if !cheatsheets_dir.is_dir() {
        eprintln!(
            "ERROR: cheatsheets/ directory not found at {}",
            cheatsheets_dir.display()
        );
        return ExitCode::from(1);
    }

    let allowed_tiers: BTreeSet<&str> = ["bundled", "distro-packaged", "pull-on-demand"]
        .into_iter()
        .collect();
    const SHADOW_FIELDS: [&str; 3] = [
        "override_reason",
        "override_consequences",
        "override_fallback",
    ];

    let image_packages = discover_image_packages(&flake_path, &containerfile_path);

    let mut errors: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();
    let mut notes: Vec<String> = Vec::new();
    let mut checked = 0usize;
    let mut by_bundled = 0usize;
    let mut by_distro = 0usize;
    let mut by_pod = 0usize;
    let mut by_unset = 0usize;

    // Equivalent of sorted(cheatsheets_dir.rglob("*.md")), sorted by full path string.
    let mut md_files: Vec<PathBuf> = Vec::new();
    collect_md(&cheatsheets_dir, &mut md_files);
    md_files.sort_by(|a, b| a.to_string_lossy().cmp(&b.to_string_lossy()));

    let parent = cheatsheets_dir.parent().unwrap_or(&cheatsheets_dir);

    for path in &md_files {
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if name == "INDEX.md" || name == "TEMPLATE.md" {
            continue;
        }
        let rel = path
            .strip_prefix(parent)
            .unwrap_or(path)
            .to_string_lossy()
            .to_string();
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) => {
                warnings.push(format!("{rel}: read failed: {e}"));
                continue;
            }
        };
        let (fm, body) = match parse_frontmatter(&text) {
            Some(v) => v,
            None => {
                warnings.push(format!("{rel}: no YAML frontmatter"));
                continue;
            }
        };
        checked += 1;

        let tier = field(&fm, "tier");
        if tier.is_empty() {
            by_unset += 1;
            warnings.push(format!(
                "{rel}: tier not set — will be inferred from license-allowlist.toml (safe default: pull-on-demand)"
            ));
        } else if !allowed_tiers.contains(tier.as_str()) {
            errors.push(format!(
                "{rel}: invalid tier '{tier}' (must be one of ['bundled', 'distro-packaged', 'pull-on-demand'])"
            ));
            continue;
        } else {
            match tier.as_str() {
                "bundled" => by_bundled += 1,
                "distro-packaged" => by_distro += 1,
                "pull-on-demand" => by_pod += 1,
                _ => {}
            }
        }

        // Tier-conditional checks
        if tier == "distro-packaged" {
            let pkg = field(&fm, "package");
            if pkg.is_empty() {
                errors.push(format!(
                    "{rel}: tier=distro-packaged requires 'package:' field"
                ));
            } else if !image_packages.is_empty() && !image_packages.contains(&pkg) {
                warnings.push(format!(
                    "{rel}: tier=distro-packaged references package '{pkg}' not found in flake.nix/Containerfile (might be a name-mapping discrepancy; verify the package is actually installed)"
                ));
            }
            if field(&fm, "local").is_empty() {
                errors.push(format!(
                    "{rel}: tier=distro-packaged requires 'local:' field"
                ));
            }
        } else if tier == "pull-on-demand" {
            let recipe = field(&fm, "pull_recipe");
            if recipe != "see-section-pull-on-demand" {
                errors.push(format!(
                    "{rel}: tier=pull-on-demand requires 'pull_recipe: see-section-pull-on-demand' (got '{recipe}')"
                ));
            }
            check_pull_on_demand_section(&rel, &body, &mut errors);
        } else if tier == "bundled" && field(&fm, "image_baked_sha256").is_empty() {
            notes.push(format!(
                "{rel}: tier=bundled has no image_baked_sha256 yet (set at forge build)"
            ));
        }

        // CRDT override discipline
        if !field(&fm, "shadows_forge_default").is_empty() {
            for f in SHADOW_FIELDS {
                if field(&fm, f).is_empty() {
                    errors.push(format!(
                        "{rel}: shadows_forge_default set but '{f}' is missing or empty"
                    ));
                }
            }
        }
    }

    // Report
    if !quiet {
        println!("check-cheatsheet-tiers: {checked} cheatsheets validated");
        println!(
            "  by tier: bundled={by_bundled}, distro-packaged={by_distro}, pull-on-demand={by_pod}, unset={by_unset}"
        );
        if !warnings.is_empty() {
            println!("\nWarnings ({}):", warnings.len());
            for w in &warnings {
                println!("  WARN: {w}");
            }
        }
        if !notes.is_empty() {
            if show_notes {
                println!("\nNotes ({}):", notes.len());
                for n in &notes {
                    println!("  NOTE: {n}");
                }
            } else {
                println!(
                    "\nNotes: {} suppressed (set SHOW_NOTES=1 to list)",
                    notes.len()
                );
            }
        }
    }

    if !errors.is_empty() {
        println!("\nErrors ({}):", errors.len());
        for e in &errors {
            println!("  ERROR: {e}");
        }
        return ExitCode::from(1);
    }

    if strict && !warnings.is_empty() {
        println!(
            "\nStrict mode: {} warning(s) treated as errors.",
            warnings.len()
        );
        return ExitCode::from(1);
    }

    if !quiet {
        println!("OK: all tier checks passed.");
    }
    ExitCode::SUCCESS
}

fn field(fm: &HashMap<String, String>, key: &str) -> String {
    fm.get(key)
        .map(|v| v.trim().to_string())
        .unwrap_or_default()
}

fn collect_md(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.is_dir() {
            collect_md(&p, out);
        } else if p.extension().and_then(|s| s.to_str()) == Some("md") {
            out.push(p);
        }
    }
}

/// Faithful port of the former Python `parse_frontmatter`.
/// Returns (fields, body) or None if there is no leading `---` frontmatter.
fn parse_frontmatter(text: &str) -> Option<(HashMap<String, String>, String)> {
    if !text.starts_with("---\n") {
        return None;
    }
    // text.find("\n---\n", 4)
    let end = text[4..].find("\n---\n").map(|i| i + 4)?;
    let block = &text[4..end];
    let body = text[end + 5..].to_string();

    let mut fm: HashMap<String, String> = HashMap::new();
    let mut current_key: Option<String> = None;
    let mut current_multiline: Vec<String> = Vec::new();

    for line in block.split('\n') {
        // skip blank or comment lines (lstrip().startswith("#"))
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        // multi-line continuation (block scalar |)
        if current_key.is_some() && (line.starts_with("  ") || line.starts_with('\t')) {
            current_multiline.push(line.trim().to_string());
            continue;
        }
        // flush previous multi-line
        if current_key.is_some() && !current_multiline.is_empty() {
            fm.insert(current_key.clone().unwrap(), current_multiline.join("\n"));
            current_multiline.clear();
        }
        current_key = None;

        let (k, v) = match match_kv(line) {
            Some(kv) => kv,
            None => continue,
        };
        if v == "|" {
            current_key = Some(k);
            continue;
        }
        fm.insert(k, v);
    }
    if let Some(k) = &current_key
        && !current_multiline.is_empty()
    {
        fm.insert(k.clone(), current_multiline.join("\n"));
    }
    Some((fm, body))
}

/// Match `^([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*)$`, returning (key, value.strip()).
fn match_kv(line: &str) -> Option<(String, String)> {
    let bytes = line.as_bytes();
    let mut i = 0;
    if i >= bytes.len() {
        return None;
    }
    let c0 = bytes[i];
    if !(c0.is_ascii_alphabetic() || c0 == b'_') {
        return None;
    }
    i += 1;
    while i < bytes.len() {
        let c = bytes[i];
        if c.is_ascii_alphanumeric() || c == b'_' {
            i += 1;
        } else {
            break;
        }
    }
    let key = &line[..i];
    // \s*
    while i < bytes.len() && is_py_space(bytes[i]) {
        i += 1;
    }
    if i >= bytes.len() || bytes[i] != b':' {
        return None;
    }
    i += 1; // consume ':'
    while i < bytes.len() && is_py_space(bytes[i]) {
        i += 1;
    }
    let value = line[i..].trim().to_string();
    Some((key.to_string(), value))
}

fn is_py_space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\r' | 0x0c | 0x0b)
}

fn check_pull_on_demand_section(rel: &str, body: &str, errors: &mut Vec<String>) {
    if !body.contains("## Pull on Demand") {
        errors.push(format!(
            "{rel}: tier=pull-on-demand but missing ## Pull on Demand section"
        ));
        return;
    }
    let idx = body.find("## Pull on Demand").unwrap();
    let pod = &body[idx..];
    if !pod.contains("### Source") {
        errors.push(format!(
            "{rel}: pull-on-demand stub missing ### Source sub-heading"
        ));
    }
    if !pod.contains("### Materialize recipe") {
        errors.push(format!(
            "{rel}: pull-on-demand stub missing ### Materialize recipe sub-heading"
        ));
    }
    if !pod.contains("### Generation guidelines") {
        errors.push(format!(
            "{rel}: pull-on-demand stub missing ### Generation guidelines sub-heading"
        ));
    }
    let has_license = pod.contains("License:") || pod.contains("license:");
    let has_url = pod.contains("https://");
    if !(has_license && has_url) {
        errors.push(format!(
            "{rel}: pull-on-demand stub must declare license + license URL in ## Pull on Demand"
        ));
    }
    if !pod.contains("```bash") && !pod.contains("```sh") {
        errors.push(format!(
            "{rel}: pull-on-demand recipe must include a fenced bash/sh code block"
        ));
    }
}

/// Port of `discover_image_packages`: union of identifier tokens from
/// flake.nix `contents = with pkgs; [ ... ]` blocks and Containerfile dnf lines.
fn discover_image_packages(flake_path: &Path, containerfile_path: &Path) -> BTreeSet<String> {
    let mut pkgs: BTreeSet<String> = BTreeSet::new();
    if let Ok(text) = std::fs::read_to_string(flake_path) {
        let mut in_block = false;
        for line in text.split('\n') {
            let stripped = line.trim();
            if stripped.contains("contents = with pkgs;") {
                in_block = true;
                continue;
            }
            if in_block {
                if stripped.starts_with("];") || stripped == "]" {
                    in_block = false;
                    continue;
                }
                // Strip trailing comment, then trailing ';'
                let ident = stripped.split('#').next().unwrap_or("").trim();
                let ident = ident.trim_end_matches(';');
                if let Some(tok) = leading_ident(ident) {
                    pkgs.insert(tok);
                }
            }
        }
    }
    if let Ok(text) = std::fs::read_to_string(containerfile_path) {
        let skip: BTreeSet<&str> = ["dnf", "install", "y", "yes", "noconfirm", "run"]
            .into_iter()
            .collect();
        for line in text.split('\n') {
            let ls = line.to_lowercase();
            let ls = ls.trim();
            if ls.contains("dnf") && (ls.contains("install") || ls.contains("in ")) {
                for t in findall_tokens(line) {
                    if !skip.contains(t.to_lowercase().as_str()) {
                        pkgs.insert(t);
                    }
                }
            }
        }
    }
    pkgs
}

/// Match `^([A-Za-z_][A-Za-z0-9_-]*)` at the start of `s`.
fn leading_ident(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    if bytes.is_empty() {
        return None;
    }
    let c0 = bytes[0];
    if !(c0.is_ascii_alphabetic() || c0 == b'_') {
        return None;
    }
    let mut i = 1;
    while i < bytes.len() {
        let c = bytes[i];
        if c.is_ascii_alphanumeric() || c == b'_' || c == b'-' {
            i += 1;
        } else {
            break;
        }
    }
    Some(s[..i].to_string())
}

/// Port of re.findall(r"[a-zA-Z][a-zA-Z0-9_-]*", line).
fn findall_tokens(line: &str) -> Vec<String> {
    let bytes = line.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_alphabetic() {
            let start = i;
            i += 1;
            while i < bytes.len() {
                let c = bytes[i];
                if c.is_ascii_alphanumeric() || c == b'_' || c == b'-' {
                    i += 1;
                } else {
                    break;
                }
            }
            out.push(line[start..i].to_string());
        } else {
            i += 1;
        }
    }
    out
}
