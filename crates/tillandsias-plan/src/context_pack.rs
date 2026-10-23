//! ORDER 1815-tei4 — the expert CONTEXT PACK.
//!
//! A small (at most [`MAX_PACK_BYTES`], about 1.2k tokens), deterministic
//! Markdown file written at forge launch beside `.forge-startup-context.md`
//! (`images/default/lib-common.sh` `write_expert_context_pack`, called from
//! `inject_startup_context`). Every synthesis system prompt begins with its
//! exact bytes followed by [`PACK_SEPARATOR`] — `pipeline::domain_synthesis_prompt`
//! and tellme's `tellme_context_pack` — so ollama's prompt-prefix cache is
//! reused across questions.
//!
//! The pack describes THE PROJECT IN THIS FORGE, which is usually not
//! Tillandsias (operator constraint 2026-10-23). Sections, in fixed order:
//!
//! 1. universal forge constraints — always; the quoted Summary block of
//!    `cheatsheets/runtime/forge-constraints.md` ([`FORGE_CONSTRAINTS_SUMMARY`],
//!    pinned equal to the sheet by a unit test);
//! 2. project identity — name, remote (credentials stripped), branch, toolchain;
//! 3. branch discipline — the level from the project's own seed
//!    (`branch_discipline::load`, the `tillandsias-plan discipline show` answer);
//! 4. project declarations — bounded excerpts of its `CLAUDE.md` / `AGENTS.md`
//!    and a pointer to its methodology, if any. Cut FIRST when over budget;
//! 5. Tillandsias rules — only when [`is_tillandsias`] (both `methodology.yaml`
//!    and `crates/tillandsias-plan`; the remote name alone does not count).
//!
//! Determinism is the cache-reuse condition: no timestamps, no per-query text,
//! nothing read from the environment.
//!
//! @trace order:1815-tei4, spec:expert-serve-grounded-pipeline

use std::path::{Path, PathBuf};
use std::process::Command;

/// The pack's file name, written in the project root.
pub const PACK_FILE: &str = ".forge-expert-context.md";
/// Hard size bound of the pack (about 1.2k tokens at 4 bytes per token).
pub const MAX_PACK_BYTES: usize = 4800;
/// What every synthesis system prompt puts between the pack and its own text.
/// tellme's `tellme_context_pack` prints the same bytes.
pub const PACK_SEPARATOR: &str = "\n---\n\n";
/// Overrides the pack path for readers (expert-serve, tellme).
pub const PACK_ENV: &str = "TILLANDSIAS_EXPERT_CONTEXT_PACK";

/// The Summary block of `cheatsheets/runtime/forge-constraints.md`, quoted.
/// Embedded so a forge running ANY project carries it; pinned equal to the
/// sheet by `constraints_summary_matches_the_cheatsheet`.
pub const FORGE_CONSTRAINTS_SUMMARY: &str = "There is NO docker and NO nested container daemon in the forge. Do not recommend `docker run`, `docker compose`, `podman run`, podman-in-podman or mounting a container socket here. The forge is itself a rootless podman container (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`). Container work is done on the host by tillandsias or by enclave services, never from inside the forge. The workspace is a git clone on tmpfs (lost on stop; push to keep it). Egress goes only through the enclave proxy. Local inference is at `inference:11434`, the expert endpoint at `127.0.0.1:11436`. `git push` goes through the git mirror.";

/// Tillandsias's own working rules. Emitted only for a Tillandsias checkout.
const TILLANDSIAS_RULES: &str = "\
## Tillandsias rules (this project is Tillandsias)
- `methodology.yaml` and `methodology/` are the source of truth for workflow; specs live in `openspec/specs/`, the plan ledger in `plan/`. Ask the forge-plan MCP (`plan_answer`, `methodology_ask`, `spec_answer`) before reading files.
- Branches: Linux and forges integrate on `linux-next` (Windows `windows-next`, macOS `osx-next`); `main` moves only by pull request from `linux-next`. Each unit of work is a `work/<order>` ref (e.g. `work/1815-tei4`) landed by pull request into `linux-next`.
- Every change carries `@trace order:<order>` or `@trace spec:<name>`. No python; no new `jq` (use `tillandsias-plan json get`). Never `--force` or `--no-verify`.
- Gates: `./build.sh --preflight`, `./build.sh --check`, `./build.sh --test`.
";

/// Per-file bound of a declaration excerpt, before the global budget.
const EXCERPT_FILE_BYTES: usize = 1600;
/// Upper bound read from any project file.
const READ_CAP: u64 = 64 * 1024;

/// A project counts as Tillandsias only with BOTH markers.
pub fn is_tillandsias(root: &Path) -> bool {
    root.join("methodology.yaml").is_file() && root.join("crates/tillandsias-plan").is_dir()
}

/// Build the pack for the checkout at `root`. Always returns a pack at most
/// [`MAX_PACK_BYTES`] long that ends with a newline; the universal
/// constraints are never cut.
pub fn build_pack(root: &Path) -> String {
    let head = format!(
        "# Forge context (generated at forge launch)\n\n\
         ## Forge constraints (always true in this forge)\n{FORGE_CONSTRAINTS_SUMMARY}\n\n"
    );
    let identity = identity_section(root);
    let discipline = discipline_section(root);
    let tillandsias = if is_tillandsias(root) {
        format!("\n{TILLANDSIAS_RULES}")
    } else {
        String::new()
    };
    let decl_head = "## Project declarations\n";
    let methodology = methodology_line(root);
    let fixed = head.len()
        + identity.len()
        + discipline.len()
        + decl_head.len()
        + methodology.len()
        + tillandsias.len();
    let budget = MAX_PACK_BYTES.saturating_sub(fixed);
    let excerpts = cut_to(&declaration_excerpts(root), budget);
    let mut pack =
        format!("{head}{identity}{discipline}{decl_head}{methodology}{excerpts}{tillandsias}");
    if pack.len() > MAX_PACK_BYTES {
        // Only reachable if the fixed sections alone overflow; the head (the
        // universal constraints) is first, so a tail cut never removes it.
        pack = cut_to(&pack, MAX_PACK_BYTES);
    }
    pack
}

/// Write the pack atomically (temp file + rename) to `out`.
pub fn write_pack(root: &Path, out: &Path) -> std::io::Result<usize> {
    let pack = build_pack(root);
    let tmp = out.with_extension("md.tmp");
    std::fs::write(&tmp, pack.as_bytes())?;
    std::fs::rename(&tmp, out)?;
    Ok(pack.len())
}

/// The pack for prompts: `$TILLANDSIAS_EXPERT_CONTEXT_PACK`, else
/// `<root>/.forge-expert-context.md`. FAIL-SOFT: absent, not a regular file,
/// empty, over twice the bound, or not UTF-8 → `None` and prompts unchanged.
pub fn load_pack(root: &Path) -> Option<String> {
    let path = std::env::var_os(PACK_ENV)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join(PACK_FILE));
    load_pack_from(&path)
}

/// [`load_pack`] for an explicit path.
pub fn load_pack_from(path: &Path) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > (2 * MAX_PACK_BYTES) as u64 {
        return None;
    }
    let text = String::from_utf8(std::fs::read(path).ok()?).ok()?;
    (!text.trim().is_empty()).then_some(text)
}

// ── sections ────────────────────────────────────────────────────────────────

fn identity_section(root: &Path) -> String {
    let name = root
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "unknown".into());
    let remote = git(root, &["config", "--get", "remote.origin.url"])
        .map(|u| strip_userinfo(&u))
        .unwrap_or_else(|| "none".into());
    // symbolic-ref answers on an unborn branch too (a fresh project).
    let branch =
        git(root, &["symbolic-ref", "--short", "-q", "HEAD"]).unwrap_or_else(|| "detached".into());
    let toolchain = detect_toolchain(root);
    format!(
        "## Project\n- name: {name}\n- remote: {remote}\n- branch: {branch}\n- toolchain: {}\n\n",
        if toolchain.is_empty() {
            "none detected".to_string()
        } else {
            toolchain.join(", ")
        }
    )
}

fn discipline_section(root: &Path) -> String {
    let d = crate::branch_discipline::load(root, None);
    let source = match (&d.refusal, d.source) {
        (Some(_), _) => "seed refused; built-in default",
        (None, crate::branch_discipline::Source::Seed) => "the project's seed",
        (None, crate::branch_discipline::Source::Default) => "no seed; built-in default",
    };
    let meaning = match d.level {
        0 => format!(
            "commit and push to the default branch `{}` freely; hooks only advise.",
            d.default_branch
        ),
        1 => format!(
            "integrate on `{}`; the default branch `{}` advances only by pull request.",
            d.target("forge"),
            d.default_branch
        ),
        _ => format!(
            "do each unit of work on a work ref (`{}`) and land it into `{}`; the default branch `{}` advances only by pull request.",
            d.work_ref.as_deref().unwrap_or("work/<id>"),
            d.target("forge"),
            d.default_branch
        ),
    };
    format!(
        "## Branch discipline\n- level {} ({source}): {meaning}\n- details: `tillandsias-plan discipline show`, or the /project-discipline skill.\n\n",
        d.level
    )
}

fn methodology_line(root: &Path) -> String {
    let mut found = Vec::new();
    for p in ["methodology.yaml", "methodology", "openspec"] {
        if root.join(p).exists() {
            found.push(format!("`{p}`"));
        }
    }
    if found.is_empty() {
        "- methodology: none declared.\n".into()
    } else {
        format!(
            "- methodology: {} (the project's own source of truth).\n",
            found.join(", ")
        )
    }
}

fn declaration_excerpts(root: &Path) -> String {
    let mut out = String::new();
    let mut seen: Vec<String> = Vec::new();
    for f in ["AGENTS.md", "CLAUDE.md"] {
        let Some(body) = read_regular(&root.join(f)) else {
            continue;
        };
        let body = body.trim();
        if body.is_empty() || seen.iter().any(|s| s == body) {
            continue;
        }
        seen.push(body.to_string());
        out.push_str(&format!("\n### {f} (excerpt)\n"));
        out.push_str(&cut_to(&format!("{body}\n"), EXCERPT_FILE_BYTES));
    }
    out
}

// ── helpers ─────────────────────────────────────────────────────────────────

const TRUNCATED: &str = "[... truncated to fit the pack]\n";

/// `s` cut to at most `max` bytes at a line boundary, marked when cut.
fn cut_to(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    if max <= TRUNCATED.len() {
        return String::new();
    }
    let mut end = max - TRUNCATED.len();
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    let end = s[..end].rfind('\n').map(|i| i + 1).unwrap_or(0);
    format!("{}{TRUNCATED}", &s[..end])
}

fn read_regular(p: &Path) -> Option<String> {
    use std::io::Read;
    let meta = std::fs::metadata(p).ok()?;
    if !meta.is_file() {
        return None;
    }
    let mut buf = Vec::new();
    std::fs::File::open(p)
        .ok()?
        .take(READ_CAP)
        .read_to_end(&mut buf)
        .ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

fn git(root: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !s.is_empty()).then_some(s)
}

/// `scheme://user:secret@host/path` → `scheme://host/path`.
fn strip_userinfo(url: &str) -> String {
    if let Some((scheme, rest)) = url.split_once("://") {
        let (auth, path) = rest.split_once('/').unwrap_or((rest, ""));
        if let Some((_, host)) = auth.rsplit_once('@') {
            return if path.is_empty() && !rest.contains('/') {
                format!("{scheme}://{host}")
            } else {
                format!("{scheme}://{host}/{path}")
            };
        }
    }
    url.to_string()
}

fn detect_toolchain(root: &Path) -> Vec<&'static str> {
    const MARKERS: &[(&str, &str)] = &[
        ("Cargo.toml", "rust (cargo)"),
        ("package.json", "node (package.json)"),
        ("pubspec.yaml", "dart/flutter"),
        ("go.mod", "go"),
        ("pyproject.toml", "python (pyproject)"),
        ("requirements.txt", "python (requirements.txt)"),
        ("Gemfile", "ruby"),
        ("pom.xml", "java (maven)"),
        ("build.gradle", "jvm (gradle)"),
        ("build.gradle.kts", "jvm (gradle)"),
        ("CMakeLists.txt", "c/c++ (cmake)"),
        ("flake.nix", "nix"),
        ("Makefile", "make"),
    ];
    let mut v: Vec<&'static str> = Vec::new();
    for (file, label) in MARKERS {
        if root.join(file).is_file() && !v.contains(label) {
            v.push(label);
        }
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    fn git_in(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .output()
            .expect("git runs")
            .status
            .success();
        assert!(ok, "git {args:?} failed");
    }

    /// A non-Tillandsias project: level 0 (no seed), an AGENTS.md, no
    /// methodology, a node toolchain and a remote carrying credentials.
    fn scratch_project() -> tempfile::TempDir {
        let t = tempfile::tempdir().unwrap();
        let d = t.path();
        git_in(d, &["init", "-q", "-b", "main"]);
        git_in(
            d,
            &[
                "remote",
                "add",
                "origin",
                "https://bob:s3cret@git.example.invalid/acme/widgets.git",
            ],
        );
        std::fs::write(
            d.join("AGENTS.md"),
            "# Widgets agent rules\n\nRun `npm test` before every commit.\nNever edit generated/ by hand.\n",
        )
        .unwrap();
        std::fs::write(d.join("package.json"), "{}\n").unwrap();
        t
    }

    // Tillandsias-specific rule strings that must never reach another project.
    const TILLANDSIAS_ONLY: &[&str] = &[
        "linux-next",
        "work/<order>",
        "osx-next",
        "Tillandsias rules",
    ];

    #[test]
    fn non_tillandsias_pack_carries_its_own_rules_and_no_tillandsias_rules() {
        let t = scratch_project();
        let pack = build_pack(t.path());
        assert!(pack.len() <= MAX_PACK_BYTES, "pack is {} bytes", pack.len());
        assert!(
            pack.contains(FORGE_CONSTRAINTS_SUMMARY),
            "universal constraints missing"
        );
        assert!(
            pack.contains("- level 0 (no seed; built-in default)"),
            "{pack}"
        );
        assert!(
            pack.contains("Run `npm test` before every commit."),
            "AGENTS.md excerpt missing"
        );
        assert!(pack.contains("- methodology: none declared."));
        assert!(pack.contains("node (package.json)"));
        assert!(pack.contains("- branch: main"));
        assert!(pack.contains("https://git.example.invalid/acme/widgets.git"));
        assert!(
            !pack.contains("s3cret"),
            "remote credentials leaked into the pack"
        );
        for s in TILLANDSIAS_ONLY {
            assert!(
                !pack.contains(s),
                "non-Tillandsias pack carries {s:?}:\n{pack}"
            );
        }
        eprintln!("non-tillandsias pack: {} bytes", pack.len());
    }

    #[test]
    fn tillandsias_checkout_pack_names_the_tillandsias_branch_rules_within_the_bound() {
        // Runtime, not env!(): a shared target dir can run a binary compiled
        // in another worktree (1590-j20f).
        let repo = PathBuf::from(
            std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"),
        )
        .join("../..");
        let repo = repo.canonicalize().unwrap();
        assert!(is_tillandsias(&repo));
        let pack = build_pack(&repo);
        assert!(pack.len() <= MAX_PACK_BYTES, "pack is {} bytes", pack.len());
        assert!(pack.starts_with("# Forge context"));
        assert!(pack.contains(FORGE_CONSTRAINTS_SUMMARY));
        assert!(pack.contains("## Tillandsias rules"), "{pack}");
        assert!(pack.contains("linux-next") && pack.contains("work/<order>"));
        assert!(pack.contains("- level 2 (the project's seed)"), "{pack}");
        assert!(pack.ends_with('\n'));
        eprintln!("tillandsias pack: {} bytes", pack.len());
    }

    #[test]
    fn remote_name_alone_does_not_make_a_project_tillandsias() {
        let t = scratch_project();
        std::fs::write(t.path().join("methodology.yaml"), "version: 1\n").unwrap();
        assert!(!is_tillandsias(t.path()), "one marker must not be enough");
        let pack = build_pack(t.path());
        assert!(!pack.contains("linux-next"));
        assert!(pack.contains("`methodology.yaml`"));
    }

    #[test]
    fn oversized_declarations_are_cut_first_and_the_constraints_survive() {
        let t = scratch_project();
        let big: String = (0..4000).map(|i| format!("rule line {i}\n")).collect();
        std::fs::write(t.path().join("AGENTS.md"), &big).unwrap();
        std::fs::write(t.path().join("CLAUDE.md"), format!("other {big}")).unwrap();
        let pack = build_pack(t.path());
        assert!(pack.len() <= MAX_PACK_BYTES, "pack is {} bytes", pack.len());
        assert!(pack.contains(FORGE_CONSTRAINTS_SUMMARY));
        assert!(pack.contains("## Branch discipline"));
        assert!(pack.contains(TRUNCATED.trim_end()));
    }

    #[test]
    fn the_pack_is_deterministic_and_written_atomically() {
        let t = scratch_project();
        let out = t.path().join(PACK_FILE);
        let n = write_pack(t.path(), &out).unwrap();
        let first = std::fs::read(&out).unwrap();
        write_pack(t.path(), &out).unwrap();
        assert_eq!(first, std::fs::read(&out).unwrap(), "two builds differ");
        assert_eq!(n, first.len());
        assert_eq!(
            load_pack_from(&out).as_deref(),
            Some(build_pack(t.path()).as_str())
        );
    }

    #[test]
    fn load_is_fail_soft() {
        let t = tempfile::tempdir().unwrap();
        assert_eq!(load_pack_from(&t.path().join("absent.md")), None);
        assert_eq!(load_pack_from(t.path()), None, "a directory is not a pack");
        let empty = t.path().join("empty.md");
        std::fs::write(&empty, "").unwrap();
        assert_eq!(load_pack_from(&empty), None);
        let huge = t.path().join("huge.md");
        std::fs::write(&huge, "x".repeat(3 * MAX_PACK_BYTES)).unwrap();
        assert_eq!(load_pack_from(&huge), None);
    }

    #[test]
    fn constraints_summary_matches_the_cheatsheet() {
        let sheet = include_str!("../../../cheatsheets/runtime/forge-constraints.md");
        let block = sheet
            .split("## Summary (quote this block)\n")
            .nth(1)
            .and_then(|s| s.split("\n## ").next())
            .expect("the sheet has a Summary block")
            .trim();
        assert_eq!(
            block, FORGE_CONSTRAINTS_SUMMARY,
            "re-quote the sheet's Summary block"
        );
    }

    #[test]
    fn strip_userinfo_removes_credentials() {
        assert_eq!(
            strip_userinfo("https://u:p@h.x/a/b.git"),
            "https://h.x/a/b.git"
        );
        assert_eq!(
            strip_userinfo("git@github.com:a/b.git"),
            "git@github.com:a/b.git"
        );
        assert_eq!(strip_userinfo("https://h.x/a"), "https://h.x/a");
    }
}
