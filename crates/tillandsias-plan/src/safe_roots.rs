//! ORDER 2065-baby — removals the FORGE answers `allow` for, so Claude Code's
//! own deletion prompt does not stop an agent cleaning regenerable output.
//!
//! Operator approval: 2026-11-09, relayed by the macuahuitl coordinator. In a
//! forge, an `rm` or `git worktree remove` whose every target lies inside a
//! safe root needs no prompt. The safe roots are:
//!
//! - the agent's session scratchpad (`/tmp/claude-<uid>/…/scratchpad/`);
//! - `/work/tmp/`;
//! - a project's `build/`, `.dart_tool/` and `.cache/` (at the root of the
//!   project checkout or of one of its worktrees);
//! - `.claude/worktrees/<name>`.
//!
//! Everything else keeps prompting. FAIL-CLOSED: any shape this module does
//! not fully understand returns `None`, and `None` changes nothing: the hook
//! stays silent and Claude Code decides as before. That covers shell
//! metacharacters, a variable, `..`, a glob outside the last component, a
//! symlinked ancestor, an unknown flag, or a second command.

use std::path::{Component, Path, PathBuf};

/// Where the safe roots live. [`SafeRoots::forge`] is the real layout;
/// tests point it at a temp directory.
#[derive(Debug, Clone)]
pub struct SafeRoots {
    /// The forge's source root; a project is `<src>/<project>`.
    pub src: PathBuf,
    /// The forge's work temp dir.
    pub work_tmp: PathBuf,
    /// The parent of Claude Code's per-uid temp dirs (`<tmp>/claude-<uid>`).
    pub tmp: PathBuf,
}

impl SafeRoots {
    pub fn forge() -> Self {
        SafeRoots {
            src: PathBuf::from("/home/forge/src"),
            work_tmp: PathBuf::from("/work/tmp"),
            tmp: PathBuf::from("/tmp"),
        }
    }
}

/// The build-output directories that are safe at a checkout's root.
const REGENERABLE: [&str; 3] = ["build", ".dart_tool", ".cache"];

/// The PreToolUse answer for a command the bash policy ALLOWED: an explicit
/// `allow` JSON in a forge when [`safe_root_removal`] accepts it; `None`
/// (stay silent, so Claude Code decides) on every other host and command. A
/// forge is read from the container record, never self-declared
/// (`command_policy::read_host_kind`), so a bare-metal host never gets here.
pub fn hook_allow(
    host_kind: crate::command_policy::HostKind,
    cmd: &str,
    cwd: &Path,
    roots: &SafeRoots,
) -> Option<serde_json::Value> {
    if host_kind != crate::command_policy::HostKind::Forge {
        return None;
    }
    let reason = safe_root_removal(cmd, cwd, roots)?;
    Some(serde_json::json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": reason,
    }}))
}

/// `Some(reason)` when `cmd` removes only paths inside the safe roots, run
/// from `cwd`. Otherwise `None`.
pub fn safe_root_removal(cmd: &str, cwd: &Path, roots: &SafeRoots) -> Option<String> {
    if !cwd.is_absolute() {
        return None;
    }
    let words = split_simple(cmd)?;
    let (targets, worktree_only) = match words.first().map(String::as_str) {
        Some("rm") => (rm_targets(&words[1..])?, false),
        Some("git") => (worktree_remove_target(&words[1..])?, true),
        _ => return None,
    };
    if targets.is_empty() {
        return None;
    }
    let mut named = Vec::new();
    for t in &targets {
        let path = normalise(cwd, t)?;
        let root = if worktree_only {
            worktree_root(&path, roots)?
        } else {
            safe_root_of(&path, roots)?
        };
        no_symlinked_ancestor(&path)?;
        named.push(root);
    }
    named.sort();
    named.dedup();
    Some(format!(
        "safe-root removal (2065-baby): every target is inside {}",
        named.join(", ")
    ))
}

/// Split a command that is ONE simple command into words. `None` for anything
/// a shell would treat specially: operators, redirections, expansions,
/// escapes, braces, or a newline. Whole-word '…' / "…" quoting is accepted
/// when the quoted text has none of those either.
fn split_simple(cmd: &str) -> Option<Vec<String>> {
    const META: &[char] = &[
        ';', '&', '|', '<', '>', '(', ')', '$', '`', '\\', '\n', '\r', '{', '}', '[', ']', '~',
        '!', '#',
    ];
    if cmd.contains(META) {
        return None;
    }
    let mut words = Vec::new();
    for raw in cmd.split([' ', '\t']).filter(|w| !w.is_empty()) {
        let word = match raw.chars().next() {
            Some(q @ ('\'' | '"')) => {
                let inner = raw.strip_prefix(q)?.strip_suffix(q)?;
                if inner.contains(['\'', '"', '*', '?']) {
                    return None;
                }
                inner.to_string()
            }
            _ if raw.contains(['\'', '"']) => return None,
            _ => raw.to_string(),
        };
        if word.is_empty() {
            return None;
        }
        words.push(word);
    }
    Some(words)
}

/// The operands of `rm` with only the flags a cleanup uses.
fn rm_targets(args: &[String]) -> Option<Vec<String>> {
    let mut out = Vec::new();
    let mut operands_only = false;
    for a in args {
        if operands_only || !a.starts_with('-') {
            out.push(a.clone());
            continue;
        }
        match a.as_str() {
            "--" => operands_only = true,
            "--recursive" | "--force" | "--verbose" => {}
            short if short.len() > 1 && short[1..].chars().all(|c| "rRfv".contains(c)) => {}
            _ => return None,
        }
    }
    Some(out)
}

/// The one path of `git worktree remove [-f|--force]… <path>`.
fn worktree_remove_target(args: &[String]) -> Option<Vec<String>> {
    let rest = match args {
        [w, r, rest @ ..] if w == "worktree" && r == "remove" => rest,
        _ => return None,
    };
    let mut path = None;
    for a in rest {
        match a.as_str() {
            "-f" | "--force" => {}
            p if !p.starts_with('-') && path.is_none() => path = Some(p.to_string()),
            _ => return None,
        }
    }
    path.map(|p| vec![p])
}

/// Make `t` absolute against `cwd`, dropping `.`. `None` on `..`.
fn normalise(cwd: &Path, t: &str) -> Option<PathBuf> {
    let joined = cwd.join(t);
    let mut out = PathBuf::new();
    for c in joined.components() {
        match c {
            Component::RootDir => out.push("/"),
            Component::CurDir => {}
            Component::Normal(n) => out.push(n),
            Component::ParentDir | Component::Prefix(_) => return None,
        }
    }
    Some(out)
}

fn has_glob(s: &str) -> bool {
    s.contains(['*', '?'])
}

/// Components of `path` as strings; `None` when one is not UTF-8.
fn parts(path: &Path) -> Option<Vec<String>> {
    path.components()
        .filter_map(|c| match c {
            Component::Normal(n) => Some(n.to_str().map(str::to_string)),
            _ => None,
        })
        .collect()
}

/// Strip `base` from `path`, as components. Globs are allowed only in the LAST
/// component, and only strictly beneath the root they are checked against
/// (`min_depth` components past `base`).
fn rest_under(path: &Path, base: &Path) -> Option<Vec<String>> {
    let rest = parts(path.strip_prefix(base).ok()?)?;
    let n = rest.len();
    if rest[..n.saturating_sub(1)].iter().any(|c| has_glob(c)) {
        return None;
    }
    Some(rest)
}

/// The safe root that contains `path`, as display text.
fn safe_root_of(path: &Path, roots: &SafeRoots) -> Option<String> {
    // /work/tmp/<x>… — beneath, never the dir itself.
    if let Some(rest) = rest_under(path, &roots.work_tmp)
        && !rest.is_empty()
        && !has_glob(&rest[0])
    {
        return Some(roots.work_tmp.display().to_string() + "/");
    }
    // <tmp>/claude-<uid>/…/scratchpad/<x>… — beneath the scratchpad.
    if let Some(rest) = rest_under(path, &roots.tmp)
        && let Some(first) = rest.first()
        && first
            .strip_prefix("claude-")
            .is_some_and(|uid| !uid.is_empty() && uid.chars().all(|c| c.is_ascii_digit()))
        && let Some(at) = rest.iter().position(|c| c == "scratchpad")
        && at >= 2
        && rest.len() > at + 1
        && !rest[..=at].iter().any(|c| has_glob(c))
    {
        return Some("the session scratchpad".to_string());
    }
    // A checkout root: <src>/<project> or <src>/<project>/.claude/worktrees/<wt>.
    let rest = rest_under(path, &roots.src)?;
    let (base_len, label) = match rest.as_slice() {
        [p, c, w, wt, ..] if c == ".claude" && w == "worktrees" => {
            if [p, wt].iter().any(|x| has_glob(x)) {
                return None;
            }
            if rest.len() == 4 {
                // The worktree itself.
                return Some(format!("{p}/.claude/worktrees/"));
            }
            (4, format!("{p}/.claude/worktrees/{wt}/"))
        }
        [p, ..] if !has_glob(p) => (1, format!("{p}/")),
        _ => return None,
    };
    let dir = rest.get(base_len)?;
    if REGENERABLE.contains(&dir.as_str()) {
        return Some(format!("{label}{dir}/"));
    }
    None
}

/// For `git worktree remove`: the path must be exactly a worktree under a
/// project's `.claude/worktrees/`.
fn worktree_root(path: &Path, roots: &SafeRoots) -> Option<String> {
    let rest = parts(path.strip_prefix(&roots.src).ok()?)?;
    match rest.as_slice() {
        [p, c, w, wt] if c == ".claude" && w == "worktrees" && !has_glob(p) && !has_glob(wt) => {
            Some(format!("{p}/.claude/worktrees/"))
        }
        _ => None,
    }
}

/// `None` when any existing ancestor of `path` (not `path` itself: rm on a
/// symlink removes the link) is a symlink, so a link cannot carry a removal
/// out of its root.
fn no_symlinked_ancestor(path: &Path) -> Option<()> {
    let mut cur = PathBuf::new();
    let comps: Vec<_> = path.components().collect();
    for c in &comps[..comps.len().saturating_sub(1)] {
        cur.push(c);
        if let Ok(m) = std::fs::symlink_metadata(&cur)
            && m.file_type().is_symlink()
        {
            return None;
        }
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roots(base: &Path) -> SafeRoots {
        SafeRoots {
            src: base.join("src"),
            work_tmp: base.join("work/tmp"),
            tmp: base.join("tmp"),
        }
    }

    fn fixture() -> (tempfile::TempDir, SafeRoots, PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let base = d.path().canonicalize().unwrap();
        let r = roots(&base);
        let proj = r.src.join("demon_attack");
        for p in [
            proj.join("build/web"),
            proj.join(".dart_tool/build"),
            proj.join(".claude/worktrees/a/.dart_tool"),
            proj.join("lib"),
            r.work_tmp.join("x"),
            r.tmp.join("claude-1000/proj/sess/scratchpad"),
        ] {
            std::fs::create_dir_all(p).unwrap();
        }
        (d, r, proj)
    }

    #[test]
    fn removals_inside_the_safe_roots_are_allowed() {
        let (_d, r, proj) = fixture();
        let pad = r.tmp.join("claude-1000/proj/sess/scratchpad/a.png");
        let wt = proj.join(".claude/worktrees/a");
        for cmd in [
            "rm -rf .dart_tool".to_string(),
            "rm -rf build/web".to_string(),
            "rm -rf build/*".to_string(),
            "rm -r -f build .dart_tool".to_string(),
            "rm -rf '.claude/worktrees/a/.dart_tool'".to_string(),
            "rm -rf .claude/worktrees/a".to_string(),
            "git worktree remove --force .claude/worktrees/a".to_string(),
            format!("git worktree remove {}", wt.display()),
            format!("rm -f {}", pad.display()),
            format!("rm -rf {}", r.work_tmp.join("x").display()),
            "rm -rf -- ./build".to_string(),
        ] {
            assert!(
                safe_root_removal(&cmd, &proj, &r).is_some(),
                "{cmd} should be a safe-root removal"
            );
        }
    }

    /// The negative arm: everything outside the roots, and every shape this
    /// module cannot fully judge, returns None, so Claude Code still asks.
    #[test]
    fn removals_outside_the_safe_roots_still_prompt() {
        let (_d, r, proj) = fixture();
        for cmd in [
            "rm -rf lib".to_string(),
            "rm -rf .".to_string(),
            "rm -rf /".to_string(),
            "rm -rf ~/".to_string(),
            "rm -rf build/../lib".to_string(),
            "rm -rf build*".to_string(),
            "rm -rf */build".to_string(),
            "rm -rf build lib".to_string(),
            "rm -rf $HOME".to_string(),
            "rm -rf build; rm -rf lib".to_string(),
            "rm -rf build && rm -rf lib".to_string(),
            "rm -rf `pwd`".to_string(),
            "rm -rf build/web > /dev/null".to_string(),
            "rm --no-preserve-root -rf build".to_string(),
            "rm".to_string(),
            "rm -rf".to_string(),
            "rm -rf lib/build".to_string(),
            "git worktree remove --force lib".to_string(),
            "git worktree remove .claude/worktrees".to_string(),
            "git worktree prune".to_string(),
            "sudo rm -rf build".to_string(),
            format!("rm -rf {}", r.work_tmp.display()),
            format!(
                "rm -rf {}",
                r.tmp.join("claude-1000/proj/sess/scratchpad").display()
            ),
            format!("rm -rf {}", r.tmp.join("claude-1000").display()),
            format!("rm -rf {}", r.src.display()),
            format!("rm -rf {}", proj.display()),
        ] {
            assert!(
                safe_root_removal(&cmd, &proj, &r).is_none(),
                "{cmd} must not be allowed"
            );
        }
    }

    #[test]
    fn a_symlinked_ancestor_is_not_a_safe_root() {
        let (_d, r, proj) = fixture();
        std::fs::remove_dir_all(proj.join("build")).unwrap();
        std::os::unix::fs::symlink(proj.join("lib"), proj.join("build")).unwrap();
        assert!(safe_root_removal("rm -rf build/web", &proj, &r).is_none());
        // Removing the link itself only removes the link.
        assert!(safe_root_removal("rm -f build", &proj, &r).is_some());
    }

    #[test]
    fn only_a_forge_answers_allow() {
        use crate::command_policy::HostKind;
        let (_d, r, proj) = fixture();
        let a = hook_allow(HostKind::Forge, "rm -rf .dart_tool", &proj, &r).unwrap();
        assert_eq!(a["hookSpecificOutput"]["permissionDecision"], "allow");
        for k in [HostKind::BareMetal, HostKind::Ci] {
            assert!(hook_allow(k, "rm -rf .dart_tool", &proj, &r).is_none());
        }
        assert!(hook_allow(HostKind::Forge, "rm -rf lib", &proj, &r).is_none());
    }

    #[test]
    fn a_relative_cwd_is_never_judged() {
        let (_d, r, _proj) = fixture();
        assert!(safe_root_removal("rm -rf build", Path::new("demon_attack"), &r).is_none());
    }
}
