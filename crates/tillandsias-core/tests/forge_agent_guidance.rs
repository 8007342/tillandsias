// ORDER 1724-kcj4: every forge agent receives the forge guidance through its
// harness's own USER-level instruction file, from ONE source, without shadowing
// a project's files or overwriting the user's.
// @trace order:1724-kcj4, spec:forge-shell-tools

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const GUIDANCE: &str = "images/default/config-overlay/mcp/forge-agent-guidance.md";
const PROFILE: &str = "images/default/config-overlay/mcp/agent-profile.sh";

/// The one sentence every harness must be given (the lakanoa agent killed its
/// own shell with `pkill -f`, exit 144).
const SENTENCE: &str =
    "find it with `pgrep`, then kill it by its PID, skipping your own shell (`$$`)";

/// Each harness's USER-level instruction file, relative to $HOME.
const HARNESS_FILES: [(&str, &str); 4] = [
    ("claude", ".claude/CLAUDE.md"),
    ("codex", ".codex/AGENTS.md"),
    ("gemini", ".gemini/GEMINI.md"),
    ("opencode", ".config/opencode/AGENTS.md"),
];

// Read at RUNTIME (1590-j20f): a shared CARGO_TARGET_DIR reuses a test binary
// compiled in another checkout, so compile-time env! would name that one.
fn repo_root() -> PathBuf {
    let manifest = PathBuf::from(
        std::env::var("CARGO_MANIFEST_DIR").expect("cargo test sets CARGO_MANIFEST_DIR"),
    );
    manifest
        .parent()
        .and_then(|p| p.parent())
        .expect("repo root")
        .to_path_buf()
}

/// Source the real agent-profile.sh the way an entrypoint does, with HOME and
/// the working directory under test, and no generic skills to link.
fn source_profile(home: &Path, cwd: &Path) {
    let root = repo_root();
    let empty_skills = home.join(".no-skills");
    fs::create_dir_all(&empty_skills).unwrap();
    let status = Command::new("bash")
        .arg("-c")
        .arg("source \"$1\"")
        .arg("bash")
        .arg(root.join(PROFILE))
        .current_dir(cwd)
        .env("HOME", home)
        .env("TILLANDSIAS_AGENT", "claude")
        .env("TILLANDSIAS_SHARED_SKILLS_ROOT", &empty_skills)
        .env("TILLANDSIAS_FORGE_GUIDANCE", root.join(GUIDANCE))
        .status()
        .expect("run bash");
    assert!(
        status.success(),
        "sourcing agent-profile.sh failed: {status}"
    );
}

#[test]
fn every_harness_receives_the_guidance_sentence() {
    let home = tempfile::tempdir().unwrap();
    source_profile(home.path(), home.path());
    for (harness, rel) in HARNESS_FILES {
        let path = home.path().join(rel);
        let text = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("{harness}: {} was not created: {e}", path.display()));
        assert!(
            text.contains(SENTENCE),
            "{harness}: {} lacks the guidance sentence",
            path.display()
        );
    }
}

#[test]
fn an_existing_user_file_is_never_overwritten() {
    let home = tempfile::tempdir().unwrap();
    let mine = home.path().join(".claude/CLAUDE.md");
    fs::create_dir_all(mine.parent().unwrap()).unwrap();
    fs::write(&mine, "the user's own notes\n").unwrap();
    source_profile(home.path(), home.path());
    assert_eq!(fs::read_to_string(&mine).unwrap(), "the user's own notes\n");
    // The other harnesses are still given the guidance.
    let codex = fs::read_to_string(home.path().join(".codex/AGENTS.md")).unwrap();
    assert!(codex.contains(SENTENCE));
}

#[test]
fn a_projects_own_instruction_files_are_untouched() {
    let home = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();
    for f in ["CLAUDE.md", "AGENTS.md", "GEMINI.md"] {
        fs::write(project.path().join(f), format!("project {f}\n")).unwrap();
    }
    source_profile(home.path(), project.path());
    for f in ["CLAUDE.md", "AGENTS.md", "GEMINI.md"] {
        let p = project.path().join(f);
        assert!(!p.is_symlink(), "{f} in the project became a link");
        assert_eq!(fs::read_to_string(&p).unwrap(), format!("project {f}\n"));
    }
    // Nothing else appeared in the project directory either.
    assert_eq!(fs::read_dir(project.path()).unwrap().count(), 3);
}

/// One source: the sentence lives in the guidance file and nowhere else under
/// images/, so the harnesses cannot drift apart.
#[test]
fn the_guidance_has_exactly_one_source() {
    let root = repo_root();
    let mut hits = Vec::new();
    let mut stack = vec![root.join("images")];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir).unwrap().flatten() {
            let p = entry.path();
            if p.is_dir() {
                stack.push(p);
            } else if fs::read_to_string(&p).is_ok_and(|t| t.contains(SENTENCE)) {
                hits.push(p.strip_prefix(&root).unwrap().display().to_string());
            }
        }
    }
    assert_eq!(hits, vec![GUIDANCE.to_string()]);
}
