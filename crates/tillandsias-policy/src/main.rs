use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("check-cheatsheet-tiers") => check_cheatsheet_tiers(&args[2..]),
        Some("check-cheatsheet-sources") => check_cheatsheet_sources(&args[2..]),
        Some("audit-cheatsheet-sources") => audit_cheatsheet_sources(&args[2..]),
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
    eprintln!("  tillandsias-policy check-cheatsheet-sources [--repo-root <path>] [--no-sha]");
    eprintln!("  tillandsias-policy audit-cheatsheet-sources [--repo-root <path>]");
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

    // Tombstone discipline: a retired script (`@tombstone`) exits early with a
    // notice and never executes its legacy body, which is preserved for
    // traceability through the retention window (see methodology.yaml). Stop
    // scanning at that early `exit 0` guard — the dead legacy below it cannot
    // run, so Python references there are not runtime references.
    let is_tombstone = content.contains("@tombstone");

    for (idx, line) in content.lines().enumerate() {
        if is_tombstone && line.trim() == "exit 0" {
            break;
        }
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

// ===========================================================================
// `check-cheatsheet-sources` subcommand — faithful port of the former
// scripts/check-cheatsheet-sources.sh (via tillandsias-cheatsheet-tools sources).
//
// Validates cheatsheet <-> verbatim-source binding per §5 of
// docs/strategy/cheatsheet-source-layer-plan.md:
//   1. Every cheatsheet ## Provenance URL must be in INDEX.json (WARNING when
//      unfetched — not yet blocking).
//   2. Every local: path must exist OR have a sidecar with redistribution
//      do-not-bundle / manual-review-required (ERROR otherwise).
//   3. Orphan detection: every INDEX entry should be cited (WARNING).
//   4. SHA-256 verification of present files (skippable with --no-sha).
//
// Exit 0 only if all ERROR-level checks pass; warnings never fail.
//
// @trace spec:cheatsheet-source-layer
// ===========================================================================

fn check_cheatsheet_sources(args: &[String]) {
    let mut no_sha = false;
    let mut repo_root = env::current_dir().unwrap_or_else(|err| {
        eprintln!("failed to read current dir: {err}");
        process::exit(2);
    });

    let mut idx = 0;
    while idx < args.len() {
        match args[idx].as_str() {
            "--no-sha" => no_sha = true,
            "--repo-root" => {
                idx += 1;
                let Some(value) = args.get(idx) else {
                    eprintln!("--repo-root requires a path");
                    process::exit(2);
                };
                repo_root = PathBuf::from(value);
            }
            other => {
                eprintln!("error: unknown argument: {other}");
                eprintln!("usage: check-cheatsheet-sources [--repo-root <path>] [--no-sha]");
                process::exit(2);
            }
        }
        idx += 1;
    }

    let root = repo_root;
    let sources_dir = root.join("cheatsheet-sources");
    let cheatsheets_dir = root.join("cheatsheets");
    let index_file = sources_dir.join("INDEX.json");

    // Sanity: INDEX.json must exist. Mirrors the shell early-exit (exit 0).
    if !index_file.is_file() {
        println!(
            "warning: {} does not exist — no sources fetched yet; nothing to validate",
            index_file.display()
        );
        println!("  Run: scripts/fetch-cheatsheet-source.sh <URL> --cite cheatsheets/<path>");
        return;
    }

    let index_text = match fs::read_to_string(&index_file) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("ERROR: cannot read {}: {e}", index_file.display());
            process::exit(1);
        }
    };
    let index: serde_json::Value = match serde_json::from_str(&index_text) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("ERROR: {} is not valid JSON: {e}", index_file.display());
            process::exit(1);
        }
    };
    let entries: Vec<&serde_json::Value> = index
        .get("entries")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().collect())
        .unwrap_or_default();

    // url_set: union of url/fetch_url/final_redirect values.
    let mut url_set: BTreeSet<String> = BTreeSet::new();
    for entry in &entries {
        for key in ["url", "fetch_url", "final_redirect"] {
            if let Some(u) = entry.get(key).and_then(|v| v.as_str())
                && !u.is_empty()
            {
                url_set.insert(u.to_string());
            }
        }
    }

    let mut errors: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();

    // Collect cheatsheet files (sorted by path string), excluding INDEX/TEMPLATE.
    let mut md_files: Vec<PathBuf> = Vec::new();
    collect_markdown_files(&cheatsheets_dir, &mut md_files);
    md_files.sort_by(|a, b| a.to_string_lossy().cmp(&b.to_string_lossy()));
    md_files.retain(|p| {
        let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
        name != "INDEX.md" && name != "TEMPLATE.md"
    });

    let mut cited_local_paths: BTreeSet<String> = BTreeSet::new();
    let mut checked_urls = 0usize;
    let mut checked_local = 0usize;

    // Checks 1 & 2.
    for cs_file in &md_files {
        let rel_cs = cs_file
            .strip_prefix(&root)
            .unwrap_or(cs_file)
            .to_string_lossy()
            .to_string();
        let text = match fs::read_to_string(cs_file) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let (urls, local_paths) = extract_provenance(&text);

        for url in &urls {
            checked_urls += 1;
            if !url_set.contains(url) {
                warnings.push(format!("UNFETCHED: {rel_cs}: URL not in INDEX.json: {url}"));
            }
        }

        for local_path in &local_paths {
            checked_local += 1;
            cited_local_paths.insert(local_path.clone());
            let abs_path = root.join(local_path);
            let meta_path = root.join(format!("{local_path}.meta.yaml"));

            if abs_path.is_file() {
                // File exists — good.
            } else if meta_path.is_file() {
                let redist = read_redistribution(&meta_path);
                if redist == "do-not-bundle" || redist == "manual-review-required" {
                    // Expected; sidecar-only is OK.
                } else {
                    errors.push(format!(
                        "MISSING FILE: {rel_cs}: local: path has sidecar but no verbatim file and redistribution is '{redist}': {local_path}"
                    ));
                }
            } else {
                errors.push(format!(
                    "MISSING: {rel_cs}: local: path does not exist (no file, no sidecar): {local_path}"
                ));
            }
        }
    }

    // Check 3: orphan detection.
    for entry in &entries {
        let lp = entry
            .get("local_path")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if lp.is_empty() {
            continue;
        }
        let cited_by = entry
            .get("cited_by")
            .and_then(|v| v.as_array())
            .map(|a| !a.is_empty())
            .unwrap_or(false);
        if !cited_local_paths.contains(lp) && !cited_by {
            warnings.push(format!(
                "ORPHAN: {lp} is in INDEX.json but not cited by any cheatsheet"
            ));
        }
    }

    // Check 4: SHA-256 verification.
    let mut sha_ok = 0usize;
    if !no_sha {
        use sha2::{Digest, Sha256};
        for entry in &entries {
            let lp = entry
                .get("local_path")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let expected_sha = entry
                .get("content_sha256")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if lp.is_empty() || expected_sha.is_empty() {
                continue;
            }
            let abs_path = root.join(lp);
            let bytes = match fs::read(&abs_path) {
                Ok(b) => b,
                Err(_) => continue, // File absent (do-not-bundle / not fetched) — skip.
            };
            let actual_sha = format!("{:x}", Sha256::digest(&bytes));
            if actual_sha != expected_sha {
                errors.push(format!(
                    "SHA MISMATCH: {lp}: expected {}... got {}... (content modified after fetch)",
                    &expected_sha[..expected_sha.len().min(16)],
                    &actual_sha[..actual_sha.len().min(16)]
                ));
            } else {
                sha_ok += 1;
            }
        }
    }

    // Report.
    let sha_note = if no_sha {
        " (SHA check skipped)".to_string()
    } else {
        format!(", {sha_ok} SHA verifications")
    };
    println!(
        "check-cheatsheet-sources: {} cheatsheets, {} INDEX entries, {checked_urls} provenance URLs, {checked_local} local: paths checked{sha_note}",
        md_files.len(),
        entries.len()
    );

    if !warnings.is_empty() {
        println!("\nWarnings ({}):", warnings.len());
        for w in &warnings {
            println!("  WARNING: {w}");
        }
    }

    if !errors.is_empty() {
        println!("\nErrors ({}):", errors.len());
        for e in &errors {
            println!("  ERROR: {e}");
        }
        process::exit(1);
    }

    println!("OK: all checks passed.");
}

/// Read `redistribution:` field from a sidecar meta.yaml (first match wins).
fn read_redistribution(meta_path: &Path) -> String {
    let text = match fs::read_to_string(meta_path) {
        Ok(t) => t,
        Err(_) => return String::new(),
    };
    for line in text.lines() {
        let line = line.trim_end();
        if let Some(rest) = line.strip_prefix("redistribution:") {
            // Mirror Python's `^redistribution:\s*(\S+)` — first whitespace-delimited token.
            return rest.split_whitespace().next().unwrap_or("").to_string();
        }
    }
    String::new()
}

/// Faithful port of the former Python `extract_provenance`.
/// Returns (urls, local_paths) parsed from the cheatsheet's ## Provenance section.
fn extract_provenance(text: &str) -> (Vec<String>, Vec<String>) {
    let mut urls: Vec<String> = Vec::new();
    let mut local_paths: Vec<String> = Vec::new();
    let mut in_provenance = false;

    for line in text.lines() {
        let stripped = line.trim();
        if is_provenance_heading(stripped) {
            in_provenance = true;
            continue;
        }
        if in_provenance && is_h2_heading(stripped) {
            in_provenance = false;
            continue;
        }
        if !in_provenance {
            continue;
        }

        // Angle-bracketed URLs: <https://...>
        extract_angle_urls(stripped, &mut urls);
        // Bare URLs not in angle brackets / backticks.
        extract_bare_urls(stripped, &mut urls);
        // local: `path`
        if let Some(lp) = extract_local_path(stripped) {
            local_paths.push(lp);
        }
    }

    (urls, local_paths)
}

/// Match `^##\s+Provenance` after stripping.
fn is_provenance_heading(stripped: &str) -> bool {
    if let Some(rest) = stripped.strip_prefix("##") {
        let rest = rest.trim_start();
        // require at least one whitespace after ## (\s+), then "Provenance"
        rest.starts_with("Provenance")
            && stripped
                .as_bytes()
                .get(2)
                .is_some_and(|b| b.is_ascii_whitespace())
    } else {
        false
    }
}

/// Match `^##\s+` after stripping.
fn is_h2_heading(stripped: &str) -> bool {
    stripped.starts_with("##")
        && stripped
            .as_bytes()
            .get(2)
            .is_some_and(|b| b.is_ascii_whitespace())
}

/// Port of `re.finditer(r'<(https://[^>]+)>', line)`.
fn extract_angle_urls(line: &str, urls: &mut Vec<String>) {
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'<' {
            let rest = &line[i + 1..];
            if rest.starts_with("https://")
                && let Some(close) = rest.find('>')
            {
                let u = &rest[..close];
                if !u.is_empty() {
                    urls.push(u.to_string());
                }
                i += 1 + close + 1;
                continue;
            }
        }
        i += 1;
    }
}

/// Port of `re.finditer(r'(?<![<`])(https://\S+?)(?:[,\s>)]|$)', line)` with
/// the subsequent `.rstrip('.,)')` and dedup against existing urls.
fn extract_bare_urls(line: &str, urls: &mut Vec<String>) {
    let bytes = line.as_bytes();
    let mut search = 0;
    while let Some(rel) = line[search..].find("https://") {
        let start = search + rel;
        // Negative lookbehind: previous char must not be '<' or '`'.
        let prev_ok = start == 0 || !matches!(bytes[start - 1], b'<' | b'`');
        if !prev_ok {
            search = start + "https://".len();
            continue;
        }
        // Python pattern is `https://\S+?` (non-greedy, ≥1 char after the
        // scheme) terminated by `[,\s>)]|$`, with a trailing `.rstrip('.,)')`.
        // The `\S+?` body must consume at least one NON-whitespace character;
        // if the char right after the scheme is whitespace (or EOL), there is
        // no match at all (e.g. `git+https:// VCS` yields nothing). When that
        // mandatory char is itself a `,`/`)`/`.`, `\S+?` consumes it and the
        // rstrip later removes it — Python emits a bare `https://` there.
        let scheme_end = start + "https://".len();
        if scheme_end >= bytes.len() || bytes[scheme_end].is_ascii_whitespace() {
            search = scheme_end.max(start + 1);
            continue;
        }
        // Consume the mandatory first char, then \S+ up to the first
        // terminator (`,`, `>`, `)`) or whitespace.
        let mut end = scheme_end + 1;
        while end < bytes.len() && !bytes[end].is_ascii_whitespace() {
            if matches!(bytes[end], b',' | b'>' | b')') {
                break;
            }
            end += 1;
        }
        let mut u = line[start..end].to_string();
        // .rstrip('.,)')
        while u.ends_with('.') || u.ends_with(',') || u.ends_with(')') {
            u.pop();
        }
        if !u.is_empty() && !urls.contains(&u) {
            urls.push(u);
        }
        search = end.max(start + 1);
    }
}

/// Port of `re.search(r'local:\s*`([^`]+)`', line)`.
fn extract_local_path(line: &str) -> Option<String> {
    let idx = line.find("local:")?;
    let after = &line[idx + "local:".len()..];
    let after = after.trim_start();
    let after = after.strip_prefix('`')?;
    let close = after.find('`')?;
    let path = &after[..close];
    if path.is_empty() {
        None
    } else {
        Some(path.to_string())
    }
}

// ===========================================================================
// `audit-cheatsheet-sources` subcommand — faithful port of the former
// scripts/audit-cheatsheet-sources.sh (via tillandsias-cheatsheet-tools audit).
//
// Emits a CSV (Python csv.writer dialect: CRLF line terminators, minimal
// quoting) with one row per cheatsheet Provenance URL:
//   cheatsheet_path, source_url, in_index_json, license_allowlisted,
//   allowlist_key, sha256_present, local_path_if_fetched
// Cheatsheets with no Provenance URLs emit a single "(no provenance URLs)" row.
// Exit code is always 0; errors are encoded as cell values.
//
// @trace spec:cheatsheet-source-layer
// ===========================================================================

fn audit_cheatsheet_sources(args: &[String]) {
    let mut repo_root = env::current_dir().unwrap_or_else(|err| {
        eprintln!("failed to read current dir: {err}");
        process::exit(2);
    });

    let mut idx = 0;
    while idx < args.len() {
        match args[idx].as_str() {
            "--repo-root" => {
                idx += 1;
                let Some(value) = args.get(idx) else {
                    eprintln!("--repo-root requires a path");
                    process::exit(2);
                };
                repo_root = PathBuf::from(value);
            }
            other => {
                eprintln!("error: unknown argument: {other}");
                eprintln!("usage: audit-cheatsheet-sources [--repo-root <path>]");
                process::exit(2);
            }
        }
        idx += 1;
    }

    let root = repo_root;
    let sources_dir = root.join("cheatsheet-sources");
    let cheatsheets_dir = root.join("cheatsheets");
    let allowlist_path = sources_dir.join("license-allowlist.toml");
    let index_file = sources_dir.join("INDEX.json");

    // --- Load INDEX.json into url -> entry map. ---
    // Mirror Python: build url_to_entry from url/fetch_url/final_redirect keys.
    let mut url_to_entry: std::collections::HashMap<String, serde_json::Value> =
        std::collections::HashMap::new();
    if index_file.is_file()
        && let Ok(text) = fs::read_to_string(&index_file)
        && let Ok(index) = serde_json::from_str::<serde_json::Value>(&text)
        && let Some(entries) = index.get("entries").and_then(|v| v.as_array())
    {
        for entry in entries {
            for key in ["url", "fetch_url", "final_redirect"] {
                if let Some(u) = entry.get(key).and_then(|v| v.as_str())
                    && !u.is_empty()
                {
                    url_to_entry.insert(u.to_string(), entry.clone());
                }
            }
        }
    }

    // --- Load allowlist domain keys. ---
    let allowlisted_domains = load_allowlist_domains(&allowlist_path);

    // --- Walk cheatsheets (sorted by path string), excluding INDEX/TEMPLATE. ---
    let mut md_files: Vec<PathBuf> = Vec::new();
    collect_markdown_files(&cheatsheets_dir, &mut md_files);
    md_files.sort_by(|a, b| a.to_string_lossy().cmp(&b.to_string_lossy()));
    md_files.retain(|p| {
        let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
        name != "INDEX.md" && name != "TEMPLATE.md"
    });

    let mut out = String::new();
    write_csv_row(
        &mut out,
        &[
            "cheatsheet_path",
            "source_url",
            "in_index_json",
            "license_allowlisted",
            "allowlist_key",
            "sha256_present",
            "local_path_if_fetched",
        ],
    );

    for cs_file in &md_files {
        let rel_cs = cs_file
            .strip_prefix(&root)
            .unwrap_or(cs_file)
            .to_string_lossy()
            .to_string();
        let text = match fs::read_to_string(cs_file) {
            Ok(t) => t,
            Err(_) => continue, // open() would raise in Python; glob hits are readable.
        };
        let urls = extract_provenance_urls_audit(&text);

        if urls.is_empty() {
            write_csv_row(
                &mut out,
                &[&rel_cs, "(no provenance URLs)", "N/A", "N/A", "", "N/A", ""],
            );
            continue;
        }

        for url in &urls {
            let in_index = url_to_entry.contains_key(url);
            let allowlist_key = is_allowlisted(url, &allowlisted_domains);
            let allowlisted = !allowlist_key.is_empty();

            let mut local_path = String::new();
            let mut sha_present = false;
            if in_index {
                let entry = &url_to_entry[url];
                local_path = entry
                    .get("local_path")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                sha_present = entry
                    .get("content_sha256")
                    .and_then(|v| v.as_str())
                    .map(|s| !s.is_empty())
                    .unwrap_or(false);
            }

            write_csv_row(
                &mut out,
                &[
                    &rel_cs,
                    url,
                    if in_index { "yes" } else { "no" },
                    if allowlisted { "yes" } else { "no" },
                    &allowlist_key,
                    if sha_present { "yes" } else { "no" },
                    &local_path,
                ],
            );
        }
    }

    print!("{out}");
}

/// Parse allowlist `[domains."<key>"]` headers into a set of keys.
/// Mirrors Python `re.match(r'\[domains\."([^"]+)"\]', line.strip())`.
fn load_allowlist_domains(allowlist_path: &Path) -> BTreeSet<String> {
    let mut domains: BTreeSet<String> = BTreeSet::new();
    let Ok(text) = fs::read_to_string(allowlist_path) else {
        return domains;
    };
    for line in text.lines() {
        let stripped = line.trim();
        if let Some(key) = parse_domains_header(stripped) {
            domains.insert(key);
        }
    }
    domains
}

/// Match `^\[domains\."([^"]+)"\]` (anchored, since Python uses re.match).
fn parse_domains_header(stripped: &str) -> Option<String> {
    let rest = stripped.strip_prefix("[domains.\"")?;
    let close = rest.find('"')?;
    let key = &rest[..close];
    if key.is_empty() {
        return None;
    }
    // Remainder after the closing quote must start with `]`.
    let after = &rest[close + 1..];
    if after.starts_with(']') {
        Some(key.to_string())
    } else {
        None
    }
}

/// Faithful port of the audit script's `is_allowlisted`.
/// Returns the matching allowlist key, or "" if none.
fn is_allowlisted(url: &str, allowlisted_domains: &BTreeSet<String>) -> String {
    let u = if let Some(rest) = url.strip_prefix("https://") {
        rest
    } else if let Some(rest) = url.strip_prefix("http://") {
        rest
    } else {
        url
    };
    let host = u.split('/').next().unwrap_or("");
    // path_parts = u[len(host):].lstrip('/').split('/')
    let after_host = &u[host.len()..];
    let trimmed = after_host.trim_start_matches('/');
    let path_parts: Vec<&str> = trimmed.split('/').collect();

    // for depth in range(min(3, len(path_parts)), -1, -1)
    let max_depth = 3.min(path_parts.len());
    for depth in (0..=max_depth).rev() {
        let candidate = if depth > 0 {
            format!("{host}/{}", path_parts[..depth].join("/"))
        } else {
            host.to_string()
        };
        if allowlisted_domains.contains(&candidate) {
            return candidate;
        }
    }
    String::new()
}

/// Provenance-URL extractor for the audit command. Differs from
/// `extract_provenance`: it skips lines containing `**Last updated:**`,
/// does NOT collect local: paths, and dedups across the whole section.
fn extract_provenance_urls_audit(text: &str) -> Vec<String> {
    let mut urls: Vec<String> = Vec::new();
    let mut in_provenance = false;
    for line in text.lines() {
        let stripped = line.trim();
        if is_provenance_heading(stripped) {
            in_provenance = true;
            continue;
        }
        if in_provenance && is_h2_heading(stripped) {
            in_provenance = false;
            continue;
        }
        if !in_provenance {
            continue;
        }
        if stripped.contains("**Last updated:**") {
            continue;
        }
        extract_angle_urls(stripped, &mut urls);
        extract_bare_urls(stripped, &mut urls);
    }
    urls
}

/// Write one CSV row using Python's csv.writer default dialect:
/// minimal quoting (only when a field contains a comma, double-quote, CR, or
/// LF), doubled quotes for escaping, and a `\r\n` line terminator.
fn write_csv_row(out: &mut String, fields: &[&str]) {
    for (i, field) in fields.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        let needs_quote = field
            .chars()
            .any(|c| c == ',' || c == '"' || c == '\r' || c == '\n');
        if needs_quote {
            out.push('"');
            for c in field.chars() {
                if c == '"' {
                    out.push('"');
                }
                out.push(c);
            }
            out.push('"');
        } else {
            out.push_str(field);
        }
    }
    out.push('\r');
    out.push('\n');
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
