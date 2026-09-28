//! ORDER 1446-xqi6 — hook templates, installed on demand per project.
//!
//! Operator ruling 7 (2026-09-27): a fresh project in a forge pushes to main by
//! default; as a project grows it installs hooks on demand, and those hooks
//! return not only the error but the AFFORDANCE ("this project at this state
//! needs work in X format, use /<skill> for instructions").
//!
//! THE SHAPE:
//! - One Lua template per client event is embedded here (`include_str!`), so a
//!   forge with the plan binary can install hooks for a project that has no
//!   Tillandsias checkout. A project's `.tillandsias/hooks/<event>.lua` wins.
//! - `install` writes a bash stub per event that execs `tillandsias-plan
//!   discipline hook <event>`; the stub carries no logic and a missing plan
//!   binary refuses (`blocked:hook:<event>:no-plan-binary`), never falls back.
//! - The seed's LEVEL chooses the set: level 0 gets the advisory post-commit and
//!   post-merge plus a pre-push that never refuses (the floor's `check-ref`
//!   refuses nothing); level 1 and up add the pre-commit and post-checkout
//!   advisories, and pre-push refuses at the seed's enforcement.
//! - `raise` moves the seed's level forward only, publishes the level as
//!   `refs/tillandsias/discipline/<n>/raised`, and the caller reinstalls.
//!
//! Mirror events (pre-receive, post-receive) are 1446-87cy's half.

use crate::branch_discipline as bd;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The marker that makes a hook file ours: `install` rewrites a file carrying
/// it and never touches one that does not.
pub const STUB_MARKER: &str = "# tillandsias-discipline-hook v1";

pub const CLIENT_EVENTS: [&str; 5] = [
    "pre-commit",
    "post-commit",
    "post-merge",
    "post-checkout",
    "pre-push",
];

/// The integration branch `raise` names when the project has none and the
/// caller named none.
pub const DEFAULT_INTEGRATION: &str = "develop";

/// The embedded template for a client event.
pub fn template(event: &str) -> Option<&'static str> {
    Some(match event {
        "pre-commit" => include_str!("../hooks/pre-commit.lua"),
        "post-commit" => include_str!("../hooks/post-commit.lua"),
        "post-merge" => include_str!("../hooks/post-merge.lua"),
        "post-checkout" => include_str!("../hooks/post-checkout.lua"),
        "pre-push" => include_str!("../hooks/pre-push.lua"),
        _ => return None,
    })
}

/// Which events a level installs. Forward-only levels mean the set only grows.
pub fn events_for_level(level: u8) -> &'static [&'static str] {
    if level == 0 {
        &["post-commit", "post-merge", "pre-push"]
    } else {
        &CLIENT_EVENTS
    }
}

/// The project override path for an event.
pub fn override_path(root: &Path, event: &str) -> PathBuf {
    root.join(".tillandsias")
        .join("hooks")
        .join(format!("{event}.lua"))
}

/// The installed stub: bash-3.2 clean, no logic, fails closed.
pub fn stub(event: &str) -> String {
    format!(
        "#!/usr/bin/env bash\n\
         {STUB_MARKER} {event}\n\
         # Installed by `tillandsias-plan discipline install-hooks` (order 1446-xqi6).\n\
         # The logic is the {event} template embedded in the plan binary, or this\n\
         # project's .tillandsias/hooks/{event}.lua when present. Nothing is decided\n\
         # here: without a runnable plan binary this hook refuses, it never falls back.\n\
         PLAN=\"${{TILLANDSIAS_PLAN_BIN:-$(command -v tillandsias-plan 2>/dev/null)}}\"\n\
         if [ -z \"$PLAN\" ] || ! \"$PLAN\" capabilities >/dev/null 2>&1; then\n\
         \x20   echo \"blocked:hook:{event}:no-plan-binary\"\n\
         \x20   echo \"  no runnable tillandsias-plan (${{PLAN:-none}}); remedy: install it, or set TILLANDSIAS_PLAN_BIN\" >&2\n\
         \x20   exit 1\n\
         fi\n\
         exec \"$PLAN\" discipline hook {event} \"$@\"\n"
    )
}

fn git(root: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// What `install` did.
#[derive(Debug)]
pub struct Installed {
    pub level: u8,
    pub dir: PathBuf,
    /// Events whose hook is ours after this run.
    pub ours: Vec<String>,
    /// Hooks written or rewritten by this run (0 on an idempotent re-run).
    pub changed: usize,
    /// (event, path) of a hook file that exists and is not ours: left alone.
    pub not_ours: Vec<(String, PathBuf)>,
}

/// Install the level's stubs. `Err` carries a one-line refusal verdict.
///
/// The hooks dir: a repo-LOCAL (or worktree) core.hooksPath is honoured; with
/// none set, the common git dir's `hooks/` is used and set LOCALLY. A
/// core.hooksPath from global or system config is REFUSED with the 1442-wyf9
/// token: writing there would arm these hooks in every repository on the box.
pub fn install(root: &Path, level: u8) -> Result<Installed, String> {
    let dir = match git(root, &["config", "--show-scope", "--get", "core.hooksPath"]) {
        Some(line) => {
            let (scope, value) = line.split_once('\t').unwrap_or(("", line.as_str()));
            match scope {
                "local" | "worktree" => {
                    let p = PathBuf::from(value);
                    if p.is_absolute() { p } else { root.join(p) }
                }
                other => {
                    let other = if other.is_empty() { "unknown" } else { other };
                    return Err(format!("refused:install-hooks:{other}-hooks-path:{value}"));
                }
            }
        }
        None => {
            let common = git(
                root,
                &["rev-parse", "--path-format=absolute", "--git-common-dir"],
            )
            .ok_or_else(|| "refused:discipline:install-hooks:not-a-git-repo".to_string())?;
            let dir = PathBuf::from(common).join("hooks");
            let dir_s = dir.to_string_lossy().to_string();
            git(root, &["config", "core.hooksPath", &dir_s]).ok_or_else(|| {
                "refused:discipline:install-hooks:cannot-set-hooks-path".to_string()
            })?;
            dir
        }
    };
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("refused:discipline:install-hooks:hooks-dir-unwritable:{e}"))?;

    let mut ours = Vec::new();
    let mut changed = 0;
    let mut not_ours = Vec::new();
    for event in events_for_level(level) {
        let path = dir.join(event);
        let want = stub(event);
        match std::fs::read_to_string(&path) {
            Ok(have) if have == want => ours.push(event.to_string()),
            Ok(have) if !have.contains(STUB_MARKER) => {
                not_ours.push((event.to_string(), path));
            }
            _ => {
                if path.exists() && !is_ours(&path) {
                    not_ours.push((event.to_string(), path));
                    continue;
                }
                std::fs::write(&path, &want).map_err(|e| {
                    format!("refused:discipline:install-hooks:write-failed:{event}:{e}")
                })?;
                make_executable(&path);
                changed += 1;
                ours.push(event.to_string());
            }
        }
    }
    Ok(Installed {
        level,
        dir,
        ours,
        changed,
        not_ours,
    })
}

fn is_ours(path: &Path) -> bool {
    std::fs::read(path)
        .map(|b| String::from_utf8_lossy(&b).contains(STUB_MARKER))
        .unwrap_or(false)
}

#[cfg(unix)]
fn make_executable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755));
}
#[cfg(not(unix))]
fn make_executable(_path: &Path) {}

/// Raise the project's level to `to`, forward-only. Returns the verdict line.
///
/// An existing seed keeps everything but its `level:` line (comments and all);
/// a missing seed is created. Level 1+ needs integration branches: an existing
/// seed without them gets `integration` for every platform, a new seed gets
/// `integration` (default DEFAULT_INTEGRATION) and `default_branch: enforced`.
/// The new text is validated by the same parser every reader uses before it is
/// written, and the level is published as refs/tillandsias/discipline/<to>/raised
/// when HEAD resolves, so a later hand edit below it is refused.
pub fn raise(root: &Path, to: u8, integration: Option<&str>) -> Result<String, String> {
    if to > 2 {
        return Err(format!("refused:discipline:raise:level-out-of-range:{to}"));
    }
    let current = bd::load(root, None);
    if let Some(r) = &current.refusal {
        return Err(format!("refused:discipline:raise:seed-refused:{r}"));
    }
    let from = current.level;
    if to <= from {
        return Err(format!(
            "refused:discipline:raise:forward-only:{from}->{to}"
        ));
    }
    let seed_path = root.join(bd::SEED_RELATIVE_PATH);
    let default_branch = bd::default_branch_of(root);
    let integ = integration.unwrap_or(DEFAULT_INTEGRATION);
    let text = match std::fs::read_to_string(&seed_path) {
        Ok(old) => {
            let mut replaced = false;
            let mut out: Vec<String> = old
                .lines()
                .map(|l| {
                    if !replaced && l.trim_start() == l && l.starts_with("level:") {
                        replaced = true;
                        format!("level: {to}")
                    } else {
                        l.to_string()
                    }
                })
                .collect();
            if !replaced {
                return Err("refused:discipline:raise:seed-has-no-level-line".into());
            }
            if to >= 1 && current.integration.is_empty() {
                out.push("integration:".into());
                for p in bd::PLATFORMS {
                    out.push(format!("  {p}: {integ}"));
                }
            }
            out.join("\n") + "\n"
        }
        Err(_) => {
            let ref_grammar = if to >= 2 { "warn" } else { "advised" };
            let mut s = format!(
                "# Branch discipline seed (order 1443-w79y), created by\n\
                 # `tillandsias-plan discipline raise --to {to}` (order 1446-xqi6).\n\
                 # Levels only move forward; read it with `tillandsias-plan discipline show`.\n\
                 version: 1\n\
                 level: {to}\n\
                 enforcement:\n  default_branch: enforced\n  ref_grammar: {ref_grammar}\n\
                 default_branch: {default_branch}\n"
            );
            if to >= 1 {
                s.push_str("integration:\n");
                for p in bd::PLATFORMS {
                    s.push_str(&format!("  {p}: {integ}\n"));
                }
            }
            s
        }
    };
    if let Err(reason) = bd::parse_seed(&text, bd::published_level(root), &default_branch) {
        return Err(format!("refused:discipline:raise:invalid-seed:{reason}"));
    }
    if let Some(dir) = seed_path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("refused:discipline:raise:seed-unwritable:{e}"))?;
    }
    std::fs::write(&seed_path, &text)
        .map_err(|e| format!("refused:discipline:raise:seed-unwritable:{e}"))?;
    let published = git(
        root,
        &[
            "update-ref",
            &format!("refs/tillandsias/discipline/{to}/raised"),
            "HEAD",
        ],
    )
    .is_some();
    Ok(format!(
        "ok:discipline:raised:{from}->{to}:published={}",
        if published { "yes" } else { "no-head" }
    ))
}

/// Run one event's template (the project's override when present) in the
/// sandboxed Lua environment. Prints the verdict line; returns the exit code:
/// 0 for ok:/advised:/warn:, 1 for anything else, 2 for an unknown event.
pub fn run_hook(root: &Path, event: &str, git_args: &[String]) -> i32 {
    let Some(embedded) = template(event) else {
        eprintln!(
            "usage: tillandsias-plan discipline hook <{}> [git hook args...]",
            CLIENT_EVENTS.join("|")
        );
        return 2;
    };
    let ov = override_path(root, event);
    let (source, name) = match std::fs::read_to_string(&ov) {
        Ok(s) => (s, ov.display().to_string()),
        Err(_) => (embedded.to_string(), format!("embedded:{event}")),
    };
    let _ = std::env::set_current_dir(root);
    if std::env::var_os("TILLANDSIAS_PLAN_BIN").is_none()
        && let Ok(exe) = std::env::current_exe()
    {
        // SAFETY: single-threaded at this point; the variable is read by the
        // Lua environment built below.
        unsafe { std::env::set_var("TILLANDSIAS_PLAN_BIN", exe) };
    }
    let plan = std::env::var("TILLANDSIAS_PLAN_BIN").unwrap_or_else(|_| "tillandsias-plan".into());
    let verdict = (|| -> Result<Option<String>, String> {
        let lua = crate::lua_predicate::build_environment(
            crate::lua_predicate::PredicateClass::Observing,
        )
        .map_err(|e| e.to_string())?;
        let arg = lua.create_table().map_err(|e| e.to_string())?;
        let set = |i: i64, v: &str| arg.set(i, v).map_err(|e| e.to_string());
        set(0, event)?;
        set(1, &plan)?;
        set(
            2,
            &std::env::var("TILLANDSIAS_HOST_KIND").unwrap_or_default(),
        )?;
        set(3, &std::env::var("OS").unwrap_or_default())?;
        for (i, a) in git_args.iter().enumerate() {
            set(4 + i as i64, a)?;
        }
        lua.globals().set("arg", arg).map_err(|e| e.to_string())?;
        let values: mlua::MultiValue = lua
            .load(&source)
            .set_name(format!("={name}"))
            .eval()
            .map_err(|e| e.to_string())?;
        Ok(values.into_iter().next().and_then(|v| match v {
            mlua::Value::String(s) => s.to_str().ok().map(|s| s.to_string()),
            _ => None,
        }))
    })();
    let line = match verdict {
        Ok(Some(v)) => v,
        Ok(None) => format!("blocked:hook:{event}:no-verdict"),
        Err(e) => {
            eprintln!("  {name}: {e}");
            format!("blocked:hook:{event}:lua-error")
        }
    };
    // An ok: verdict is silent: these hooks run on every commit and push in
    // someone else's project, and a line each time is noise, not information.
    // TILLANDSIAS_HOOK_VERDICTS=1 prints it (fixtures, debugging). Advisories
    // and refusals always print; they carry the affordance.
    let is_ok = line.starts_with("ok:");
    if !is_ok || std::env::var("TILLANDSIAS_HOOK_VERDICTS").as_deref() == Ok("1") {
        println!("{line}");
    }
    if is_ok || line.starts_with("advised:") || line.starts_with("warn:") {
        0
    } else {
        1
    }
}
