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
        Some("distill-forge-diagnostics") => distill_forge_diagnostics(&args[2..]),
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
    eprintln!(
        "  tillandsias-policy distill-forge-diagnostics [--repo-root <path>] [--latest <path>] [--all]"
    );
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

// ===========================================================================
// `distill-forge-diagnostics` subcommand — faithful port of the former
// scripts/distill-forge-diagnostics.sh (which shelled out to python3 only for
// the JSON-flatten step). Reads the latest (or a given, or all) raw forge
// diagnostics log(s) from target/forge-diagnostics/, flattens the capabilities
// JSON, and writes a dated markdown summary to plan/diagnostics/ — including
// regression detection vs the previous run, an envelope-line fallback for the
// metadata header, and container-start stream forensics from the .stderr.log
// companion.
//
// @trace spec:default-image, spec:forge-as-only-runtime
// @trace spec:cli-diagnostics, spec:runtime-diagnostics-stream
// @trace spec:podman-idiomatic-patterns
// @trace plan/issues/forge-diagnostics-automation-2026-05-27.md
// ===========================================================================

const C_RED: &str = "\u{1b}[0;31m";
const C_GREEN: &str = "\u{1b}[0;32m";
const C_YELLOW: &str = "\u{1b}[1;33m";
const C_NC: &str = "\u{1b}[0m";

fn distill_info(msg: &str) {
    println!("{C_GREEN}[distill]{C_NC} {msg}");
}

fn distill_warn(msg: &str) {
    println!("{C_YELLOW}[distill]{C_NC} {msg}");
}

fn distill_error(msg: &str) {
    eprintln!("{C_RED}[distill]{C_NC} {msg}");
}

fn distill_forge_diagnostics(args: &[String]) {
    let mut repo_root = env::current_dir().unwrap_or_else(|err| {
        eprintln!("failed to read current dir: {err}");
        process::exit(2);
    });
    let mut latest_log: Option<String> = None;
    let mut process_all = false;

    let mut idx = 0;
    while idx < args.len() {
        match args[idx].as_str() {
            "--latest" => {
                idx += 1;
                latest_log = args.get(idx).cloned();
            }
            "--all" => process_all = true,
            "--repo-root" => {
                idx += 1;
                let Some(value) = args.get(idx) else {
                    eprintln!("--repo-root requires a path");
                    process::exit(2);
                };
                repo_root = PathBuf::from(value);
            }
            "--help" | "-h" => {
                println!(
                    "Usage: distill-forge-diagnostics [--repo-root <path>] [--latest <path>] [--all]"
                );
                return;
            }
            other => {
                distill_error(&format!("Unknown flag: {other}"));
                process::exit(2);
            }
        }
        idx += 1;
    }

    let diagnostics_dir = repo_root.join("target/forge-diagnostics");
    let plan_dir = repo_root.join("plan/diagnostics");

    if let Err(err) = fs::create_dir_all(&diagnostics_dir) {
        distill_error(&format!(
            "failed to create {}: {err}",
            diagnostics_dir.display()
        ));
        process::exit(2);
    }
    if let Err(err) = fs::create_dir_all(&plan_dir) {
        distill_error(&format!("failed to create {}: {err}", plan_dir.display()));
        process::exit(2);
    }

    // Resolve default latest log when neither --latest nor --all given.
    if latest_log.is_none() && !process_all {
        latest_log = newest_diagnostics_log(&diagnostics_dir).map(|p| p.display().to_string());
    }

    if latest_log.is_none() && !process_all {
        distill_warn(&format!(
            "No diagnostics logs found in {}",
            rel_display(&repo_root, &diagnostics_dir)
        ));
        distill_info("Run the forge diagnostics litmus test first to generate one.");
        process::exit(0);
    }

    if process_all {
        // Iterate diagnostics_*.log in shell-glob (lexical) order.
        let mut logs = list_diagnostics_logs(&diagnostics_dir);
        logs.sort();
        for log in logs {
            let _ = distill_one(&repo_root, &plan_dir, &log);
        }
    } else if let Some(log) = latest_log {
        let _ = distill_one(&repo_root, &plan_dir, &PathBuf::from(log));
    }

    distill_info(&format!(
        "Done. Summaries available in {}/",
        rel_display(&repo_root, &plan_dir)
    ));
}

/// Display a path relative to repo_root when possible, else absolute — mirrors
/// the shell which `cd`s to REPO_ROOT and uses relative `target/...` strings.
fn rel_display(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .display()
        .to_string()
}

/// `ls -t diagnostics_*.log | head -1` — newest by mtime.
fn newest_diagnostics_log(dir: &Path) -> Option<PathBuf> {
    let mut logs: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    let entries = fs::read_dir(dir).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        if is_diagnostics_log(&path) {
            let mtime = entry
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            logs.push((mtime, path));
        }
    }
    // Newest first; tie-break on path desc to be deterministic.
    logs.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
    logs.into_iter().next().map(|(_, p)| p)
}

fn list_diagnostics_logs(dir: &Path) -> Vec<PathBuf> {
    let mut logs = Vec::new();
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if is_diagnostics_log(&path) {
                logs.push(path);
            }
        }
    }
    logs
}

fn is_diagnostics_log(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    name.starts_with("diagnostics_") && name.ends_with(".log") && !name.ends_with(".stderr.log")
}

/// Flattened capability entry from the diagnostics JSON.
struct FlattenedDiagnostics {
    /// Ordered `section.key=STATUS` / `section=value` lines plus DIAGNOSTIC:,
    /// MISSING_TOOL:, etc., exactly as the python extractor printed them.
    lines: Vec<String>,
    timestamp: String,
    forge_version: String,
    parse_error: Option<String>,
}

/// Faithful port of the python JSON-flatten step (lines 86-129 of the script).
/// Returns the printed-line stream plus extracted timestamp/forge_version.
fn flatten_diagnostics_json(content: &str) -> FlattenedDiagnostics {
    let mut lines: Vec<String> = Vec::new();

    // Mirror the CPython extractor's control flow:
    //   match = re.search(r'\{.*\}', content, re.DOTALL)
    //   data  = json.loads(match.group(0)) if match else json.loads(content)
    // re.search with DOTALL finds the FIRST '{' through the LAST '}' (greedy).
    let brace_match = match (content.find('{'), content.rfind('}')) {
        (Some(a), Some(b)) if b >= a => Some(&content[a..=b]),
        _ => None,
    };
    let (to_parse, no_brace) = match brace_match {
        Some(slice) => (slice, false),
        None => (content, true),
    };

    let data: serde_json::Value = match serde_json::from_str(to_parse) {
        Ok(v) => v,
        Err(_) => {
            // CPython surfaces a `json.JSONDecodeError`; for the common
            // no-value case (empty file, or text not starting with a JSON
            // value) the message is `Expecting value: line 1 column C
            // (char N)` where N is the offset of the first non-whitespace
            // char on the failing slice. Reproduce that exact message for
            // the no-brace path (the dominant real-world case); fall back to
            // a clear generic string otherwise.
            let msg = if no_brace {
                expecting_value_message(content)
            } else {
                "Failed to parse JSON".to_string()
            };
            return FlattenedDiagnostics {
                lines: Vec::new(),
                timestamp: "unknown".to_string(),
                forge_version: "unknown".to_string(),
                parse_error: Some(msg),
            };
        }
    };

    // caps = data.get('capabilities', {})
    if let Some(caps) = data.get("capabilities").and_then(|v| v.as_object()) {
        for (section, values) in caps {
            if let Some(map) = values.as_object() {
                for (key, val) in map {
                    let status = if json_value_is_missing(val) {
                        "MISSING"
                    } else {
                        "OK"
                    };
                    lines.push(format!("{section}.{key}={status}"));
                }
            } else {
                lines.push(format!("{section}={}", json_scalar_str(values)));
            }
        }
    }

    // diag = data.get('diagnostics', [])
    if let Some(diag) = data.get("diagnostics").and_then(|v| v.as_array()) {
        for d in diag {
            lines.push(format!("DIAGNOSTIC: {}", json_scalar_str(d)));
        }
    }

    for t in data
        .get("missing_tools")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
    {
        lines.push(format!("MISSING_TOOL: {}", json_scalar_str(t)));
    }

    for e in data
        .get("proposed_enhancements")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
    {
        if let Some(obj) = e.as_object() {
            let ecosystem = obj
                .get("ecosystem")
                .map(json_scalar_str)
                .unwrap_or_else(|| "other".to_string());
            let tool = obj
                .get("tool")
                .map(json_scalar_str)
                .unwrap_or_else(|| "?".to_string());
            let why = obj.get("why").map(json_scalar_str).unwrap_or_default();
            lines.push(format!("PROPOSED_ENHANCEMENT: {ecosystem}: {tool} — {why}"));
        } else {
            lines.push(format!("PROPOSED_ENHANCEMENT: {}", json_scalar_str(e)));
        }
    }

    for r in data
        .get("isolation_or_privacy_risks")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
    {
        lines.push(format!("ISOLATION_RISK: {}", json_scalar_str(r)));
    }

    let timestamp = data
        .get("diagnostics_timestamp")
        .map(json_scalar_str)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    let forge_version = data
        .get("forge_version")
        .map(json_scalar_str)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string());

    FlattenedDiagnostics {
        lines,
        timestamp,
        forge_version,
        parse_error: None,
    }
}

/// Reproduce CPython `json`'s "Expecting value" error message for content that
/// does not begin with a JSON value. CPython skips leading whitespace
/// (` \t\n\r`) then raises at that position with line/column/char computed over
/// characters: `Expecting value: line L column C (char N)`.
fn expecting_value_message(content: &str) -> String {
    // json's whitespace class is exactly SPACE, TAB, LF, CR.
    let chars: Vec<char> = content.chars().collect();
    let skip_ws = |start: usize| {
        let mut i = start;
        while i < chars.len() && matches!(chars[i], ' ' | '\t' | '\n' | '\r') {
            i += 1;
        }
        i
    };
    let mut idx = skip_ws(0);
    // CPython dispatches on the first non-ws char. `[` opens an array: it
    // consumes the bracket, skips whitespace, and (when the next token is not
    // `]` or a value) raises "Expecting value" at that inner position. Walk
    // through nested array openings so the reported offset matches CPython for
    // logs that begin with `[…]`-shaped prose (e.g. `[lifecycle] …`).
    while idx < chars.len() && chars[idx] == '[' {
        let inner = skip_ws(idx + 1);
        if inner < chars.len() && chars[inner] == ']' {
            break; // empty array — would parse; stop (no value error here).
        }
        idx = inner;
        // If the inner token is another array opener, keep descending;
        // otherwise this is where CPython raises.
        if idx < chars.len() && chars[idx] == '[' {
            continue;
        }
        break;
    }
    // line = count of '\n' in chars[..idx] + 1; column = idx - (index after last '\n') + 1.
    let mut line = 1usize;
    let mut last_nl: Option<usize> = None;
    for (i, c) in chars.iter().enumerate().take(idx) {
        if *c == '\n' {
            line += 1;
            last_nl = Some(i);
        }
    }
    let col = match last_nl {
        Some(nl) => idx - nl, // idx - (nl+1) + 1
        None => idx + 1,
    };
    format!("Expecting value: line {line} column {col} (char {idx})")
}

/// Python truthiness + membership: status='MISSING' when
/// `not val or val in ('unset','N/A','BLOCKED','NOT_FOUND','NONE')`.
fn json_value_is_missing(val: &serde_json::Value) -> bool {
    // `not val` covers falsey: null, false, 0, 0.0, "", [], {}.
    let falsey = match val {
        serde_json::Value::Null => true,
        serde_json::Value::Bool(b) => !b,
        serde_json::Value::Number(n) => n.as_f64().map(|f| f == 0.0).unwrap_or(false),
        serde_json::Value::String(s) => s.is_empty(),
        serde_json::Value::Array(a) => a.is_empty(),
        serde_json::Value::Object(o) => o.is_empty(),
    };
    if falsey {
        return true;
    }
    if let Some(s) = val.as_str() {
        matches!(s, "unset" | "N/A" | "BLOCKED" | "NOT_FOUND" | "NONE")
    } else {
        false
    }
}

/// Render a JSON value the way Python's f-string `{val}` / `str(val)` would.
/// Top-level scalars: strings unquoted, bools True/False, null None, numbers
/// verbatim. Nested containers (dicts/lists, e.g. a risk object) use Python's
/// `repr()` form — single-quoted keys/strings, `True/False/None` literals, and
/// insertion order (preserved via serde_json's `preserve_order` feature) — to
/// match the former CPython extractor's `print(f'… {d}')`.
fn json_scalar_str(val: &serde_json::Value) -> String {
    match val {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Bool(b) => {
            if *b {
                "True".to_string()
            } else {
                "False".to_string()
            }
        }
        serde_json::Value::Null => "None".to_string(),
        serde_json::Value::Number(n) => n.to_string(),
        other => python_repr(other),
    }
}

/// Python `repr()` of a JSON value, used when a list/dict element is itself a
/// container (mirrors CPython's f-string formatting of nested structures).
fn python_repr(val: &serde_json::Value) -> String {
    match val {
        serde_json::Value::Null => "None".to_string(),
        serde_json::Value::Bool(b) => {
            if *b {
                "True".to_string()
            } else {
                "False".to_string()
            }
        }
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::String(s) => python_repr_str(s),
        serde_json::Value::Array(a) => {
            let inner: Vec<String> = a.iter().map(python_repr).collect();
            format!("[{}]", inner.join(", "))
        }
        serde_json::Value::Object(o) => {
            let inner: Vec<String> = o
                .iter()
                .map(|(k, v)| format!("{}: {}", python_repr_str(k), python_repr(v)))
                .collect();
            format!("{{{}}}", inner.join(", "))
        }
    }
}

/// CPython `repr()` of a str: prefers single quotes, switches to double quotes
/// only if the string contains a single quote but no double quote. Escapes
/// backslash, the active quote, and the standard control chars.
fn python_repr_str(s: &str) -> String {
    let has_single = s.contains('\'');
    let has_double = s.contains('"');
    let quote = if has_single && !has_double { '"' } else { '\'' };
    let mut out = String::with_capacity(s.len() + 2);
    out.push(quote);
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c == quote => {
                out.push('\\');
                out.push(c);
            }
            c => out.push(c),
        }
    }
    out.push(quote);
    out
}

fn distill_one(repo_root: &Path, plan_dir: &Path, log_file: &Path) -> Result<(), ()> {
    let log_basename = log_file
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default()
        .strip_suffix(".log")
        .unwrap_or_else(|| {
            log_file
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or_default()
        })
        .to_string();
    let summary_file = plan_dir.join(format!("{log_basename}-summary.md"));

    if !log_file.is_file() {
        distill_error(&format!(
            "Log file not found: {}",
            rel_display(repo_root, log_file)
        ));
        return Err(());
    }

    distill_info(&format!("Distilling: {}", rel_display(repo_root, log_file)));

    let content = fs::read_to_string(log_file).unwrap_or_default();
    let flat = flatten_diagnostics_json(&content);
    let lines = &flat.lines;
    let mut timestamp = flat.timestamp.clone();
    let mut forge_version = flat.forge_version.clone();
    let parse_error = flat.parse_error.clone();

    // Metrics.
    let ok_count = lines.iter().filter(|l| l.ends_with("=OK")).count();
    let missing_count = lines.iter().filter(|l| l.ends_with("=MISSING")).count();
    let total_checks = ok_count + missing_count;
    let completeness_pct = (ok_count * 100).checked_div(total_checks).unwrap_or(0);

    // Regression detection vs previous summary (2nd-newest *-summary.md).
    let regression_note = compute_regression_note(plan_dir, completeness_pct);

    // Envelope-line fallback for metadata header.
    let envelope = read_envelope(log_file);
    let mut envelope_host_platform = "unknown".to_string();
    let mut envelope_agent = "unknown".to_string();
    if let Some(env_fields) = &envelope {
        if !env_fields.host_platform.is_empty() {
            envelope_host_platform = env_fields.host_platform.clone();
        }
        if !env_fields.agent.is_empty() {
            envelope_agent = env_fields.agent.clone();
        }
        if timestamp == "unknown" && !env_fields.timestamp.is_empty() {
            timestamp = env_fields.timestamp.clone();
        }
        if forge_version == "unknown" && !env_fields.tversion.is_empty() {
            forge_version = format!(
                "{} (from-envelope; in-forge JSON missing)",
                env_fields.tversion
            );
        }
    }

    // Build the summary.
    let mut s = String::new();
    s.push_str(&format!("# Forge Diagnostics Summary — {timestamp}\n\n"));
    s.push_str("## Metadata\n\n");
    s.push_str(&format!(
        "- **Source log**: `{}`\n",
        rel_display(repo_root, log_file)
    ));
    s.push_str(&format!("- **Forge version**: {forge_version}\n"));
    s.push_str(&format!("- **Host platform**: {envelope_host_platform}\n"));
    s.push_str(&format!("- **Agent**: {envelope_agent}\n"));
    s.push_str(&format!(
        "- **Completeness**: {ok_count} / {total_checks} checks passed ({completeness_pct}%)\n"
    ));

    if let Some(note) = &regression_note {
        s.push_str("\n## Change vs Previous Run\n\n");
        s.push_str(note);
        s.push('\n');
    }

    if missing_count > 0 {
        s.push_str("\n## Missing Capabilities\n\n");
        for line in lines {
            if let Some(cap) = line.strip_suffix("=MISSING") {
                s.push_str(&format!("- `{cap}`\n"));
            }
        }
    }

    if let Some(pe) = &parse_error {
        s.push_str("\n## Parse Errors\n\n");
        s.push_str(&format!("- {pe}\n"));
    }

    // Recommended actions.
    s.push_str("\n## Recommended Actions\n\n");
    for line in lines {
        if let Some(cap) = line.strip_suffix("=MISSING") {
            s.push_str(&recommended_action(cap));
            s.push('\n');
        }
    }
    if missing_count == 0 {
        s.push_str(
            "- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.\n",
        );
    }

    // Isolation / privacy risks.
    let risks: Vec<String> = lines
        .iter()
        .filter_map(|l| l.strip_prefix("ISOLATION_RISK: ").map(|r| format!("- {r}")))
        .collect();
    if !risks.is_empty() {
        s.push_str("\n## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)\n\n");
        s.push_str(&risks.join("\n"));
        s.push('\n');
    }

    // Forge enhancement candidates.
    let missing_tools: Vec<String> = lines
        .iter()
        .filter_map(|l| l.strip_prefix("MISSING_TOOL: ").map(|t| format!("- {t}")))
        .collect();
    let enhancements: Vec<String> = lines
        .iter()
        .filter_map(|l| {
            l.strip_prefix("PROPOSED_ENHANCEMENT: ")
                .map(|e| format!("- {e}"))
        })
        .collect();
    if !missing_tools.is_empty() || !enhancements.is_empty() {
        s.push_str("\n## Forge Enhancement Candidates (→ curated-toolchain-backlog)\n\n");
        s.push_str(
            "Candidates only — orchestrator approves against the privacy/isolation gate.\n\n",
        );
        if !missing_tools.is_empty() {
            s.push_str("### Missing tools\n");
            s.push_str(&missing_tools.join("\n"));
            s.push('\n');
        }
        if !enhancements.is_empty() {
            s.push_str("### Proposed enhancements\n");
            s.push_str(&enhancements.join("\n"));
            s.push('\n');
        }
    }

    // Container-start stream forensics from the .stderr.log companion.
    append_container_start_stream(repo_root, log_file, &mut s);

    if let Err(err) = fs::write(&summary_file, &s) {
        distill_error(&format!(
            "failed to write {}: {err}",
            rel_display(repo_root, &summary_file)
        ));
        return Err(());
    }

    distill_info(&format!(
        "Summary written: {}",
        rel_display(repo_root, &summary_file)
    ));
    distill_info(&format!(
        "Completeness: {completeness_pct}% ({ok_count}/{total_checks})"
    ));
    Ok(())
}

/// `ls -t *-summary.md | head -2 | tail -1` then parse its Completeness %.
fn compute_regression_note(plan_dir: &Path, completeness_pct: usize) -> Option<String> {
    let mut summaries: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    let entries = fs::read_dir(plan_dir).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_default();
        if name.ends_with("-summary.md") {
            let mtime = entry
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            summaries.push((mtime, path));
        }
    }
    // Newest first.
    summaries.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
    // head -2 | tail -1 → the 2nd entry.
    let prev = summaries.get(1)?;
    let text = fs::read_to_string(&prev.1).ok()?;
    // The shell grep is `grep -o 'Completeness:[[:space:]]*[0-9]\+%'`, which
    // does NOT match the `**Completeness**: …` summary line (the `**` breaks the
    // literal `Completeness:`). When there's no match the shell falls back to
    // `echo "0"`, so prev_pct is 0 in practice. We reproduce that exactly:
    // parse a bare `Completeness:` (no markdown bold) or default to 0.
    let prev_pct = parse_completeness_pct(&text).unwrap_or(0);
    if prev_pct > completeness_pct {
        Some(format!(
            "**REGRESSION**: Completeness dropped from {prev_pct}% to {completeness_pct}%"
        ))
    } else if completeness_pct > prev_pct {
        Some(format!(
            "Improvement: completeness rose from {prev_pct}% to {completeness_pct}%"
        ))
    } else {
        None
    }
}

/// grep -o 'Completeness:[[:space:]]*[0-9]\+%' | first integer.
fn parse_completeness_pct(text: &str) -> Option<usize> {
    let idx = text.find("Completeness:")?;
    let rest = &text[idx + "Completeness:".len()..];
    let rest = rest.trim_start();
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return None;
    }
    // Require a trailing % to match the grep pattern `[0-9]\+%`.
    let after = &rest[digits.len()..];
    if !after.starts_with('%') {
        return None;
    }
    digits.parse().ok()
}

struct EnvelopeFields {
    timestamp: String,
    tversion: String,
    host_platform: String,
    agent: String,
}

/// Recover framing fields from the last `event:diagnostics_envelope ` line in
/// the `<log>.stderr.log` companion.
fn read_envelope(log_file: &Path) -> Option<EnvelopeFields> {
    let stderr_log = envelope_stderr_path(log_file);
    let meta = fs::metadata(&stderr_log).ok()?;
    if meta.len() == 0 {
        return None;
    }
    let text = fs::read_to_string(&stderr_log).ok()?;
    let line = text
        .lines()
        .rfind(|l| l.starts_with("event:diagnostics_envelope "))?;
    Some(EnvelopeFields {
        timestamp: extract_kv(line, "timestamp="),
        tversion: extract_kv(line, "tillandsias_version="),
        host_platform: extract_kv(line, "host_platform="),
        agent: extract_kv(line, "agent="),
    })
}

/// `${log_file%.log}.stderr.log`.
fn envelope_stderr_path(log_file: &Path) -> PathBuf {
    let s = log_file.to_string_lossy();
    let base = s.strip_suffix(".log").unwrap_or(&s);
    PathBuf::from(format!("{base}.stderr.log"))
}

/// grep -oE 'key=[^ ]+' | cut -d= -f2- on a space-delimited k=v line.
fn extract_kv(line: &str, key: &str) -> String {
    for token in line.split(' ') {
        if let Some(rest) = token.strip_prefix(key) {
            return rest.to_string();
        }
    }
    String::new()
}

fn append_container_start_stream(repo_root: &Path, log_file: &Path, s: &mut String) {
    let stderr_log = envelope_stderr_path(log_file);
    let Ok(meta) = fs::metadata(&stderr_log) else {
        return;
    };
    if meta.len() == 0 {
        return;
    }
    let Ok(text) = fs::read_to_string(&stderr_log) else {
        return;
    };
    let log_lines: Vec<&str> = text.lines().collect();

    let total_events = log_lines
        .iter()
        .filter(|l| l.contains("event:container_launch "))
        .count();
    let running_events = log_lines
        .iter()
        .filter(|l| l.contains("event:container_launch ") && l.contains(" state=running "))
        .count();
    let failed_events = log_lines
        .iter()
        .filter(|l| l.contains("event:container_launch ") && l.contains(" state=failed"))
        .count();

    // Distinct (stage, state) tuples: grep -oE 'event:container_launch stage=[^ ]+ state=[^ ]+' | sort -u.
    // The original pipes through coreutils `sort -u`, whose collation is
    // locale-dependent (en_US.UTF-8 orders e.g. `opencode-git` before
    // `opencode state`). We reproduce that exact ordering by deferring to the
    // same `sort -u` binary rather than a byte-order set, so output is
    // byte-identical to the shell on any given host.
    let mut stage_state_matches: Vec<String> = Vec::new();
    for line in &log_lines {
        if let Some(m) = extract_stage_state(line) {
            stage_state_matches.push(m);
        }
    }
    let stage_states = sort_unique_via_coreutil(&stage_state_matches);

    s.push_str("\n## Container-Start Stream (from .stderr.log companion)\n\n");
    s.push_str(&format!(
        "- **Source**: `{}`\n",
        rel_display(repo_root, &stderr_log)
    ));
    s.push_str(&format!("- **Total launch events**: {total_events}\n"));
    s.push_str(&format!("- **state=running**: {running_events}\n"));
    s.push_str(&format!("- **state=failed**: {failed_events}\n"));
    if !stage_states.is_empty() {
        s.push_str("\n### Distinct stage → state pairings\n\n");
        s.push_str("```\n");
        for ss in &stage_states {
            s.push_str(ss);
            s.push('\n');
        }
        s.push_str("```\n");
    }
    let _ = &stage_states;
    if failed_events > 0 {
        s.push_str("\n### ❌ Failed launches\n\n");
        s.push_str("```\n");
        for line in &log_lines {
            if line.contains("event:container_launch ") && line.contains(" state=failed") {
                s.push_str(line);
                s.push('\n');
            }
        }
        s.push_str("```\n");
    }

    // Typed-event arms.
    let exit_lines: Vec<&&str> = log_lines
        .iter()
        .filter(|l| l.contains("event:container_exit "))
        .collect();
    let signal_lines: Vec<&&str> = log_lines
        .iter()
        .filter(|l| l.contains("event:container_signal "))
        .collect();
    let resource_lines: Vec<&&str> = log_lines
        .iter()
        .filter(|l| l.contains("event:resource_exhaustion "))
        .collect();
    let stderr_lines: Vec<&&str> = log_lines
        .iter()
        .filter(|l| l.contains("event:container_stderr "))
        .collect();
    let exit_count = exit_lines.len();
    let signal_count = signal_lines.len();
    let resource_count = resource_lines.len();
    let stderr_count = stderr_lines.len();

    if exit_count > 0 || signal_count > 0 || resource_count > 0 || stderr_count > 0 {
        s.push_str("\n### Typed-event arms\n\n");
        s.push_str("| event type | count |\n");
        s.push_str("|---|---:|\n");
        if exit_count > 0 {
            s.push_str(&format!(
                "| event:container_exit       | {exit_count}     |\n"
            ));
        }
        if signal_count > 0 {
            s.push_str(&format!(
                "| event:container_signal     | {signal_count}   |\n"
            ));
        }
        if resource_count > 0 {
            s.push_str(&format!(
                "| event:resource_exhaustion  | {resource_count} |\n"
            ));
        }
        if stderr_count > 0 {
            s.push_str(&format!(
                "| event:container_stderr     | {stderr_count}   |\n"
            ));
        }

        if exit_count > 0 {
            s.push_str("\n#### container_exit lines (head 10)\n");
            s.push_str("```\n");
            for line in exit_lines.iter().take(10) {
                s.push_str(line);
                s.push('\n');
            }
            s.push_str("```\n");
        }
        if signal_count > 0 {
            s.push_str("\n#### container_signal lines (head 10)\n");
            s.push_str("```\n");
            for line in signal_lines.iter().take(10) {
                s.push_str(line);
                s.push('\n');
            }
            s.push_str("```\n");
        }
        if resource_count > 0 {
            s.push_str("\n#### resource_exhaustion lines (head 10)\n");
            s.push_str("```\n");
            for line in resource_lines.iter().take(10) {
                s.push_str(line);
                s.push('\n');
            }
            s.push_str("```\n");
        }
        if stderr_count > 0 {
            // grep -oE 'event:container_stderr container=[^ ]+' | sort | uniq -c | sort -rn | head -5
            let by_container = top_stderr_containers(&log_lines);
            if !by_container.is_empty() {
                s.push_str("\n#### container_stderr — top 5 containers by line count\n");
                s.push_str("```\n");
                for entry in &by_container {
                    s.push_str(entry);
                    s.push('\n');
                }
                s.push_str("```\n");
            }
        }
    }
}

/// Reproduce `... | sort -u` using the same coreutils binary the original
/// pipeline used, so the locale-dependent collation is byte-identical to the
/// shell. Falls back to a byte-order dedup if `sort` is unavailable.
fn sort_unique_via_coreutil(lines: &[String]) -> Vec<String> {
    if lines.is_empty() {
        return Vec::new();
    }
    let input = {
        let mut buf = lines.join("\n");
        buf.push('\n');
        buf
    };
    use std::io::Write;
    use std::process::{Command, Stdio};
    let child = Command::new("sort")
        .arg("-u")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn();
    if let Ok(mut child) = child {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(input.as_bytes());
        }
        if let Ok(output) = child.wait_with_output() {
            return String::from_utf8_lossy(&output.stdout)
                .lines()
                .map(|l| l.to_string())
                .collect();
        }
    }
    // Fallback: byte-order unique.
    let mut set: BTreeSet<String> = BTreeSet::new();
    for l in lines {
        set.insert(l.clone());
    }
    set.into_iter().collect()
}

/// Extract `event:container_launch stage=<x> state=<y>` (matching grep -oE).
fn extract_stage_state(line: &str) -> Option<String> {
    let idx = line.find("event:container_launch stage=")?;
    let rest = &line[idx..];
    // event:container_launch stage=<nonspace> state=<nonspace>
    let mut parts = rest.split(' ');
    let _ev = parts.next()?; // event:container_launch
    let stage = parts.next()?; // stage=...
    if !stage.starts_with("stage=") {
        return None;
    }
    let state = parts.next()?; // state=...
    if !state.starts_with("state=") {
        return None;
    }
    Some(format!("event:container_launch {stage} {state}"))
}

/// Reproduce `grep -oE 'event:container_stderr container=[^ ]+' | sort | uniq -c
/// | sort -rn | head -5`, including the leading whitespace of `uniq -c`.
fn top_stderr_containers(log_lines: &[&str]) -> Vec<String> {
    let mut matches: Vec<String> = Vec::new();
    for line in log_lines {
        let mut search = 0;
        while let Some(rel) = line[search..].find("event:container_stderr container=") {
            let start = search + rel;
            let after = &line[start..];
            // up to first space
            let token_end = after.find(' ').unwrap_or(after.len());
            // but the prefix "event:container_stderr " contains a space; grep -oE
            // matches the full regex 'event:container_stderr container=[^ ]+'.
            // Reconstruct: literal "event:container_stderr container=" + [^ ]+.
            let prefix = "event:container_stderr container=";
            let val_start = start + prefix.len();
            if val_start <= line.len() {
                let val_region = &line[val_start..];
                let val_len = val_region.find(' ').unwrap_or(val_region.len());
                let matched = &line[start..val_start + val_len];
                matches.push(matched.to_string());
            }
            search = start + token_end.max(1);
        }
    }
    // sort | uniq -c
    matches.sort();
    let mut counts: Vec<(usize, String)> = Vec::new();
    for m in matches {
        if let Some(last) = counts.last_mut()
            && last.1 == m
        {
            last.0 += 1;
            continue;
        }
        counts.push((1, m));
    }
    // sort -rn (by count desc; uniq output order for ties is by value asc, but
    // sort -rn is not stable on the count key — GNU sort uses the whole line as
    // tiebreak which keeps value asc reversed... match practical behavior:
    // sort -rn sorts numerically desc, ties keep input order).
    counts.sort_by_key(|b| std::cmp::Reverse(b.0));
    counts
        .into_iter()
        .take(5)
        .map(|(c, m)| format!("{:>7} {m}", c))
        .collect()
}

/// Per-capability recommended-action text (the shell case statement).
fn recommended_action(cap: &str) -> String {
    match cap {
        "agent_available.claude" => {
            "- Install claude-code in Containerfile (npm install -g @anthropic-ai/claude-code)".to_string()
        }
        "agent_available.codex" => {
            "- Install codex in Containerfile (npm install -g @openai/codex)".to_string()
        }
        "network_isolation.external_curl" => {
            "- Verify enclave network isolation: forge should not reach external internet directly".to_string()
        }
        "network_isolation.inference_reachable" => {
            "- Ensure inference container is running and reachable on 'inference:11434'".to_string()
        }
        "agent_instructions.paths" => {
            "- Check that cache-discipline.md is properly mounted into ~/.config/opencode/instructions/".to_string()
        }
        "shell.tillandsias_help" => {
            "- Ensure tillandsias-help shell function is sourced (check shell-helpers.sh)".to_string()
        }
        "openspec.opsx_bin" => "- Install openspec CLI in Containerfile".to_string(),
        _ => {
            if let Some(rest) = cap.strip_prefix("hot_paths.") {
                format!("- Verify tmpfs mount sizes in build_podman_args() for {rest}")
            } else if let Some(rest) = cap.strip_prefix("cache_routing.") {
                format!("- Ensure {rest} is exported in lib-common.sh")
            } else {
                format!("- Investigate missing capability: {cap}")
            }
        }
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

    #[test]
    fn diagnostics_missing_status_matches_python_truthiness() {
        use serde_json::json;
        assert!(json_value_is_missing(&json!("")));
        assert!(json_value_is_missing(&json!("unset")));
        assert!(json_value_is_missing(&json!("BLOCKED")));
        assert!(json_value_is_missing(&json!("NOT_FOUND")));
        assert!(json_value_is_missing(&json!(null)));
        assert!(json_value_is_missing(&json!(false)));
        assert!(json_value_is_missing(&json!(0)));
        assert!(!json_value_is_missing(&json!("/usr/bin/opencode")));
        assert!(!json_value_is_missing(&json!("yes")));
        assert!(!json_value_is_missing(&json!(true)));
    }

    #[test]
    fn flattens_capabilities_and_metadata() {
        let raw = r#"prefix junk
{"diagnostics_timestamp":"2026-06-16T07:28:47Z","forge_version":"0.3.0",
 "capabilities":{"agent_available":{"claude":"NOT_FOUND","opencode":"/usr/bin/opencode"}},
 "diagnostics":["check ran"],
 "missing_tools":["ripgrep"],
 "proposed_enhancements":[{"ecosystem":"rust","tool":"bacon","why":"watch"}],
 "isolation_or_privacy_risks":["leak X"]}
trailing"#;
        let flat = flatten_diagnostics_json(raw);
        assert_eq!(flat.timestamp, "2026-06-16T07:28:47Z");
        assert_eq!(flat.forge_version, "0.3.0");
        assert!(flat.parse_error.is_none());
        assert!(
            flat.lines
                .contains(&"agent_available.claude=MISSING".to_string())
        );
        assert!(
            flat.lines
                .contains(&"agent_available.opencode=OK".to_string())
        );
        assert!(flat.lines.contains(&"DIAGNOSTIC: check ran".to_string()));
        assert!(flat.lines.contains(&"MISSING_TOOL: ripgrep".to_string()));
        assert!(
            flat.lines
                .contains(&"PROPOSED_ENHANCEMENT: rust: bacon — watch".to_string())
        );
        assert!(flat.lines.contains(&"ISOLATION_RISK: leak X".to_string()));
    }

    #[test]
    fn parse_error_when_no_json() {
        let flat = flatten_diagnostics_json("no json here at all");
        assert!(flat.parse_error.is_some());
        assert_eq!(flat.timestamp, "unknown");
    }

    #[test]
    fn python_repr_matches_cpython_dict_form() {
        use serde_json::json;
        // Insertion order preserved (preserve_order feature); single-quoted.
        let v = json!({"risk": "x", "detail": "it's bad"});
        assert_eq!(python_repr(&v), "{'risk': 'x', 'detail': \"it's bad\"}");
        assert_eq!(python_repr(&json!([1, true, null])), "[1, True, None]");
    }

    #[test]
    fn expecting_value_message_matches_cpython() {
        // Empty file → char 0.
        assert_eq!(
            expecting_value_message(""),
            "Expecting value: line 1 column 1 (char 0)"
        );
        // Leading whitespace then junk → position of first non-ws char.
        assert_eq!(
            expecting_value_message(" x"),
            "Expecting value: line 1 column 2 (char 1)"
        );
        // Starts with `[` (valid array opener); CPython fails at the inner
        // non-value token at char 1.
        assert_eq!(
            expecting_value_message("[lifecycle] foo"),
            "Expecting value: line 1 column 2 (char 1)"
        );
    }

    #[test]
    fn completeness_pct_parsing_matches_shell_grep() {
        // The shell grep matches a bare `Completeness:[[:space:]]*[0-9]+%`.
        assert_eq!(parse_completeness_pct("Completeness: 100%"), Some(100));
        assert_eq!(parse_completeness_pct("Completeness:50%"), Some(50));
        // The `**Completeness**:` summary line does NOT contain the literal
        // `Completeness:` substring, so (like the shell) it does not match.
        assert_eq!(
            parse_completeness_pct("- **Completeness**: 9 / 12 checks passed (75%)"),
            None
        );
        // Digits without a trailing % do not match the grep pattern.
        assert_eq!(parse_completeness_pct("Completeness: 9 / 12"), None);
        assert_eq!(parse_completeness_pct("no completeness here"), None);
    }
}
