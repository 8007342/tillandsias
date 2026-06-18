use std::env;
use std::fs;
use std::path::Path;
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
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
    eprintln!("  tillandsias-policy check-no-python-scripts");
    eprintln!("  tillandsias-policy validate-yaml <file>...");
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
