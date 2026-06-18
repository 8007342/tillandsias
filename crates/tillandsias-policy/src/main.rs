use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("check-cheatsheet-tiers") => check_cheatsheet_tiers(&args[2..]),
        Some("check-no-python-scripts") => check_no_python_scripts(),
        Some("validate-yaml") => validate_yaml(&args[2..]),
        Some("--help") | Some("-h") | None => usage(),
        Some(other) => {
            eprintln!("unknown command: {other}");
            usage();
            process::exit(2);
        }
    }
}

fn usage() {
    eprintln!("Usage:");
    eprintln!(
        "  tillandsias-policy check-cheatsheet-tiers [--repo-root <path>] [--quiet] [--strict]"
    );
    eprintln!("  tillandsias-policy check-no-python-scripts");
    eprintln!("  tillandsias-policy validate-yaml <file>...");
}

// @trace spec:cheatsheets-license-tiered
fn check_cheatsheet_tiers(args: &[String]) {
    let mut quiet = false;
    let mut strict = false;
    let mut repo_root = env::current_dir().unwrap_or_else(|err| {
        eprintln!("failed to read current dir: {err}");
        process::exit(2);
    });

    let mut idx = 0;
    while idx < args.len() {
        match args[idx].as_str() {
            "--quiet" => quiet = true,
            "--strict" => strict = true,
            "--repo-root" => {
                idx += 1;
                let Some(value) = args.get(idx) else {
                    eprintln!("--repo-root requires a path");
                    process::exit(2);
                };
                repo_root = PathBuf::from(value);
            }
            other => {
                eprintln!(
                    "usage: check-cheatsheet-tiers [--repo-root <path>] [--quiet] [--strict]"
                );
                eprintln!("unexpected argument: {other}");
                process::exit(2);
            }
        }
        idx += 1;
    }

    let cheatsheets_dir = repo_root.join("cheatsheets");
    if !cheatsheets_dir.is_dir() {
        eprintln!(
            "ERROR: cheatsheets/ directory not found at {}",
            cheatsheets_dir.display()
        );
        process::exit(1);
    }

    let image_packages = discover_image_packages(
        &repo_root.join("flake.nix"),
        &repo_root.join("images/default/Containerfile"),
    );
    let mut report = CheatsheetTierReport::default();
    let mut files = Vec::new();
    collect_markdown_files(&cheatsheets_dir, &mut files);
    files.sort();

    for path in files {
        let file_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("");
        if matches!(file_name, "INDEX.md" | "TEMPLATE.md") {
            continue;
        }
        inspect_cheatsheet_tier(&repo_root, &image_packages, &path, &mut report);
    }

    if !quiet {
        println!(
            "check-cheatsheet-tiers: {} cheatsheets validated",
            report.checked
        );
        println!(
            "  by tier: bundled={}, distro-packaged={}, pull-on-demand={}, unset={}",
            report.bundled, report.distro_packaged, report.pull_on_demand, report.unset
        );
        if !report.warnings.is_empty() {
            println!("\nWarnings ({}):", report.warnings.len());
            for warning in &report.warnings {
                println!("  WARN: {warning}");
            }
        }
        if !report.notes.is_empty() {
            if env::var("SHOW_NOTES").ok().as_deref() == Some("1") {
                println!("\nNotes ({}):", report.notes.len());
                for note in &report.notes {
                    println!("  NOTE: {note}");
                }
            } else {
                println!(
                    "\nNotes: {} suppressed (set SHOW_NOTES=1 to list)",
                    report.notes.len()
                );
            }
        }
    }

    if !report.errors.is_empty() {
        println!("\nErrors ({}):", report.errors.len());
        for error in &report.errors {
            println!("  ERROR: {error}");
        }
        process::exit(1);
    }

    if strict && !report.warnings.is_empty() {
        println!(
            "\nStrict mode: {} warning(s) treated as errors.",
            report.warnings.len()
        );
        process::exit(1);
    }

    if !quiet {
        println!("OK: all tier checks passed.");
    }
}

#[derive(Default)]
struct CheatsheetTierReport {
    checked: usize,
    bundled: usize,
    distro_packaged: usize,
    pull_on_demand: usize,
    unset: usize,
    errors: Vec<String>,
    warnings: Vec<String>,
    notes: Vec<String>,
}

// @trace spec:cheatsheets-license-tiered
fn discover_image_packages(flake_path: &Path, containerfile_path: &Path) -> Vec<String> {
    let mut packages = Vec::new();
    if let Ok(text) = fs::read_to_string(flake_path) {
        let mut in_block = false;
        for line in text.lines() {
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
                let ident = stripped
                    .split('#')
                    .next()
                    .unwrap_or("")
                    .trim()
                    .trim_end_matches(';');
                if let Some(token) = leading_identifier(ident) {
                    push_unique(&mut packages, token);
                }
            }
        }
    }
    if let Ok(text) = fs::read_to_string(containerfile_path) {
        for line in text.lines() {
            let lower = line.to_ascii_lowercase();
            if lower.contains("dnf") && (lower.contains("install") || lower.contains(" in ")) {
                for token in identifier_tokens(line) {
                    let token_lower = token.to_ascii_lowercase();
                    if !matches!(
                        token_lower.as_str(),
                        "dnf" | "install" | "y" | "yes" | "noconfirm" | "run"
                    ) {
                        push_unique(&mut packages, token);
                    }
                }
            }
        }
    }
    packages
}

fn collect_markdown_files(dir: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_markdown_files(&path, files);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("md") {
            files.push(path);
        }
    }
}

fn inspect_cheatsheet_tier(
    repo_root: &Path,
    image_packages: &[String],
    path: &Path,
    report: &mut CheatsheetTierReport,
) {
    let rel_path = path.strip_prefix(repo_root).unwrap_or(path);
    let rel = rel_path.display().to_string();
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(err) => {
            report.warnings.push(format!("{rel}: read failed: {err}"));
            return;
        }
    };
    let Some((frontmatter, body)) = parse_frontmatter(&text) else {
        report.warnings.push(format!("{rel}: no YAML frontmatter"));
        return;
    };
    report.checked += 1;

    let tier = frontmatter_value(&frontmatter, "tier").trim().to_string();
    match tier.as_str() {
        "" => {
            report.unset += 1;
            report.warnings.push(format!(
                "{rel}: tier not set - will be inferred from license-allowlist.toml (safe default: pull-on-demand)"
            ));
        }
        "bundled" => report.bundled += 1,
        "distro-packaged" => report.distro_packaged += 1,
        "pull-on-demand" => report.pull_on_demand += 1,
        other => {
            report.errors.push(format!(
                "{rel}: invalid tier '{other}' (must be one of ['bundled', 'distro-packaged', 'pull-on-demand'])"
            ));
            return;
        }
    }

    match tier.as_str() {
        "distro-packaged" => {
            let package = frontmatter_value(&frontmatter, "package")
                .trim()
                .to_string();
            if package.is_empty() {
                report.errors.push(format!(
                    "{rel}: tier=distro-packaged requires 'package:' field"
                ));
            } else if !image_packages.is_empty()
                && !image_packages.iter().any(|pkg| pkg == &package)
            {
                report.warnings.push(format!(
                    "{rel}: tier=distro-packaged references package '{package}' not found in flake.nix/Containerfile (might be a name-mapping discrepancy; verify the package is actually installed)"
                ));
            }
            if frontmatter_value(&frontmatter, "local").trim().is_empty() {
                report.errors.push(format!(
                    "{rel}: tier=distro-packaged requires 'local:' field"
                ));
            }
        }
        "pull-on-demand" => {
            let recipe = frontmatter_value(&frontmatter, "pull_recipe")
                .trim()
                .to_string();
            if recipe != "see-section-pull-on-demand" {
                report.errors.push(format!(
                    "{rel}: tier=pull-on-demand requires 'pull_recipe: see-section-pull-on-demand' (got '{recipe}')"
                ));
            }
            check_pull_on_demand_section(&rel, body, report);
        }
        "bundled"
            if frontmatter_value(&frontmatter, "image_baked_sha256")
                .trim()
                .is_empty() =>
        {
            report.notes.push(format!(
                "{rel}: tier=bundled has no image_baked_sha256 yet (set at forge build)"
            ));
        }
        _ => {}
    }

    if !frontmatter_value(&frontmatter, "shadows_forge_default")
        .trim()
        .is_empty()
    {
        for field in [
            "override_reason",
            "override_consequences",
            "override_fallback",
        ] {
            if frontmatter_value(&frontmatter, field).trim().is_empty() {
                report.errors.push(format!(
                    "{rel}: shadows_forge_default set but '{field}' is missing or empty"
                ));
            }
        }
    }
}

// @trace spec:cheatsheets-license-tiered
fn check_pull_on_demand_section(rel: &str, body: &str, report: &mut CheatsheetTierReport) {
    let Some(start) = body.find("## Pull on Demand") else {
        report.errors.push(format!(
            "{rel}: tier=pull-on-demand but missing ## Pull on Demand section"
        ));
        return;
    };
    let section = &body[start..];
    if !section.contains("### Source") {
        report.errors.push(format!(
            "{rel}: pull-on-demand stub missing ### Source sub-heading"
        ));
    }
    if !section.contains("### Materialize recipe") {
        report.errors.push(format!(
            "{rel}: pull-on-demand stub missing ### Materialize recipe sub-heading"
        ));
    }
    if !section.contains("### Generation guidelines") {
        report.errors.push(format!(
            "{rel}: pull-on-demand stub missing ### Generation guidelines sub-heading"
        ));
    }
    let has_license = section.contains("License:") || section.contains("license:");
    let has_url = section.contains("https://");
    if !(has_license && has_url) {
        report.errors.push(format!(
            "{rel}: pull-on-demand stub must declare license + license URL in ## Pull on Demand"
        ));
    }
    if !(section.contains("```bash") || section.contains("```sh")) {
        report.errors.push(format!(
            "{rel}: pull-on-demand recipe must include a fenced bash/sh code block"
        ));
    }
}

// @trace spec:cheatsheets-license-tiered
fn parse_frontmatter(text: &str) -> Option<(Vec<(String, String)>, &str)> {
    if !text.starts_with("---\n") {
        return None;
    }
    let end = text[4..].find("\n---\n")? + 4;
    let block = &text[4..end];
    let body = &text[end + 5..];
    let mut fields = Vec::new();
    let mut current_key: Option<String> = None;
    let mut current_multiline = Vec::new();

    for line in block.lines() {
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        if current_key.is_some() && (line.starts_with("  ") || line.starts_with('\t')) {
            current_multiline.push(line.trim().to_string());
            continue;
        }
        if let Some(key) = current_key.take()
            && !current_multiline.is_empty()
        {
            fields.push((key, current_multiline.join("\n")));
            current_multiline.clear();
        }
        let Some((key, value)) = parse_frontmatter_line(line) else {
            continue;
        };
        if value == "|" {
            current_key = Some(key.to_string());
        } else {
            fields.push((key.to_string(), value.to_string()));
        }
    }
    if let Some(key) = current_key.take()
        && !current_multiline.is_empty()
    {
        fields.push((key, current_multiline.join("\n")));
    }
    Some((fields, body))
}

fn parse_frontmatter_line(line: &str) -> Option<(&str, &str)> {
    let (key, value) = line.split_once(':')?;
    let key = key.trim();
    if key.is_empty()
        || !key
            .chars()
            .all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
        || key
            .chars()
            .next()
            .is_some_and(|ch| !(ch == '_' || ch.is_ascii_alphabetic()))
    {
        return None;
    }
    Some((key, value.trim()))
}

fn frontmatter_value(fields: &[(String, String)], key: &str) -> String {
    fields
        .iter()
        .find_map(|(field, value)| (field == key).then(|| value.clone()))
        .unwrap_or_default()
}

fn validate_yaml(files: &[String]) {
    if files.is_empty() {
        eprintln!("validate-yaml requires at least one file");
        process::exit(2);
    }

    let mut failed = false;
    for file in files {
        match fs::read_to_string(file) {
            Ok(content) => match serde_yaml::from_str::<serde_yaml::Value>(&content) {
                Ok(_) => println!("ok: {file}"),
                Err(err) => {
                    eprintln!("{file}: {err}");
                    failed = true;
                }
            },
            Err(err) => {
                eprintln!("{file}: {err}");
                failed = true;
            }
        }
    }

    if failed {
        process::exit(1);
    }
}

fn check_no_python_scripts() {
    let root = env::current_dir().unwrap_or_else(|err| {
        eprintln!("failed to read current dir: {err}");
        process::exit(2);
    });
    let mut violations = Vec::new();
    scan_dir(&root, &root, &mut violations);
    violations.sort();

    if violations.is_empty() {
        println!("ok: no Python runtime references in scripts/harness files");
        return;
    }

    for violation in &violations {
        eprintln!("{violation}");
    }
    eprintln!(
        "python runtime is not allowed in Tillandsias scripts; rewrite in Rust or get Tlatoani approval"
    );
    process::exit(1);
}

fn scan_dir(root: &Path, dir: &Path, violations: &mut Vec<String>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if should_skip_dir(name, &path) {
            continue;
        }
        if path.is_dir() {
            scan_dir(root, &path, violations);
            continue;
        }
        if !is_script_or_harness(root, &path) {
            continue;
        }
        inspect_file(root, &path, violations);
    }
}

fn should_skip_dir(name: &str, path: &Path) -> bool {
    matches!(
        name,
        ".git" | "target" | "dist" | "node_modules" | ".cache" | ".direnv"
    ) || path.components().any(|component| {
        component.as_os_str() == "plan" && path.components().any(|c| c.as_os_str() == "archive")
    })
}

fn is_script_or_harness(root: &Path, path: &Path) -> bool {
    let rel = path.strip_prefix(root).unwrap_or(path);
    let rel_str = rel.to_string_lossy();
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("");
    let ext = path.extension().and_then(|ext| ext.to_str()).unwrap_or("");

    matches!(ext, "sh" | "bash" | "ps1" | "bat" | "py")
        || rel_str.starts_with("scripts/")
        || matches!(
            file_name,
            "codex" | "claude" | "repeat" | "observatorium.sh" | "build.sh" | "verify.sh"
        )
}

fn inspect_file(root: &Path, path: &Path, violations: &mut Vec<String>) {
    let Ok(content) = fs::read_to_string(path) else {
        return;
    };
    let rel = path.strip_prefix(root).unwrap_or(path).display();
    for (idx, line) in content.lines().enumerate() {
        if has_python_runtime_reference(line) {
            violations.push(format!("{rel}:{}: {}", idx + 1, line.trim()));
        }
    }
}

fn has_python_runtime_reference(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    if trimmed.starts_with('#') && !trimmed.starts_with("#!") {
        return false;
    }
    let lower = trimmed.to_ascii_lowercase();
    lower.contains("#!/usr/bin/env python")
        || lower.contains("#!/usr/bin/python")
        || lower.starts_with("python ")
        || lower.starts_with("python3 ")
        || lower.starts_with("python -")
        || lower.starts_with("python3 -")
        || lower.contains("$(python ")
        || lower.contains("$(python3 ")
        || lower.contains("`python ")
        || lower.contains("`python3 ")
        || lower.contains(" command -v python")
        || lower.starts_with("if command -v python")
}

fn leading_identifier(value: &str) -> Option<String> {
    let mut chars = value.chars();
    let first = chars.next()?;
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return None;
    }
    let mut token = String::from(first);
    for ch in chars {
        if ch == '_' || ch == '-' || ch.is_ascii_alphanumeric() {
            token.push(ch);
        } else {
            break;
        }
    }
    Some(token)
}

fn identifier_tokens(line: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    for ch in line.chars() {
        if ch == '_' || ch == '-' || ch.is_ascii_alphanumeric() {
            current.push(ch);
        } else if !current.is_empty() {
            tokens.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

fn push_unique(values: &mut Vec<String>, value: String) {
    if !values.iter().any(|existing| existing == &value) {
        values.push(value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_frontmatter_with_multiline_fields() {
        let text = "---\ntier: bundled\noverride_reason: |\n  keep local copy\n---\nbody";
        let (fields, body) = parse_frontmatter(text).expect("frontmatter should parse");
        assert_eq!(frontmatter_value(&fields, "tier"), "bundled");
        assert_eq!(
            frontmatter_value(&fields, "override_reason"),
            "keep local copy"
        );
        assert_eq!(body, "body");
    }

    #[test]
    fn flags_python_runtime_invocations() {
        assert!(has_python_runtime_reference("python3 - <<'PYEOF'"));
        assert!(has_python_runtime_reference(
            "value=$(python -c 'print(1)')"
        ));
        assert!(!has_python_runtime_reference("# python3 in a comment"));
    }
}
