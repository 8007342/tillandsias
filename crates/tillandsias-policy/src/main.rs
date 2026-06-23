use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::io::{self, Read};
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
        Some("validate-forge-diagnostics-json") => validate_forge_diagnostics_json(&args[2..]),
        Some("json-get-string") => json_get_string(&args[2..]),
        Some("assert-menu-items") => assert_menu_items(&args[2..]),
        Some("assert-disabled-v2") => assert_disabled_v2(&args[2..]),
        Some("vault-unsealed-epoch") => vault_unsealed_epoch(&args[2..]),
        Some("regenerate-cheatsheet-index") => regenerate_cheatsheet_index(&args[2..]),
        Some("fetch-cheatsheet-source") => fetch_cheatsheet_source(&args[2..]),
        Some("validate-yaml") => validate_yaml(&args[2..]),
        Some("run-in-pty") => run_in_pty_cmd(&args[2..]),
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
    eprintln!("  tillandsias-policy validate-forge-diagnostics-json <diagnostics-log>");
    eprintln!("  tillandsias-policy json-get-string <json.path> < stdin-json");
    eprintln!("  tillandsias-policy assert-menu-items <menu-json-file> <id>...");
    eprintln!("  tillandsias-policy assert-disabled-v2 <menu-json-file> <id>...");
    eprintln!("  tillandsias-policy vault-unsealed-epoch < stdin-json");
    eprintln!("  tillandsias-policy regenerate-cheatsheet-index [--repo-root <path>] [--check]");
    eprintln!(
        "  tillandsias-policy fetch-cheatsheet-source [--repo-root <path>] <URL> [--cite <path>] [--manual-review] [--force]"
    );
    eprintln!(
        "  tillandsias-policy fetch-cheatsheet-source [--repo-root <path>] --tier=bundled [--max-age-days N] [--dry-run]"
    );
    eprintln!("  tillandsias-policy validate-yaml <file>...");
    eprintln!("  tillandsias-policy run-in-pty <command>...");
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

fn json_get_string(args: &[String]) {
    if args.len() != 1 {
        eprintln!("Usage: json-get-string <json.path> < stdin-json");
        process::exit(2);
    }

    let data = read_json_stdin("json-get-string");
    let value = json_path(&data, &args[0]).unwrap_or_else(|| {
        eprintln!("json-get-string: missing path {}", args[0]);
        process::exit(1);
    });
    match value {
        serde_json::Value::String(s) => println!("{s}"),
        serde_json::Value::Null => {
            eprintln!("json-get-string: {} is null", args[0]);
            process::exit(1);
        }
        other => println!("{}", json_scalar_str(other)),
    }
}

fn assert_menu_items(args: &[String]) {
    if args.len() < 2 {
        eprintln!("Usage: assert-menu-items <menu-json-file> <id>...");
        process::exit(2);
    }

    let path = Path::new(&args[0]);
    let data = read_json_file(path);
    let ids = menu_item_ids(path, &data);
    let missing: Vec<&str> = args[1..]
        .iter()
        .map(String::as_str)
        .filter(|id| !ids.contains(*id))
        .collect();
    if !missing.is_empty() {
        eprintln!(
            "{}: missing menu item id(s): {}",
            path.display(),
            missing.join(", ")
        );
        process::exit(1);
    }
    println!("OK");
}

fn assert_disabled_v2(args: &[String]) {
    if args.len() < 2 {
        eprintln!("Usage: assert-disabled-v2 <menu-json-file> <id>...");
        process::exit(2);
    }

    let path = Path::new(&args[0]);
    let data = read_json_file(path);
    let items = data.as_array().unwrap_or_else(|| {
        eprintln!("{}: menu JSON must be an array", path.display());
        process::exit(1);
    });

    for id in &args[1..] {
        let item = items
            .iter()
            .find(|item| item.get("id").and_then(|v| v.as_str()) == Some(id.as_str()))
            .unwrap_or_else(|| {
                eprintln!("{}: missing menu item id {id}", path.display());
                process::exit(1);
            });
        if item.get("disabled").and_then(|v| v.as_bool()) != Some(true) {
            eprintln!("{}: menu item {id} is not disabled", path.display());
            process::exit(1);
        }
        let reason = item
            .get("disabled_reason")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if !reason.contains("v2") {
            eprintln!(
                "{}: menu item {id} disabled_reason lacks v2 marker",
                path.display()
            );
            process::exit(1);
        }
    }
    println!("OK");
}

fn vault_unsealed_epoch(args: &[String]) {
    if !args.is_empty() {
        eprintln!("Usage: vault-unsealed-epoch < stdin-json");
        process::exit(2);
    }

    let data = read_json_stdin("vault-unsealed-epoch");
    let sealed = data.get("sealed").and_then(|v| v.as_bool()).unwrap_or(true);
    if sealed {
        eprintln!("vault-unsealed-epoch: vault is sealed");
        process::exit(1);
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_else(|err| {
            eprintln!("vault-unsealed-epoch: system clock before Unix epoch: {err}");
            process::exit(1);
        })
        .as_secs();
    println!("{now}");
}

fn read_json_stdin(context: &str) -> serde_json::Value {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .unwrap_or_else(|err| {
            eprintln!("{context}: failed to read stdin: {err}");
            process::exit(1);
        });
    serde_json::from_str(&input).unwrap_or_else(|err| {
        eprintln!("{context}: invalid JSON: {err}");
        process::exit(1);
    })
}

fn read_json_file(path: &Path) -> serde_json::Value {
    let input = fs::read_to_string(path).unwrap_or_else(|err| {
        eprintln!("{}: {err}", path.display());
        process::exit(1);
    });
    serde_json::from_str(&input).unwrap_or_else(|err| {
        eprintln!("{}: invalid JSON: {err}", path.display());
        process::exit(1);
    })
}

fn json_path<'a>(value: &'a serde_json::Value, path: &str) -> Option<&'a serde_json::Value> {
    let mut current = value;
    for segment in path.split('.') {
        if segment.is_empty() {
            return None;
        }
        current = current.get(segment)?;
    }
    Some(current)
}

fn menu_item_ids(path: &Path, data: &serde_json::Value) -> BTreeSet<String> {
    let items = data.as_array().unwrap_or_else(|| {
        eprintln!("{}: menu JSON must be an array", path.display());
        process::exit(1);
    });
    items
        .iter()
        .filter_map(|item| item.get("id").and_then(|v| v.as_str()))
        .map(str::to_string)
        .collect()
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
        || (rel_str.starts_with("openspec/litmus-tests/") && matches!(ext, "yaml" | "yml"))
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
        || lower.contains("python -c")
        || lower.contains("python3 -c")
        || lower.contains("python /tmp/")
        || lower.contains("python3 /tmp/")
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

fn validate_forge_diagnostics_json(args: &[String]) {
    if args.len() != 1 {
        eprintln!("Usage: validate-forge-diagnostics-json <diagnostics-log>");
        process::exit(2);
    }

    let path = Path::new(&args[0]);
    let content = fs::read_to_string(path).unwrap_or_else(|err| {
        eprintln!("{}: {err}", path.display());
        process::exit(1);
    });

    let (to_parse, _) = diagnostics_json_candidate(&content);
    let data: serde_json::Value = serde_json::from_str(to_parse).unwrap_or_else(|err| {
        eprintln!("{}: invalid JSON: {err}", path.display());
        process::exit(1);
    });
    let Some(obj) = data.as_object() else {
        eprintln!("{}: diagnostics root must be a JSON object", path.display());
        process::exit(1);
    };

    let timestamp = obj
        .get("diagnostics_timestamp")
        .unwrap_or_else(|| fail_json_shape(path, "missing diagnostics_timestamp"));
    let caps = obj
        .get("capabilities")
        .and_then(|v| v.as_object())
        .unwrap_or_else(|| fail_json_shape(path, "missing capabilities object"));
    if !caps.contains_key("agent_available") {
        fail_json_shape(path, "missing capabilities.agent_available");
    }

    let missing_tools = required_array(obj, path, "missing_tools");
    let proposed_enhancements = required_array(obj, path, "proposed_enhancements");
    let isolation_risks = required_array(obj, path, "isolation_or_privacy_risks");

    println!("PASS: forge diagnostics JSON valid");
    println!("  timestamp: {}", json_scalar_str(timestamp));
    for (section, values) in caps {
        if let Some(map) = values.as_object() {
            for (key, val) in map {
                let status = if json_value_is_missing_for_litmus(val) {
                    "MISSING"
                } else {
                    "OK"
                };
                println!("  [{status}] {section}.{key} = {}", json_scalar_str(val));
            }
        } else {
            println!("  [INFO] {section} = {}", json_scalar_str(values));
        }
    }
    println!(
        "  missing_tools: {}; proposed_enhancements: {}; isolation_risks: {}",
        missing_tools.len(),
        proposed_enhancements.len(),
        isolation_risks.len()
    );
}

fn fail_json_shape(path: &Path, message: &str) -> ! {
    eprintln!("{}: {message}", path.display());
    process::exit(1);
}

fn required_array<'a>(
    obj: &'a serde_json::Map<String, serde_json::Value>,
    path: &Path,
    field: &str,
) -> &'a Vec<serde_json::Value> {
    obj.get(field)
        .and_then(|v| v.as_array())
        .unwrap_or_else(|| fail_json_shape(path, &format!("{field} must be an array")))
}

fn diagnostics_json_candidate(content: &str) -> (&str, bool) {
    match (content.find('{'), content.rfind('}')) {
        (Some(a), Some(b)) if b >= a => (&content[a..=b], false),
        _ => (content, true),
    }
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
    let (to_parse, no_brace) = diagnostics_json_candidate(content);

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

fn json_value_is_missing_for_litmus(val: &serde_json::Value) -> bool {
    matches!(
        val.as_str(),
        Some("unset" | "N/A" | "BLOCKED" | "NOT_FOUND" | "NONE")
    )
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

// ===========================================================================
// fetch-cheatsheet-source — verbatim fetcher for the cheatsheet-source layer.
//
// Faithful Rust port of scripts/fetch-cheatsheet-source.sh. The script's six
// python3 sites handled: YAML frontmatter parsing, structural-drift heading
// fingerprint, allowlist field extraction (x2), cited_by extraction, and
// ## Provenance local: line insertion — all reimplemented below. Network fetch
// is delegated to the `curl` binary exactly as the shell did.
//
// @trace spec:cheatsheet-source-layer, spec:cheatsheets-license-tiered
// ===========================================================================

const FETCHER_VERSION: u32 = 1;

fn fetch_die(msg: &str) -> ! {
    eprintln!("error: {msg}");
    process::exit(1);
}

fn fetch_info(msg: &str) {
    println!("  {msg}");
}

struct FetchConfig {
    repo_root: PathBuf,
    sources_dir: PathBuf,
    allowlist: PathBuf,
    scripts_dir: PathBuf,
    cache_dir: PathBuf,
    user_agent: String,
}

fn fetch_cheatsheet_source(args: &[String]) {
    let mut repo_root: Option<PathBuf> = None;
    let mut url = String::new();
    let mut cite_path = String::new();
    let mut manual_review = false;
    let mut force = false;
    let mut tier_mode = String::new();
    let mut max_age_days = String::new();
    let mut dry_run = false;

    let mut idx = 0;
    while idx < args.len() {
        let arg = args[idx].as_str();
        match arg {
            "--repo-root" => {
                idx += 1;
                let Some(value) = args.get(idx) else {
                    eprintln!("--repo-root requires a path");
                    process::exit(2);
                };
                repo_root = Some(PathBuf::from(value));
            }
            "--cite" => {
                idx += 1;
                let Some(value) = args.get(idx) else {
                    eprintln!("error: --cite requires a path argument");
                    process::exit(2);
                };
                cite_path = value.clone();
            }
            "--manual-review" => manual_review = true,
            "--force" => force = true,
            "--canonicalize" => { /* reserved; silently accepted */ }
            "--dry-run" => dry_run = true,
            "--max-age-days" => {
                idx += 1;
                let Some(value) = args.get(idx) else {
                    eprintln!("error: --max-age-days requires a numeric argument");
                    process::exit(2);
                };
                max_age_days = value.clone();
            }
            _ if arg.starts_with("--tier=") => {
                tier_mode = arg["--tier=".len()..].to_string();
                if tier_mode != "bundled" {
                    eprintln!("error: --tier={tier_mode} not supported (only 'bundled' for now)");
                    process::exit(2);
                }
            }
            _ if arg.starts_with("--max-age-days=") => {
                max_age_days = arg["--max-age-days=".len()..].to_string();
            }
            _ if arg.starts_with("--") => {
                eprintln!("error: unknown option: {arg}");
                process::exit(2);
            }
            _ => {
                if url.is_empty() {
                    url = arg.to_string();
                } else {
                    eprintln!("error: unexpected argument: {arg}");
                    process::exit(2);
                }
            }
        }
        idx += 1;
    }

    let repo_root = repo_root.unwrap_or_else(|| {
        env::current_dir().unwrap_or_else(|err| {
            eprintln!("failed to read current dir: {err}");
            process::exit(2);
        })
    });

    let sources_dir = match env::var("CHEATSHEET_SOURCES_DIR") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => repo_root.join("cheatsheet-sources"),
    };
    let allowlist = if repo_root
        .join("cheatsheets/license-allowlist.toml")
        .is_file()
    {
        repo_root.join("cheatsheets/license-allowlist.toml")
    } else {
        repo_root.join("cheatsheet-sources/license-allowlist.toml")
    };
    let cache_dir = match env::var("CACHE_DIR") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => {
            let base = env::var("XDG_CACHE_HOME")
                .ok()
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(env::var("HOME").unwrap_or_default()).join(".cache")
                });
            base.join("tillandsias")
        }
    };
    let cfg = FetchConfig {
        repo_root: repo_root.clone(),
        sources_dir,
        allowlist,
        scripts_dir: repo_root.join("scripts"),
        cache_dir,
        user_agent: format!(
            "tillandsias-cheatsheet-fetcher/{FETCHER_VERSION} (+https://github.com/8007342/tillandsias)"
        ),
    };

    // Bundled-tier dispatch.
    if !tier_mode.is_empty() {
        if !url.is_empty() {
            eprintln!("error: --tier={tier_mode} does not accept a positional URL argument");
            process::exit(2);
        }
        fetch_bundled_tier_main(&cfg, &max_age_days, dry_run);
        return;
    }

    if url.is_empty() {
        eprintln!(
            "usage: fetch-cheatsheet-source.sh <URL> [--cite cheatsheets/<path>] [--manual-review] [--force]"
        );
        eprintln!(
            "   or: fetch-cheatsheet-source.sh --tier=bundled [--max-age-days N] [--dry-run]"
        );
        process::exit(2);
    }

    fetch_single_url(&cfg, &url, &cite_path, manual_review, force);
}

/// SHA-256 hex of bytes (full digest).
fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    let mut s = String::with_capacity(64);
    for b in digest {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// Parse YAML frontmatter to key=value / key+=item lines, faithful port of the
/// `parse_frontmatter` PYEOF (a tiny YAML subset). Returns the emitted lines.
fn fetch_parse_frontmatter_lines(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    // Frontmatter is the block between the first two "---" lines: ^---\n(...)\n---\n
    if !text.starts_with("---\n") {
        return out;
    }
    let rest = &text[4..];
    let Some(end) = rest.find("\n---\n") else {
        return out;
    };
    let fm = &rest[..end];

    let mut current_list_key: Option<String> = None;
    for line in fm.lines() {
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        // List item: ^\s+-\s+(.*)$
        if let Some(item) = fetch_match_list_item(line)
            && let Some(key) = &current_list_key
        {
            let v = item.trim().trim_matches('"').trim_matches('\'');
            out.push(format!("{key}+={v}"));
            continue;
        }
        // key: value  (^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$)
        if let Some((key, value)) = fetch_match_kv(line) {
            let value = value.trim();
            if value.is_empty() || value == "|" || value == ">" {
                current_list_key = Some(key.to_string());
            } else {
                current_list_key = None;
                let v = value.trim_matches('"').trim_matches('\'');
                out.push(format!("{key}={v}"));
            }
        }
    }
    out
}

/// Match `^\s+-\s+(.*)$`: leading whitespace, dash, whitespace, capture rest.
fn fetch_match_list_item(line: &str) -> Option<&str> {
    let trimmed = line.strip_prefix(|c: char| c == ' ' || c == '\t')?;
    let after_ws = trimmed.trim_start_matches([' ', '\t']);
    let after_dash = after_ws.strip_prefix('-')?;
    if !after_dash.starts_with([' ', '\t']) {
        return None;
    }
    Some(after_dash.trim_start_matches([' ', '\t']))
}

/// Match `^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$`.
fn fetch_match_kv(line: &str) -> Option<(&str, &str)> {
    let (key, value) = line.split_once(':')?;
    let key = key.trim_end_matches([' ', '\t']);
    if key.is_empty() {
        return None;
    }
    let mut chars = key.chars();
    let first = chars.next()?;
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return None;
    }
    if !chars.all(|c| c == '_' || c.is_ascii_alphanumeric()) {
        return None;
    }
    Some((key, value.trim_start_matches([' ', '\t'])))
}

/// Returns true if the cheatsheet declares tier: bundled.
fn fetch_is_bundled_tier(text: &str) -> bool {
    fetch_parse_frontmatter_lines(text)
        .iter()
        .any(|l| l == "tier=bundled")
}

/// Extract source URLs (prefer source_urls+=, fall back to sources+=), filter
/// to https://.
fn fetch_extract_source_urls(text: &str) -> Vec<String> {
    let lines = fetch_parse_frontmatter_lines(text);
    let mut urls: Vec<String> = lines
        .iter()
        .filter_map(|l| l.strip_prefix("source_urls+="))
        .map(|s| s.to_string())
        .collect();
    if urls.is_empty() {
        urls = lines
            .iter()
            .filter_map(|l| l.strip_prefix("sources+="))
            .map(|s| s.to_string())
            .collect();
    }
    urls.into_iter()
        .filter(|u| u.starts_with("https://"))
        .collect()
}

/// Compute the bundled-tier cache key:
///   SHA-256( "\n".join(sort -u(urls)) + "\n" + "max-age-days=N\n" )[:16]
/// The shell pipes the URLs through `sort -u`, so we must use the same locale
/// collation for byte-for-byte parity.
fn fetch_bundled_cache_key(max_age: &str, urls: &[String]) -> String {
    let sorted = locale_sort_unique(urls);
    let mut buf = String::new();
    for u in &sorted {
        buf.push_str(u);
        buf.push('\n');
    }
    buf.push_str(&format!("max-age-days={max_age}\n"));
    let hex = sha256_hex(buf.as_bytes());
    hex.chars().take(16).collect()
}

/// Equivalent to `printf '%s\n' "${items[@]}" | sort -u`: locale-collated,
/// de-duplicated. Falls back to a byte-wise sort+dedup if `sort` is missing.
fn locale_sort_unique(items: &[String]) -> Vec<String> {
    use std::io::Write;
    if items.is_empty() {
        return Vec::new();
    }
    let mut input = String::new();
    for it in items {
        input.push_str(it);
        input.push('\n');
    }
    let child = std::process::Command::new("sort")
        .arg("-u")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn();
    let byte_fallback = || {
        let mut v: Vec<String> = items.to_vec();
        v.sort();
        v.dedup();
        v
    };
    let Ok(mut child) = child else {
        return byte_fallback();
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input.as_bytes());
    }
    let Ok(output) = child.wait_with_output() else {
        return byte_fallback();
    };
    if !output.status.success() {
        return byte_fallback();
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|l| l.to_string())
        .collect()
}

fn fetch_bundled_tier_main(cfg: &FetchConfig, max_age_days: &str, dry_run: bool) {
    let cheatsheets_dir = cfg.repo_root.join("cheatsheets");
    if !cheatsheets_dir.is_dir() {
        fetch_die(&format!(
            "cheatsheets/ directory not found at {}",
            cheatsheets_dir.display()
        ));
    }

    fetch_info(&format!(
        "scanning {} for tier: bundled cheatsheets",
        cheatsheets_dir.display()
    ));

    let mut all_files = Vec::new();
    collect_markdown_files(&cheatsheets_dir, &mut all_files);
    // The shell uses `find ... -print0` whose order is filesystem order; the
    // bundled list order only affects per-file fetch ordering (not the cache
    // key, which sorts). For dry-run output (sorted -u) ordering is normalised.
    let mut bundled_files: Vec<(PathBuf, String)> = Vec::new();
    for f in all_files {
        if let Ok(text) = fs::read_to_string(&f)
            && fetch_is_bundled_tier(&text)
        {
            bundled_files.push((f, text));
        }
    }

    if bundled_files.is_empty() {
        fetch_info("no tier: bundled cheatsheets found");
        println!("key=");
        println!("dir=");
        return;
    }

    fetch_info(&format!(
        "found {} bundled cheatsheet(s)",
        bundled_files.len()
    ));

    // Union of source URLs across all bundled cheatsheets (in file order).
    let mut all_urls: Vec<String> = Vec::new();
    let mut file_urls: Vec<(PathBuf, Vec<String>)> = Vec::new();
    for (f, text) in &bundled_files {
        let urls = fetch_extract_source_urls(text);
        for u in &urls {
            all_urls.push(u.clone());
        }
        file_urls.push((f.clone(), urls));
    }

    if all_urls.is_empty() {
        fetch_info("warning: no source URLs found across bundled cheatsheets");
        println!("key=");
        println!("dir=");
        return;
    }

    let max_age = if max_age_days.is_empty() {
        "unset"
    } else {
        max_age_days
    };
    let key = fetch_bundled_cache_key(max_age, &all_urls);
    let key_dir = cfg.cache_dir.join("cheatsheet-source-bake").join(&key);

    fetch_info(&format!("cache key: {key}"));
    fetch_info(&format!("cache dir: {}", key_dir.display()));

    if dry_run {
        fetch_info("[dry-run] would fetch the following URLs:");
        for u in locale_sort_unique(&all_urls) {
            fetch_info(&format!("  {u}"));
        }
        println!("key={key}");
        println!("dir={}", key_dir.display());
        return;
    }

    let _ = fs::create_dir_all(&key_dir);

    let total = all_urls.len();
    let mut fetched = 0usize;
    let mut failed = 0usize;
    let skipped = 0usize;
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();

    for (f, urls) in &file_urls {
        for url in urls {
            if seen.contains(url) {
                continue;
            }
            seen.insert(url.clone());
            let cited_by = f
                .strip_prefix(&cfg.repo_root)
                .unwrap_or(f)
                .display()
                .to_string();
            fetch_info(&format!("[{fetched}/{total}] {url} (cited by {cited_by})"));

            // Re-invoke this binary for each URL with CHEATSHEET_SOURCES_DIR set,
            // mirroring the shell's self-re-invocation, suppressing output.
            let exe = env::current_exe().unwrap_or_else(|_| PathBuf::from("tillandsias-policy"));
            let status = std::process::Command::new(&exe)
                .arg("fetch-cheatsheet-source")
                .arg("--repo-root")
                .arg(&cfg.repo_root)
                .arg(url)
                .arg("--manual-review")
                .env("CHEATSHEET_SOURCES_DIR", &key_dir)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();

            if matches!(status, Ok(s) if s.success()) {
                fetched += 1;
                // Locate the produced file (path mirrors URL host structure).
                let host_part = url.strip_prefix("https://").unwrap_or(url);
                let host = host_part.split('/').next().unwrap_or("");
                let mut path_part = &host_part[host.len()..];
                if let Some(q) = path_part.find('?') {
                    path_part = &path_part[..q];
                }
                if let Some(h) = path_part.find('#') {
                    path_part = &path_part[..h];
                }
                let path_part = path_part.trim_end_matches('/');
                let path_part = if path_part.is_empty() || path_part == "/" {
                    "/index.html"
                } else {
                    path_part
                };
                let mut produced = key_dir.join(format!("{host}{path_part}"));
                let mut sidecar = PathBuf::new();
                let meta = PathBuf::from(format!("{}.meta.yaml", produced.display()));
                let norepublish = PathBuf::from(format!("{}.norepublish", produced.display()));
                let norepublish_meta =
                    PathBuf::from(format!("{}.norepublish.meta.yaml", produced.display()));
                if meta.is_file() {
                    sidecar = meta;
                } else if norepublish_meta.is_file() {
                    sidecar = norepublish_meta;
                    produced = norepublish;
                }
                if sidecar.is_file() && produced.is_file() {
                    let ctype = fs::read_to_string(&sidecar)
                        .ok()
                        .and_then(|s| {
                            s.lines().find_map(|l| {
                                l.strip_prefix("content_type:")
                                    .map(|v| v.trim().to_string())
                            })
                        })
                        .unwrap_or_default();
                    let fp = fetch_structural_drift_fingerprint(&produced, &ctype);
                    fetch_sidecar_set_fingerprint(&sidecar, &fp);
                    fetch_info(&format!("fingerprint: {fp}"));
                }
            } else {
                failed += 1;
                fetch_info(&format!("warning: fetch failed for {url} (continuing)"));
            }
        }
    }

    fetch_info(&format!(
        "bundled-tier bake complete: fetched={fetched} failed={failed} skipped={skipped}"
    ));
    println!("key={key}");
    println!("dir={}", key_dir.display());
}

/// Compute structural-drift fingerprint over <h1>+<h2>+<h3> headings.
/// Non-HTML → "n/a". Mirrors the htmlq-or-Python fallback (we always use the
/// internal heading extractor, which matches the Python html.parser path).
fn fetch_structural_drift_fingerprint(file: &Path, content_type: &str) -> String {
    let is_html =
        if content_type.starts_with("text/html") || content_type.starts_with("application/xhtml") {
            true
        } else if content_type.is_empty() {
            // Sniff first 8192 bytes for an opening html/body/h1/h2/h3 tag.
            match fs::read(file) {
                Ok(bytes) => {
                    let head = &bytes[..bytes.len().min(8192)];
                    let lower = String::from_utf8_lossy(head).to_ascii_lowercase();
                    lower.contains("<html")
                        || lower.contains("<body")
                        || lower.contains("<h1")
                        || lower.contains("<h2")
                        || lower.contains("<h3")
                }
                Err(_) => false,
            }
        } else {
            false
        };
    if !is_html {
        return "n/a".to_string();
    }
    let Ok(bytes) = fs::read(file) else {
        return "n/a".to_string();
    };
    let text = String::from_utf8_lossy(&bytes);
    let parts = extract_headings(&text);
    if parts.is_empty() {
        "n/a".to_string()
    } else {
        let joined = parts.join("\n");
        sha256_hex(joined.as_bytes()).chars().take(16).collect()
    }
}

/// Extract text content of h1/h2/h3 tags in document order, mirroring the
/// Python HTMLParser HeadingExtractor (whitespace-trimmed, empties dropped).
fn extract_headings(html: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let bytes = html.as_bytes();
    let lower = html.to_ascii_lowercase();
    let mut i = 0;
    while i < bytes.len() {
        // Find next heading open tag.
        let Some(rel) = find_heading_open(&lower[i..]) else {
            break;
        };
        let open_start = i + rel;
        // Find end of the open tag '>'.
        let Some(gt_rel) = lower[open_start..].find('>') else {
            break;
        };
        let content_start = open_start + gt_rel + 1;
        // The tag name is h1/h2/h3 at open_start+1.
        let tag = &lower[open_start + 1..open_start + 3];
        let close = format!("</{tag}");
        let Some(close_rel) = lower[content_start..].find(&close) else {
            break;
        };
        let content_end = content_start + close_rel;
        let raw = &html[content_start..content_end];
        let text = strip_tags(raw);
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            parts.push(trimmed.to_string());
        }
        // Advance past the close tag.
        i = content_end + close.len();
    }
    parts
}

/// Find the byte offset of the next `<h1`, `<h2`, or `<h3` followed by `>` or
/// whitespace (mirrors HTMLParser start-tag recognition for those tags).
fn find_heading_open(lower: &str) -> Option<usize> {
    let bytes = lower.as_bytes();
    let mut i = 0;
    while i + 2 < bytes.len() {
        if bytes[i] == b'<'
            && bytes[i + 1] == b'h'
            && (bytes[i + 2] == b'1' || bytes[i + 2] == b'2' || bytes[i + 2] == b'3')
        {
            let after = bytes.get(i + 3).copied();
            if matches!(
                after,
                Some(b'>') | Some(b' ') | Some(b'\t') | Some(b'\n') | Some(b'\r') | Some(b'/')
            ) {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

/// Strip nested HTML tags from heading inner content (Python's handle_data only
/// collects text nodes between start/end of the heading).
fn strip_tags(s: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for ch in s.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    out
}

/// Append or replace `structural_drift_fingerprint:` in a sidecar .meta.yaml.
fn fetch_sidecar_set_fingerprint(sidecar: &Path, fingerprint: &str) {
    let Ok(content) = fs::read_to_string(sidecar) else {
        return;
    };
    if content
        .lines()
        .any(|l| l.starts_with("structural_drift_fingerprint:"))
    {
        let new: String = content
            .lines()
            .map(|l| {
                if l.starts_with("structural_drift_fingerprint:") {
                    format!("structural_drift_fingerprint: {fingerprint}")
                } else {
                    l.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        // Preserve a trailing newline like awk's print output.
        let new = format!("{new}\n");
        let _ = fs::write(sidecar, new);
    } else {
        let mut content = content;
        content.push_str(&format!("structural_drift_fingerprint: {fingerprint}\n"));
        let _ = fs::write(sidecar, content);
    }
}

/// Allowlist field record (publisher, license, redistribution, license_url).
struct AllowlistFields {
    publisher: String,
    license: String,
    redistribution: String,
    license_url: String,
}

/// Port of the allowlist-extraction PYEOF: find `[domains."<key>"]` and read
/// `k = v` lines until the next `[` section.
fn fetch_allowlist_fields(content: &str, key: &str) -> Option<AllowlistFields> {
    let header = format!("[domains.\"{key}\"]\n");
    let start = content.find(&header)? + header.len();
    let section = &content[start..];
    // Up to next "\n[" or end.
    let end = section.find("\n[").map(|p| p + 1).unwrap_or(section.len());
    let section = &section[..end];
    let mut publisher = String::new();
    let mut license = String::new();
    let mut redistribution = String::from("do-not-bundle");
    let mut license_url = String::new();
    for line in section.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            let k = k.trim();
            let v = v.trim().trim_matches('"');
            match k {
                "publisher" => publisher = v.to_string(),
                "license" => license = v.to_string(),
                "redistribution" => redistribution = v.to_string(),
                "license_url" => license_url = v.to_string(),
                _ => {}
            }
        }
    }
    Some(AllowlistFields {
        publisher,
        license,
        redistribution,
        license_url,
    })
}

/// Compute deterministic on-disk path from URL (port of compute_dest_path).
fn fetch_compute_dest_path(sources_dir: &Path, url: &str) -> PathBuf {
    let u = url.strip_prefix("https://").unwrap_or(url);
    let host = u.split('/').next().unwrap_or("");
    let mut path = &u[host.len()..];
    if let Some(q) = path.find('?') {
        path = &path[..q];
    }
    if let Some(h) = path.find('#') {
        path = &path[..h];
    }
    let path = path.trim_end_matches('/');
    let path = if path.is_empty() || path == "/" {
        "/index.html"
    } else {
        path
    };
    sources_dir.join(format!("{host}{path}"))
}

/// Build URL candidates (RFC .txt preference, single-page variants), port of
/// build_url_candidates.
fn fetch_build_url_candidates(base_url: &str, raw_host: &str) -> Vec<String> {
    let mut candidates: Vec<String> = Vec::new();
    if (raw_host.contains("rfc-editor.org") || raw_host.contains("ietf.org"))
        && (base_url.ends_with(".html") || base_url.ends_with(".htm"))
    {
        let txt = base_url
            .strip_suffix(".html")
            .or_else(|| base_url.strip_suffix(".htm"))
            .map(|b| format!("{b}.txt"))
            .unwrap_or_else(|| base_url.to_string());
        candidates.push(txt);
    }
    candidates.push(base_url.to_string());

    // Dedup preserving order.
    let mut seen: Vec<String> = Vec::new();
    let mut final_list: Vec<String> = Vec::new();
    for u in &candidates {
        if !seen.contains(u) {
            final_list.push(u.clone());
            seen.push(u.clone());
        }
    }

    let base_stripped = base_url.split('?').next().unwrap_or(base_url);
    let base_no_slash = base_stripped.trim_end_matches('/');
    for variant in [
        format!("{base_stripped}?print=1"),
        format!("{base_no_slash}/print/"),
        format!("{base_no_slash}/single-page/"),
    ] {
        if !seen.contains(&variant) {
            final_list.push(variant.clone());
            seen.push(variant);
        }
    }
    final_list
}

fn fetch_single_url(
    cfg: &FetchConfig,
    url_in: &str,
    cite_path: &str,
    manual_review: bool,
    force: bool,
) {
    if !url_in.starts_with("https://") {
        fetch_die(&format!("only https:// URLs are allowed (got: {url_in})"));
    }

    let mut url = url_in.to_string();
    let original_url = url_in.to_string();

    // GitHub blob → raw rewrite.
    {
        let u_no_scheme = url.strip_prefix("https://").unwrap_or(&url).to_string();
        let host = u_no_scheme.split('/').next().unwrap_or("").to_string();
        let path = u_no_scheme[host.len()..].to_string();
        if host == "github.com" && path.contains("/blob/") {
            let raw_path = path.replacen("/blob/", "/", 1);
            url = format!("https://raw.githubusercontent.com{raw_path}");
            fetch_info(&format!("GitHub blob → raw rewrite: {url}"));
        }
    }

    // Allowlist lookup.
    if !cfg.allowlist.is_file() {
        fetch_die(&format!(
            "allowlist not found at {}",
            cfg.allowlist.display()
        ));
    }
    let allowlist_content = fs::read_to_string(&cfg.allowlist).unwrap_or_default();

    let u_no_scheme = url.strip_prefix("https://").unwrap_or(&url).to_string();
    let raw_host = u_no_scheme.split('/').next().unwrap_or("").to_string();
    let url_path = u_no_scheme[raw_host.len()..].to_string();

    let mut publisher = String::new();
    let mut license = String::new();
    let mut redistribution = String::new();
    let mut license_url = String::new();
    let mut allowlist_match = String::new();
    let mut found = false;

    // Try host + first {3,2,1,0} path segments (most specific first).
    for depth in [3usize, 2, 1, 0] {
        let mut candidate = raw_host.clone();
        if depth > 0 && !url_path.is_empty() {
            let trimmed = url_path.trim_start_matches('/');
            let segs: Vec<&str> = trimmed
                .split('/')
                .filter(|s| !s.is_empty())
                .take(depth)
                .collect();
            if !segs.is_empty() {
                candidate = format!("{raw_host}/{}", segs.join("/"));
            }
        }
        let header = format!("[domains.\"{candidate}\"]");
        if allowlist_content.contains(&header) {
            if let Some(f) = fetch_allowlist_fields(&allowlist_content, &candidate) {
                publisher = f.publisher;
                license = f.license;
                redistribution = f.redistribution;
                license_url = f.license_url;
            }
            allowlist_match = candidate;
            found = true;
            break;
        }
    }

    if !found {
        if !manual_review {
            fetch_die(&format!(
                "host '{raw_host}' is not in the license allowlist.\nPass --manual-review to fetch anyway (redistribution will be marked 'manual-review-required').\nAdd the domain to {} to suppress this warning.",
                cfg.allowlist.display()
            ));
        }
        publisher = "unknown".to_string();
        license = "unknown".to_string();
        redistribution = "manual-review-required".to_string();
        license_url = String::new();
        allowlist_match = String::new();
        fetch_info("warning: domain not in allowlist; proceeding with --manual-review");
    }

    let mut dest_path = fetch_compute_dest_path(&cfg.sources_dir, &url);
    let norepublish = PathBuf::from(format!("{}.norepublish", dest_path.display()));
    let skip_fetch = (dest_path.is_file() || norepublish.is_file()) && !force;
    if skip_fetch {
        fetch_info(&format!(
            "already fetched: {} (use --force to re-fetch)",
            dest_path.display()
        ));
    }

    let mut fetch_url = url.clone();
    let mut final_url = url.clone();
    let mut http_status = String::from("0");
    let mut content_type = String::new();

    if !skip_fetch {
        println!("fetching: {url}");
        let candidates = fetch_build_url_candidates(&url, &raw_host);
        let tmp_body =
            env::temp_dir().join(format!("tillandsias-fetch-body-{}", std::process::id()));
        let mut tried: Vec<String> = Vec::new();
        let mut got = false;
        for candidate_url in &candidates {
            tried.push(candidate_url.clone());
            fetch_info(&format!("trying: {candidate_url}"));
            let output = std::process::Command::new("curl")
                .args([
                    "-L",
                    "--proto",
                    "=https",
                    "--tlsv1.2",
                    "-A",
                    &cfg.user_agent,
                    "--max-time",
                    "60",
                    "--connect-timeout",
                    "15",
                    "--max-redirs",
                    "5",
                    "--write-out",
                    "%{http_code}\n%{url_effective}\n%{content_type}",
                    "--silent",
                    "--output",
                ])
                .arg(&tmp_body)
                .arg("--dump-header")
                .arg(env::temp_dir().join(format!("tillandsias-fetch-hdr-{}", std::process::id())))
                .arg(candidate_url)
                .output();
            let Ok(output) = output else {
                fetch_info(&format!("curl failed for {candidate_url}; trying next"));
                continue;
            };
            if !output.status.success() {
                fetch_info(&format!("curl failed for {candidate_url}; trying next"));
                continue;
            }
            let writeout = String::from_utf8_lossy(&output.stdout);
            let lines: Vec<&str> = writeout.lines().collect();
            let n = lines.len();
            let status_line = if n >= 3 { lines[n - 3] } else { "" };
            let effective = if n >= 2 { lines[n - 2] } else { "" };
            let ctype = if n >= 1 { lines[n - 1] } else { "" };
            http_status = status_line.to_string();
            let body_len = fs::metadata(&tmp_body).map(|m| m.len()).unwrap_or(0);
            if http_status == "200" && body_len > 0 {
                content_type = ctype.to_string();
                fetch_url = candidate_url.clone();
                final_url = effective.to_string();
                fetch_info(&format!(
                    "fetched {http_status}: {final_url} ({body_len} bytes)"
                ));
                got = true;
                break;
            } else {
                fetch_info(&format!(
                    "  → HTTP {http_status} or empty body; trying next"
                ));
            }
        }
        if !got {
            let _ = fs::remove_file(&tmp_body);
            fetch_die(&format!(
                "all URL candidates failed or returned empty body for {url}\nTried: {}",
                tried.join(" ")
            ));
        }

        // Recompute dest for the URL that actually succeeded.
        dest_path = fetch_compute_dest_path(&cfg.sources_dir, &fetch_url);
        if let Some(parent) = dest_path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if redistribution == "do-not-bundle" || redistribution == "manual-review-required" {
            dest_path = PathBuf::from(format!("{}.norepublish", dest_path.display()));
        }
        if let Ok(bytes) = fs::read(&tmp_body) {
            let _ = fs::write(&dest_path, bytes);
        }
        let _ = fs::remove_file(&tmp_body);
        fetch_info(&format!("stored: {}", dest_path.display()));
    } else {
        if norepublish.is_file() {
            dest_path = norepublish;
        }
        fetch_url = url.clone();
        final_url = url.clone();
        let meta = PathBuf::from(format!("{}.meta.yaml", dest_path.display()));
        if meta.is_file() {
            let content = fs::read_to_string(&meta).unwrap_or_default();
            http_status = content
                .lines()
                .find_map(|l| l.strip_prefix("http_status:").map(|v| v.trim().to_string()))
                .unwrap_or_else(|| "200".to_string());
            content_type = content
                .lines()
                .find_map(|l| {
                    l.strip_prefix("content_type:")
                        .map(|v| v.trim().to_string())
                })
                .unwrap_or_default();
        } else {
            http_status = "200".to_string();
            content_type = String::new();
        }
    }

    // SHA-256 + length.
    let mut content_sha256 = String::new();
    let mut content_length: u64 = 0;
    if dest_path.is_file()
        && let Ok(bytes) = fs::read(&dest_path)
    {
        content_sha256 = sha256_hex(&bytes);
        content_length = bytes.len() as u64;
    }

    // Write sidecar.
    let fetch_ts = fetch_utc_timestamp();
    let meta_path = PathBuf::from(format!("{}.meta.yaml", dest_path.display()));

    // Read existing cited_by (idempotent) — port of cited_by PYEOF.
    let mut cited_by_list: Vec<String> = Vec::new();
    if meta_path.is_file() {
        let content = fs::read_to_string(&meta_path).unwrap_or_default();
        cited_by_list = fetch_extract_cited_by(&content);
    }

    if !cite_path.is_empty() {
        let cite_norm = cite_path
            .strip_prefix(&format!("{}/", cfg.repo_root.display()))
            .unwrap_or(cite_path)
            .to_string();
        if !cited_by_list.iter().any(|e| e == &cite_norm) {
            cited_by_list.push(cite_norm);
        }
    }

    let cited_by_yaml = if cited_by_list.is_empty() {
        "cited_by:\n  []".to_string()
    } else {
        let mut s = String::from("cited_by:");
        for item in &cited_by_list {
            s.push_str(&format!("\n  - {item}"));
        }
        s
    };

    let render = "static";
    // local_path relative to repo root (bash: ${DEST_PATH#${REPO_ROOT}/}).
    let local_path = strip_repo_prefix(&dest_path, &cfg.repo_root);

    let sidecar_text = format!(
        "url: {original_url}\nfetch_url: {fetch_url}\nfinal_redirect: {final_url}\nfetched: {fetch_ts}\nfetcher_version: {FETCHER_VERSION}\ncontent_sha256: {content_sha256}\ncontent_length: {content_length}\ncontent_type: {content_type}\nhttp_status: {http_status}\npublisher: {publisher}\nlicense: {license}\nlicense_url: {license_url}\nredistribution: {redistribution}\nallowlist_match: {allowlist_match}\nrender: {render}\nlocal_path: {local_path}\n{cited_by_yaml}\nnotes: \"\"\n"
    );
    let _ = fs::write(&meta_path, &sidecar_text);
    fetch_info(&format!("sidecar: {}", meta_path.display()));

    // --cite: append local: line to the cheatsheet's ## Provenance section.
    if !cite_path.is_empty() {
        let cheatsheet_abs = if cite_path.starts_with('/') {
            PathBuf::from(cite_path)
        } else if cite_path.starts_with("cheatsheets/") {
            cfg.repo_root.join(cite_path)
        } else {
            cfg.repo_root.join("cheatsheets").join(cite_path)
        };
        if !cheatsheet_abs.is_file() {
            eprintln!(
                "warning: cheatsheet not found at {}; skipping --cite",
                cheatsheet_abs.display()
            );
        } else {
            let local_cite_path = strip_repo_prefix(&dest_path, &cfg.repo_root);
            let source_url = fetch_url.clone();
            let content = fs::read_to_string(&cheatsheet_abs).unwrap_or_default();
            if content.contains(&format!("local: `{local_cite_path}")) {
                fetch_info(&format!("already cited in {}", cheatsheet_abs.display()));
            } else {
                let (new_content, inserted) =
                    fetch_insert_local_line(&content, &source_url, &original_url, &local_cite_path);
                let _ = fs::write(&cheatsheet_abs, &new_content);
                if inserted {
                    eprintln!("  → inserted local: line into {}", cheatsheet_abs.display());
                } else {
                    eprintln!(
                        "  warning: could not find insertion point in {}; please add manually:",
                        cheatsheet_abs.display()
                    );
                    eprintln!("    local: `{local_cite_path}`");
                }
                fetch_info(&format!(
                    "updated provenance in: {}",
                    cheatsheet_abs.display()
                ));
            }
        }
    }

    // Regenerate INDEX.json via regenerate-source-index.sh if executable.
    let regen = cfg.scripts_dir.join("regenerate-source-index.sh");
    if fetch_is_executable(&regen) {
        let _ = std::process::Command::new(&regen).status();
    } else {
        fetch_info(
            "warning: regenerate-source-index.sh not found or not executable; INDEX.json not updated",
        );
    }

    println!("done: {url}");
}

/// Bash `${path#${repo_root}/}` — strip the repo-root prefix if present,
/// otherwise return the path unchanged (as a display string).
fn strip_repo_prefix(path: &Path, repo_root: &Path) -> String {
    let p = path.display().to_string();
    let prefix = format!("{}/", repo_root.display());
    p.strip_prefix(&prefix).map(|s| s.to_string()).unwrap_or(p)
}

fn fetch_is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path)
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

fn fetch_utc_timestamp() -> String {
    // date -u +"%Y-%m-%dT%H:%M:%SZ" via the system `date` for byte-parity.
    let out = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::new(),
    }
}

/// Port of the cited_by PYEOF: extract items from a `cited_by:\n  - ...` block.
fn fetch_extract_cited_by(content: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut in_block = false;
    for line in content.lines() {
        if line == "cited_by:" {
            in_block = true;
            continue;
        }
        if in_block {
            if let Some(rest) = line.strip_prefix("  - ") {
                items.push(rest.to_string());
            } else {
                break;
            }
        }
    }
    items
}

/// Port of the provenance-insertion PYEOF. Returns (new_content, inserted).
fn fetch_insert_local_line(
    content: &str,
    source_url: &str,
    original_url: &str,
    local_path: &str,
) -> (String, bool) {
    let local_line = format!("  local: `{local_path}`");

    // If already present, return unchanged.
    if content
        .lines()
        .any(|l| l.contains(&format!("local: `{local_path}`")))
    {
        return (content.to_string(), false);
    }

    // splitlines(keepends=True): preserve line endings.
    let lines = split_keepends(content);
    let mut new_lines: Vec<String> = Vec::new();
    let mut inserted = false;
    let mut in_provenance = false;

    for line in &lines {
        new_lines.push(line.clone());
        let bare = line.trim_end_matches(['\n', '\r']);
        if regen_is_h2_provenance(bare) {
            in_provenance = true;
            continue;
        }
        if in_provenance && regen_is_h2(bare) {
            in_provenance = false;
            continue;
        }
        if in_provenance && !inserted {
            let stripped = bare.trim();
            if stripped.contains(source_url) || stripped.contains(original_url) {
                new_lines.push(format!("{local_line}\n"));
                inserted = true;
            }
        }
    }

    if !inserted && in_provenance {
        let mut out: Vec<String> = Vec::new();
        for line in &new_lines {
            if line.contains("**Last updated:**") && !inserted {
                out.push(format!("{local_line}\n"));
                inserted = true;
            }
            out.push(line.clone());
        }
        new_lines = out;
    }

    if !inserted {
        let mut out: Vec<String> = Vec::new();
        let mut in_prov = false;
        for line in &new_lines {
            let bare = line.trim_end_matches(['\n', '\r']);
            if regen_is_h2_provenance(bare) {
                in_prov = true;
            }
            if in_prov && line.contains("**Last updated:**") && !inserted {
                out.push(format!("{local_line}\n"));
                inserted = true;
            }
            out.push(line.clone());
        }
        new_lines = out;
    }

    (new_lines.join(""), inserted)
}

/// Python str.splitlines(keepends=True) over \n (sufficient for our inputs).
fn split_keepends(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for ch in s.chars() {
        cur.push(ch);
        if ch == '\n' {
            out.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

// ===========================================================================
// regenerate-cheatsheet-index — rebuild cheatsheets/INDEX.md from frontmatter.
//
// Faithful Rust port of scripts/regenerate-cheatsheet-index.sh (the script's
// only python3 use was the INDEX.json verify-marker lookup table).
//
// @trace spec:cheatsheet-tooling, spec:cheatsheet-source-layer
// @trace spec:cheatsheets-license-tiered
// ===========================================================================

const REGEN_INDEX_HEADER: &str = "# Cheatsheets Index\n\n@trace spec:cheatsheet-tooling, spec:cheatsheet-source-layer\n\n> AUTO-GENERATED by `scripts/regenerate-cheatsheet-index.sh`. Do NOT hand-edit.\n> Source of truth = the YAML frontmatter on each cheatsheet file.\n> To refresh: `scripts/regenerate-cheatsheet-index.sh`.\n\nCurated reference for tools, languages, and runtimes shipped with the Tillandsias forge. Optimised for `cat | rg`: one line per cheatsheet, `<filename> — <one-line description>`.\n\n**Discovery**: agents inside the forge find cheatsheets at `$TILLANDSIAS_CHEATSHEETS/INDEX.md` (resolves to `/opt/cheatsheets/INDEX.md`). Humans read them on GitHub.\n\n**Authoring**: copy `cheatsheets/TEMPLATE.md` into the right category subdirectory, fill the YAML frontmatter (`tags`, `since`, `last_verified`, `sources`, `authority`, `status`), then run `scripts/regenerate-cheatsheet-index.sh` to refresh this file.\n";

/// Parsed result of one cheatsheet's frontmatter+body, mirroring the awk
/// `parse_cheatsheet` emitter (7 \x1f-separated fields).
struct CheatsheetParse {
    status: String,
    title: String,
    description: String,
    tier: String,
    image_baked_sha256: String,
    package: String,
    committed_for_project: String,
}

/// Faithful port of the awk `parse_cheatsheet` function in the shell script.
fn regen_parse_cheatsheet(text: &str) -> CheatsheetParse {
    let mut in_fm = false;
    let mut saw_fm_open = false;
    let mut saw_fm_close = false;
    let mut status = String::from("none");
    let mut title = String::new();
    let mut description = String::new();
    let mut second_line = String::new();
    let mut use_when_next = false;
    let mut nonempty_body_count = 0u32;
    let mut tier = String::new();
    let mut image_baked_sha256 = String::new();
    let mut package = String::new();
    let mut committed_for_project = String::new();

    for (idx, line) in text.lines().enumerate() {
        let line_no = idx + 1;

        // Frontmatter open: only if --- is on line 1.
        if line_no == 1 && line == "---" {
            in_fm = true;
            saw_fm_open = true;
            continue;
        }
        // Frontmatter close.
        if in_fm && line == "---" {
            in_fm = false;
            saw_fm_close = true;
            continue;
        }
        if in_fm {
            if let Some(v) = awk_match_capture(line, "status:", |c| c.is_ascii_alphabetic()) {
                status = v.to_ascii_lowercase();
            }
            if let Some(v) =
                awk_match_capture(line, "tier:", |c| c.is_ascii_alphabetic() || c == '-')
            {
                tier = v;
            }
            if let Some(v) =
                awk_match_capture(line, "image_baked_sha256:", |c| c.is_ascii_hexdigit())
            {
                image_baked_sha256 = v;
            }
            if let Some(v) = awk_match_capture(line, "package:", |c| {
                c.is_ascii_alphanumeric() || c == '_' || c == '-'
            }) {
                package = v;
            }
            if let Some(rest) = line.strip_prefix("committed_for_project:") {
                let t = rest.trim_start();
                if let Some(v) = t.strip_prefix("true") {
                    if v.is_empty() || !v.starts_with(|c: char| c.is_ascii_alphanumeric()) {
                        committed_for_project = "true".to_string();
                    }
                } else if let Some(v) = t.strip_prefix("false")
                    && (v.is_empty() || !v.starts_with(|c: char| c.is_ascii_alphanumeric()))
                {
                    committed_for_project = "false".to_string();
                }
            }
            continue;
        }

        // Body parsing.

        // First H1 -> title.
        if title.is_empty()
            && let Some(rest) = match_h1(line)
        {
            title = rest.to_string();
            continue;
        }

        if description.is_empty() {
            // Inline form: `**Use when**: blah`
            if let Some(rest) = match_use_when_inline(line) {
                description = rest.to_string();
            }
            // Heading form: `## Use when` -> next non-empty line is desc.
            else if is_use_when_heading(line) {
                use_when_next = true;
            } else if use_when_next && !line.trim().is_empty() {
                description = line.to_string();
                use_when_next = false;
            }
        }

        // Track second non-empty body line as fallback description.
        if !line.trim().is_empty() {
            nonempty_body_count += 1;
            if nonempty_body_count == 2 && second_line.is_empty() {
                second_line = line.to_string();
            }
        }
    }

    if description.is_empty() {
        description = second_line;
    }
    description = description.trim().to_string();

    if saw_fm_open && !saw_fm_close {
        status = "none".to_string();
    }
    if !saw_fm_open {
        status = "none".to_string();
    }

    CheatsheetParse {
        status,
        title,
        description,
        tier,
        image_baked_sha256,
        package,
        committed_for_project,
    }
}

/// Mirror awk `match($0, /^key:[[:space:]]*(<charclass>+)/, m)`: requires the
/// line to start with `key`, then optional whitespace, then capture the maximal
/// run of characters matching `pred` (must be at least one char to "match").
fn awk_match_capture(line: &str, key: &str, pred: impl Fn(char) -> bool) -> Option<String> {
    let rest = line.strip_prefix(key)?;
    let rest = rest.trim_start_matches([' ', '\t']);
    let captured: String = rest.chars().take_while(|&c| pred(c)).collect();
    if captured.is_empty() {
        None
    } else {
        Some(captured)
    }
}

/// awk `/^#[[:space:]]+(.*)/` — H1 line: `#` then >=1 space, capture the rest.
fn match_h1(line: &str) -> Option<&str> {
    let rest = line.strip_prefix('#')?;
    if rest.starts_with([' ', '\t']) {
        Some(rest.trim_start_matches([' ', '\t']))
    } else {
        None
    }
}

/// awk `/^\*\*Use when\*\*:[[:space:]]*(.+)/` — capture must be non-empty (.+).
fn match_use_when_inline(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("**Use when**:")?;
    let rest = rest.trim_start_matches([' ', '\t']);
    if rest.is_empty() { None } else { Some(rest) }
}

/// awk `/^##[[:space:]]+Use when[[:space:]]*$/`.
fn is_use_when_heading(line: &str) -> bool {
    let Some(rest) = line.strip_prefix("##") else {
        return false;
    };
    if !rest.starts_with([' ', '\t']) {
        return false;
    }
    let rest = rest.trim_start_matches([' ', '\t']);
    let Some(rest) = rest.strip_prefix("Use when") else {
        return false;
    };
    rest.chars().all(|c| c == ' ' || c == '\t')
}

/// Faithful port of the awk `truncate_desc` function: trim, strip a leading
/// `**bold**:` marker, collapse internal whitespace, cap at `max` chars
/// (replacing with `<max-1 chars>…` when longer). Char-based to match gawk in
/// a UTF-8 locale.
fn regen_truncate_desc(s: &str, max: usize) -> String {
    let mut s = s.trim().to_string();
    // sub(/^\*\*[^*]+\*\*:[[:space:]]*/, "", s) — leading bold marker.
    if let Some(after_open) = s.strip_prefix("**")
        && let Some(close_idx) = after_open.find("**")
    {
        let inner = &after_open[..close_idx];
        let tail = &after_open[close_idx + 2..];
        if !inner.contains('*')
            && !inner.is_empty()
            && let Some(rest) = tail.strip_prefix(':')
        {
            s = rest.trim_start_matches([' ', '\t']).to_string();
        }
    }
    // gsub(/[[:space:]]+/, " ", s) — collapse all whitespace runs to one space.
    let collapsed = collapse_whitespace(&s);
    let chars: Vec<char> = collapsed.chars().collect();
    if chars.len() > max {
        let prefix: String = chars[..max - 1].iter().collect();
        format!("{prefix}…")
    } else {
        collapsed
    }
}

fn collapse_whitespace(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_ws = false;
    for ch in s.chars() {
        if ch.is_whitespace() {
            if !in_ws {
                out.push(' ');
                in_ws = true;
            }
        } else {
            out.push(ch);
            in_ws = false;
        }
    }
    out
}

/// One rendered row: (rel_path, marker, desc_with_verify_marker).
struct RegenRow {
    rel: String,
    marker: String,
    desc: String,
}

/// Build the verify-marker lookup table from cheatsheet-sources/INDEX.json.
/// Maps repo-relative cheatsheet path -> marker string ("verified:<sha8>",
/// "partial-verify", or "" for none). Faithful port of the VERIFY_PYEOF block.
fn regen_build_verify_lookup(
    repo_root: &Path,
    cheatsheets_dir: &Path,
    sources_index: &Path,
) -> std::collections::HashMap<String, String> {
    let mut lookup = std::collections::HashMap::new();
    let Ok(index_text) = fs::read_to_string(sources_index) else {
        return lookup;
    };
    let Ok(index): Result<serde_json::Value, _> = serde_json::from_str(&index_text) else {
        return lookup;
    };
    let empty = Vec::new();
    let entries = index
        .get("entries")
        .and_then(|e| e.as_array())
        .unwrap_or(&empty);

    // url -> entry (first wins), over keys url, fetch_url, final_redirect.
    let mut url_to_entry: std::collections::HashMap<String, &serde_json::Value> =
        std::collections::HashMap::new();
    for entry in entries {
        for key in ["url", "fetch_url", "final_redirect"] {
            if let Some(u) = entry.get(key).and_then(|v| v.as_str())
                && !u.is_empty()
            {
                url_to_entry.entry(u.to_string()).or_insert(entry);
            }
        }
    }

    let mut files = Vec::new();
    collect_markdown_files(cheatsheets_dir, &mut files);
    files.retain(|f| {
        !matches!(
            f.file_name().and_then(|n| n.to_str()),
            Some("INDEX.md") | Some("TEMPLATE.md")
        )
    });
    locale_sort_by(&mut files, |p| p.display().to_string());

    for cs_file in files {
        let rel = cs_file
            .strip_prefix(repo_root)
            .unwrap_or(&cs_file)
            .display()
            .to_string();
        let Ok(text) = fs::read_to_string(&cs_file) else {
            continue;
        };
        let (urls, _local_paths) = regen_extract_provenance_info(&text);
        if urls.is_empty() {
            lookup.insert(rel, String::new());
            continue;
        }
        let fetched: Vec<&serde_json::Value> = urls
            .iter()
            .filter_map(|u| url_to_entry.get(u).copied())
            .collect();
        let unfetched_count = urls
            .iter()
            .filter(|u| !url_to_entry.contains_key(*u))
            .count();
        if fetched.is_empty() {
            lookup.insert(rel, String::new());
            continue;
        }
        if unfetched_count > 0 {
            lookup.insert(rel, "partial-verify".to_string());
        } else {
            let mut sha_prefix = String::new();
            for entry in &fetched {
                if let Some(sha) = entry.get("content_sha256").and_then(|v| v.as_str())
                    && !sha.is_empty()
                {
                    sha_prefix = sha.chars().take(8).collect();
                    break;
                }
            }
            if sha_prefix.is_empty() {
                lookup.insert(rel, "partial-verify".to_string());
            } else {
                lookup.insert(rel, format!("verified:{sha_prefix}"));
            }
        }
    }
    lookup
}

/// Port of the Python `extract_provenance_info`: scan the `## Provenance`
/// section for URLs (both `<https://...>` and bare https tokens) and
/// `local: \`...\`` paths.
fn regen_extract_provenance_info(text: &str) -> (Vec<String>, Vec<String>) {
    let mut urls: Vec<String> = Vec::new();
    let mut local_paths: Vec<String> = Vec::new();
    let mut in_provenance = false;
    for line in text.lines() {
        let stripped = line.trim();
        if regen_is_h2_provenance(stripped) {
            in_provenance = true;
            continue;
        }
        if in_provenance && regen_is_h2(stripped) {
            in_provenance = false;
            continue;
        }
        if !in_provenance {
            continue;
        }
        // <https://...>
        let mut rest = stripped;
        while let Some(open) = rest.find("<https://") {
            let after = &rest[open + 1..];
            if let Some(close) = after.find('>') {
                let url = &after[..close];
                urls.push(url.to_string());
                rest = &after[close + 1..];
            } else {
                break;
            }
        }
        // Bare https tokens not preceded by < or ` and trimmed of .,) suffixes.
        for bare in regen_bare_https(stripped) {
            if !urls.contains(&bare) {
                urls.push(bare);
            }
        }
        // local: `path`
        if let Some(pos) = stripped.find("local:") {
            let after = &stripped[pos + "local:".len()..];
            let after = after.trim_start_matches([' ', '\t']);
            if let Some(rest) = after.strip_prefix('`')
                && let Some(end) = rest.find('`')
            {
                local_paths.push(rest[..end].to_string());
            }
        }
    }
    (urls, local_paths)
}

fn regen_is_h2(s: &str) -> bool {
    if let Some(rest) = s.strip_prefix("##") {
        rest.starts_with([' ', '\t'])
    } else {
        false
    }
}

fn regen_is_h2_provenance(s: &str) -> bool {
    if let Some(rest) = s.strip_prefix("##") {
        let rest = rest.trim_start_matches([' ', '\t']);
        rest.starts_with("Provenance")
    } else {
        false
    }
}

/// Mirror the Python `(?<![<`])(https://\S+?)(?:[,\s>)]|$)` finditer, then
/// `.rstrip('.,)')`. Returns bare https tokens NOT immediately preceded by
/// `<` or a backtick.
fn regen_bare_https(s: &str) -> Vec<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut search_from = 0;
    while let Some(rel) = s[search_from..].find("https://") {
        let start = search_from + rel;
        // Negative lookbehind for `<` or backtick.
        let preceded_bad = start > 0 && (bytes[start - 1] == b'<' || bytes[start - 1] == b'`');
        // Find the minimal run up to a terminator [,\s>)] or end of string.
        let tail = &s[start..];
        let mut end_off = tail.len();
        for (i, ch) in tail.char_indices() {
            if i == 0 {
                continue;
            }
            if ch == ',' || ch.is_whitespace() || ch == '>' || ch == ')' {
                end_off = i;
                break;
            }
        }
        let token = &tail[..end_off];
        let trimmed = token.trim_end_matches(['.', ',', ')']);
        if !preceded_bad && !trimmed.is_empty() {
            out.push(trimmed.to_string());
        }
        search_from = start + 8; // advance past "https://"
    }
    out
}

fn regenerate_cheatsheet_index(args: &[String]) {
    let mut check_mode = false;
    let mut repo_root = env::current_dir().unwrap_or_else(|err| {
        eprintln!("failed to read current dir: {err}");
        process::exit(2);
    });

    let mut idx = 0;
    while idx < args.len() {
        match args[idx].as_str() {
            "--check" => check_mode = true,
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
                eprintln!("usage: regenerate-cheatsheet-index.sh [--check]");
                process::exit(2);
            }
        }
        idx += 1;
    }

    let cheatsheets_dir = repo_root.join("cheatsheets");
    let index_file = cheatsheets_dir.join("INDEX.md");
    if !cheatsheets_dir.is_dir() {
        eprintln!(
            "error: cheatsheets directory not found at {}",
            cheatsheets_dir.display()
        );
        process::exit(2);
    }

    let sources_index = repo_root.join("cheatsheet-sources/INDEX.json");
    let verify_lookup = if sources_index.is_file() {
        regen_build_verify_lookup(&repo_root, &cheatsheets_dir, &sources_index)
    } else {
        std::collections::HashMap::new()
    };

    let rendered = regen_render_index(&cheatsheets_dir, &verify_lookup);

    if check_mode {
        if !index_file.is_file() {
            eprintln!("check: {} does not exist", index_file.display());
            process::exit(1);
        }
        let current = fs::read_to_string(&index_file).unwrap_or_default();
        if current != rendered {
            eprintln!(
                "check: {} is out of date — run scripts/regenerate-cheatsheet-index.sh",
                index_file.display()
            );
            process::exit(1);
        }
        return;
    }

    let current = fs::read_to_string(&index_file).ok();
    if current.as_deref() == Some(rendered.as_str()) {
        println!("INDEX.md unchanged.");
    } else {
        if let Err(err) = fs::write(&index_file, &rendered) {
            eprintln!("error: failed to write {}: {err}", index_file.display());
            process::exit(1);
        }
        println!("INDEX.md regenerated: {}", index_file.display());
    }
}

/// Render one cheatsheet file into an optional row (None = deprecated/hidden).
fn regen_process_file(
    file: &Path,
    sub: &str,
    verify_lookup: &std::collections::HashMap<String, String>,
) -> Option<RegenRow> {
    let fname = file.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let rel = if sub.is_empty() {
        fname.to_string()
    } else {
        format!("{sub}/{fname}")
    };

    let text = fs::read_to_string(file).unwrap_or_default();
    let parsed = regen_parse_cheatsheet(&text);

    if parsed.status == "deprecated" {
        return None;
    }

    let marker = match parsed.status.as_str() {
        "current" => "",
        "stale" => "[STALE]",
        _ => "[DRAFT]", // draft | none | anything else
    };

    // Verify marker lookup keyed by cheatsheets/<category>/[sub/]<filename>.
    let category_path = file
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("");
    let category_rel = if sub.is_empty() {
        format!("cheatsheets/{category_path}/{fname}")
    } else {
        format!("cheatsheets/{category_path}/{sub}/{fname}")
    };

    let mut verify_marker = String::new();
    if !verify_lookup.is_empty() {
        // The shell does `grep -F "${category_rel}"` then takes the first
        // match's field — i.e. a substring match. Reproduce: first key that
        // contains category_rel (sorted for determinism, matching file order).
        let mut keys: Vec<String> = verify_lookup.keys().cloned().collect();
        locale_sort_by(&mut keys, |k| k.clone());
        if let Some(k) = keys.into_iter().find(|k| k.contains(&category_rel)) {
            let raw = &verify_lookup[&k];
            if let Some(sha) = raw.strip_prefix("verified:") {
                verify_marker = format!(" [verified: {sha}]");
            } else if raw == "partial-verify" {
                verify_marker = " [partial-verify]".to_string();
            }
        }
    }

    // Tier badges supersede the legacy verify_marker when tier is set.
    let tier_marker = match parsed.tier.as_str() {
        "bundled" => {
            if !parsed.image_baked_sha256.is_empty() {
                let prefix: String = parsed.image_baked_sha256.chars().take(8).collect();
                Some(format!(" [bundled, verified: {prefix}]"))
            } else {
                Some(" [bundled, partial-verify]".to_string())
            }
        }
        "distro-packaged" => {
            if !parsed.package.is_empty() {
                Some(format!(" [distro-packaged: {}]", parsed.package))
            } else {
                Some(" [distro-packaged: MISSING]".to_string())
            }
        }
        "pull-on-demand" => {
            if parsed.committed_for_project == "true" {
                Some(" [pull-on-demand: project-committed]".to_string())
            } else {
                Some(" [pull-on-demand: stub]".to_string())
            }
        }
        _ => None,
    };
    if let Some(tm) = tier_marker {
        verify_marker = tm;
    }

    let description = if parsed.description.is_empty() {
        parsed.title.clone()
    } else {
        parsed.description.clone()
    };
    let desc = regen_truncate_desc(&description, 80);

    Some(RegenRow {
        rel,
        marker: marker.to_string(),
        desc: format!("{desc}{verify_marker}"),
    })
}

/// Sort `items` by the locale collation that the system `sort` binary uses
/// (the shell pipes `find` output through `sort`/`sort -z`). We defer to the
/// real `sort` binary so the result is byte-for-byte identical to the shell
/// regardless of how glibc collation orders punctuation like `-` vs `.`. The
/// `key` closure yields the string `sort` would see for each item. Falls back
/// to a stable Rust sort if the `sort` binary is unavailable.
fn locale_sort_by<T, F>(items: &mut Vec<T>, key: F)
where
    T: Clone,
    F: Fn(&T) -> String,
{
    use std::io::Write;
    if items.len() < 2 {
        return;
    }
    // Map key -> list of items (handles duplicate keys deterministically).
    let mut buckets: std::collections::HashMap<String, std::collections::VecDeque<T>> =
        std::collections::HashMap::new();
    let mut input = Vec::new();
    for item in items.iter() {
        let k = key(item);
        input.extend_from_slice(k.as_bytes());
        input.push(0);
        buckets.entry(k).or_default().push_back(item.clone());
    }

    let child = std::process::Command::new("sort")
        .arg("-z")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn();

    let Ok(mut child) = child else {
        // Fallback: byte-wise sort by key.
        items.sort_by_key(|a| key(a));
        return;
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(&input);
    }
    let Ok(output) = child.wait_with_output() else {
        items.sort_by_key(|a| key(a));
        return;
    };
    if !output.status.success() {
        items.sort_by_key(|a| key(a));
        return;
    }

    let mut sorted: Vec<T> = Vec::with_capacity(items.len());
    for part in output.stdout.split(|&b| b == 0) {
        if part.is_empty() {
            continue;
        }
        let k = String::from_utf8_lossy(part).to_string();
        if let Some(bucket) = buckets.get_mut(&k)
            && let Some(item) = bucket.pop_front()
        {
            sorted.push(item);
        }
    }
    // Safety: only replace if we recovered every item.
    if sorted.len() == items.len() {
        *items = sorted;
    } else {
        items.sort_by_key(|a| key(a));
    }
}

/// Build the full INDEX.md text (post canonicalisation), matching the shell.
fn regen_render_index(
    cheatsheets_dir: &Path,
    verify_lookup: &std::collections::HashMap<String, String>,
) -> String {
    let mut out = String::new();
    out.push_str(REGEN_INDEX_HEADER);
    out.push('\n');

    // Categories = immediate subdirectories, sorted by name.
    let mut categories: Vec<PathBuf> = Vec::new();
    if let Ok(entries) = fs::read_dir(cheatsheets_dir) {
        for entry in entries.flatten() {
            if entry.path().is_dir() {
                categories.push(entry.path());
            }
        }
    }
    // Categories: `find -printf '%f\n' | sort` — sort by basename using the
    // system locale collation (matches the committed INDEX.md exactly).
    locale_sort_by(&mut categories, |p| {
        p.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string()
    });

    for category in &categories {
        let category_name = category.file_name().and_then(|n| n.to_str()).unwrap_or("");
        let mut rows: Vec<RegenRow> = Vec::new();

        // Files directly under cheatsheets/<category>/, sorted by path.
        let mut direct: Vec<PathBuf> = Vec::new();
        if let Ok(entries) = fs::read_dir(category) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("md") {
                    direct.push(p);
                }
            }
        }
        // `find ... -print0 | sort -z` sorts by full path with locale collation.
        locale_sort_by(&mut direct, |p| p.display().to_string());
        for file in &direct {
            if let Some(row) = regen_process_file(file, "", verify_lookup) {
                rows.push(row);
            }
        }

        // Files one level deeper: cheatsheets/<category>/<sub>/*.md, subdirs sorted.
        let mut subdirs: Vec<PathBuf> = Vec::new();
        if let Ok(entries) = fs::read_dir(category) {
            for entry in entries.flatten() {
                if entry.path().is_dir() {
                    subdirs.push(entry.path());
                }
            }
        }
        locale_sort_by(&mut subdirs, |p| p.display().to_string());
        for subdir in &subdirs {
            let sub = subdir.file_name().and_then(|n| n.to_str()).unwrap_or("");
            let mut subfiles: Vec<PathBuf> = Vec::new();
            if let Ok(entries) = fs::read_dir(subdir) {
                for entry in entries.flatten() {
                    let p = entry.path();
                    if p.is_file() && p.extension().and_then(|e| e.to_str()) == Some("md") {
                        subfiles.push(p);
                    }
                }
            }
            locale_sort_by(&mut subfiles, |p| p.display().to_string());
            for file in &subfiles {
                if let Some(row) = regen_process_file(file, sub, verify_lookup) {
                    rows.push(row);
                }
            }
        }

        // Section header.
        out.push_str(&format!("## {category_name}\n"));
        out.push('\n');
        if rows.is_empty() {
            out.push_str("(empty)\n");
        } else {
            // Compute longest "<path> [MARKER]" so descriptions align.
            let mut max_left = 0usize;
            for row in &rows {
                let width = if row.marker.is_empty() {
                    row.rel.chars().count()
                } else {
                    row.rel.chars().count() + 1 + row.marker.chars().count()
                };
                if width > max_left {
                    max_left = width;
                }
            }
            if max_left < 32 {
                max_left = 32;
            }
            for row in &rows {
                let left = if row.marker.is_empty() {
                    row.rel.clone()
                } else {
                    format!("{} {}", row.rel, row.marker)
                };
                // printf '- %-*s — %s\n' — left-justify to max_left (char count).
                let pad = max_left.saturating_sub(left.chars().count());
                out.push_str(&format!("- {left}{} — {}\n", " ".repeat(pad), row.desc));
            }
        }
        out.push('\n');
    }

    // Canonicalise: collapse runs of blank lines, drop trailing blank lines.
    regen_canonicalize(&out)
}

/// Port of the awk blank-line canonicaliser: emit non-blank lines verbatim;
/// blank lines are buffered and only emitted (as a single run separator) when
/// a subsequent non-blank line appears — so trailing blanks are dropped and
/// internal blank runs collapse to exactly the count that precedes content...
/// Actually the awk prints `blank` empty lines before each non-blank line,
/// where `blank` is the number of consecutive blanks just seen. Reproduce
/// exactly.
fn regen_canonicalize(text: &str) -> String {
    let mut result = String::new();
    let mut blank: usize = 0;
    for line in text.lines() {
        if line.is_empty() {
            blank += 1;
            continue;
        }
        for _ in 0..blank {
            result.push('\n');
        }
        blank = 0;
        result.push_str(line);
        result.push('\n');
    }
    result
}

#[cfg(unix)]
fn run_in_pty_cmd(args: &[String]) {
    use nix::pty::{ForkptyResult, forkpty};
    use nix::unistd::execvp;
    use std::ffi::CString;
    use std::io::{self, Read, Write};
    use std::os::unix::io::AsRawFd;
    use std::os::unix::io::FromRawFd;

    if args.is_empty() {
        eprintln!("error: run-in-pty requires a command");
        process::exit(2);
    }

    let program = CString::new(args[0].as_bytes()).unwrap();
    let c_args: Vec<CString> = args
        .iter()
        .map(|s| CString::new(s.as_bytes()).unwrap())
        .collect();

    match unsafe { forkpty(None, None) } {
        Ok(ForkptyResult::Parent { child, master }) => {
            let master_fd = master.as_raw_fd();
            let mut master_file = unsafe { std::fs::File::from_raw_fd(master_fd) };
            let mut stdout = io::stdout();
            let mut buf = [0u8; 4096];

            loop {
                match master_file.read(&mut buf) {
                    Ok(0) => break, // EOF
                    Ok(n) => {
                        let _ = stdout.write_all(&buf[..n]);
                        let _ = stdout.flush();
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break, // EIO on child exit
                }
            }

            use nix::sys::wait::waitpid;
            match waitpid(child, None) {
                Ok(nix::sys::wait::WaitStatus::Exited(_, code)) => {
                    process::exit(code);
                }
                Ok(nix::sys::wait::WaitStatus::Signaled(_, sig, _)) => {
                    process::exit(128 + sig as i32);
                }
                _ => {
                    process::exit(1);
                }
            }
        }
        Ok(ForkptyResult::Child) => {
            let err = execvp(&program, &c_args);
            eprintln!("failed to exec: {err:?}");
            process::exit(1);
        }
        Err(err) => {
            eprintln!("forkpty failed: {err:?}");
            process::exit(1);
        }
    }
}

#[cfg(not(unix))]
fn run_in_pty_cmd(args: &[String]) {
    if args.is_empty() {
        eprintln!("error: run-in-pty requires a command");
        process::exit(2);
    }
    let mut cmd = process::Command::new(&args[0]);
    cmd.args(&args[1..]);
    match cmd.status() {
        Ok(status) => {
            process::exit(status.code().unwrap_or(1));
        }
        Err(err) => {
            eprintln!("failed to run command: {err:?}");
            process::exit(1);
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
        assert!(has_python_runtime_reference(
            "command: \"python3 -c 'import json'\""
        ));
        assert!(has_python_runtime_reference(
            "python3 /tmp/opencode-mock.py"
        ));
        assert!(!has_python_runtime_reference("# python3 in a comment"));
    }

    #[test]
    fn litmus_yaml_files_are_scanned_for_python_runtime_drift() {
        let root = Path::new("/repo");
        assert!(is_script_or_harness(
            root,
            Path::new("/repo/openspec/litmus-tests/litmus-example.yaml")
        ));
        assert!(!is_script_or_harness(
            root,
            Path::new("/repo/plan/issues/no-python-litmus-drift-2026-06-20.md")
        ));
    }

    #[test]
    fn menu_assertion_helpers_accept_expected_shape() {
        use serde_json::json;
        let menu = json!([
            {"id": "status_text"},
            {"id": "observatorium", "disabled": true, "disabled_reason": "v2 terminal-only"}
        ]);
        let ids = menu_item_ids(Path::new("menu.json"), &menu);
        assert!(ids.contains("status_text"));
        assert!(ids.contains("observatorium"));
    }

    #[test]
    fn json_path_extracts_nested_values() {
        use serde_json::json;
        let data = json!({"auth": {"client_token": "hvs.test"}});
        assert_eq!(
            json_path(&data, "auth.client_token").and_then(|v| v.as_str()),
            Some("hvs.test")
        );
        assert!(json_path(&data, "auth.missing").is_none());
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
    fn diagnostics_litmus_missing_status_matches_legacy_inline_validator() {
        use serde_json::json;
        assert!(json_value_is_missing_for_litmus(&json!("unset")));
        assert!(json_value_is_missing_for_litmus(&json!("N/A")));
        assert!(json_value_is_missing_for_litmus(&json!("BLOCKED")));
        assert!(json_value_is_missing_for_litmus(&json!("NOT_FOUND")));
        assert!(json_value_is_missing_for_litmus(&json!("NONE")));
        assert!(!json_value_is_missing_for_litmus(&json!("")));
        assert!(!json_value_is_missing_for_litmus(&json!(null)));
        assert!(!json_value_is_missing_for_litmus(&json!(false)));
        assert!(!json_value_is_missing_for_litmus(&json!(0)));
        assert!(!json_value_is_missing_for_litmus(&json!(
            "/usr/bin/opencode"
        )));
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
    fn diagnostics_json_candidate_ignores_forge_banner_and_fence() {
        let raw = "[forge] banner\n```json\n{\"diagnostics_timestamp\":\"t\"}\n```\n";
        let (candidate, no_brace) = diagnostics_json_candidate(raw);
        assert!(!no_brace);
        assert_eq!(candidate, "{\"diagnostics_timestamp\":\"t\"}");
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
