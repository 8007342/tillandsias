// @trace order:2106-scrt
//
// scratch_root.rs — `scratch.*`: file verbs over ONE declared scratch root
// OUTSIDE the repo-rooted `fs.*` doors, plus an advisory lock.
//
// WHY. `fs.*` is rooted at the checkout, so a fixture that sandboxes under
// $TMPDIR, or a tool that works in a shared CARGO_TARGET_DIR (the darwin
// object prune), could only reach its files by proc.run-ing rm/chmod/ls,
// which keeps the shell it was meant to replace. This door gives those
// scripts native verbs without widening `fs.*`.
//
// THE CONTRACT.
//   scratch.declare(path)             -> abs root (created if absent)
//       Once per script. The root must resolve, after canonicalisation, at or
//       under one of: $TMPDIR (std::env::temp_dir), <repo>/target, or
//       $CARGO_TARGET_DIR. Anything else is refused. A second declare of a
//       different root is refused.
//   scratch.root()                    -> the declared root, or nil
//   scratch.mkdir(p)  scratch.write(p, data)  scratch.read(p)
//   scratch.list(p)                   -> files, dirs (sorted names; symlinks
//                                        are in neither list and never followed)
//   scratch.exists(p)                 -> bool (lstat: a dangling link exists)
//   scratch.rm(p)                     file, symlink (the link, not its target)
//                                     or directory tree; never the root itself
//   scratch.chmod(p, mode)            mode is an integer, e.g. tonumber("755", 8)
//   scratch.lock(p, {shared=bool, timeout_ms=n})
//                                     -> handle, or nil + "timeout"
//       flock(2) on a file under the root. timeout_ms=0 is one non-blocking
//       try. The handle has :release(); it is released at the latest when the
//       script ends. A BSD flock lives on the open file, so it interlocks with
//       perl's/flock(1)'s locks on the same path from other processes.
//
// EVERY path (relative to the root, or absolute) is refused if it leaves the
// root lexically (`..`) or through a symlink: the deepest EXISTING ancestor is
// canonicalised and must stay under the canonical root, and a write, chmod or
// lock never follows a symlink at the final component.

use mlua::prelude::*;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex};

fn err<T>(verb: &str, msg: impl std::fmt::Display) -> LuaResult<T> {
    Err(LuaError::RuntimeError(format!(
        "scratch.{verb}: refused — {msg}"
    )))
}

fn canon(p: &Path) -> std::io::Result<PathBuf> {
    p.canonicalize()
}

/// The canonical directories a root may sit at or under.
fn allowed_bases() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Ok(t) = canon(&std::env::temp_dir()) {
        v.push(t);
    }
    if let Ok(repo) = crate::lua_predicate::find_repo_root() {
        let t = repo.join("target");
        if let Ok(t) = canon(&t) {
            v.push(t);
        }
    }
    if let Some(c) = std::env::var_os("CARGO_TARGET_DIR")
        && let Ok(t) = canon(Path::new(&c))
    {
        v.push(t);
    }
    v
}

/// Lexically normalise: drop `.`, resolve `..` against what precedes it, and
/// report whether a `..` tried to climb above the start.
fn lexical(p: &Path) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    return None;
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    Some(out)
}

/// Canonicalise the deepest existing ancestor of `p`, then re-append the
/// missing tail. The result is where `p` would really land.
fn resolve_through_existing(p: &Path) -> std::io::Result<PathBuf> {
    let mut existing = p.to_path_buf();
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    loop {
        if std::fs::symlink_metadata(&existing).is_ok() {
            break;
        }
        match (existing.file_name(), existing.parent()) {
            (Some(name), Some(parent)) => {
                tail.push(name.to_os_string());
                existing = parent.to_path_buf();
            }
            _ => break,
        }
    }
    let mut r = canon(&existing)?;
    for t in tail.iter().rev() {
        r.push(t);
    }
    Ok(r)
}

#[derive(Default)]
struct State {
    root: Option<PathBuf>,
}

/// Resolve a script path against the declared root and refuse any escape.
/// `follow_last`: whether the final component may be a symlink that is
/// followed (read/list/chmod check the resolved target; rm and exists do not
/// follow it at all; write and lock refuse a link there).
fn resolve(state: &State, verb: &str, p: &str, follow_last: bool) -> LuaResult<PathBuf> {
    let Some(root) = state.root.clone() else {
        return err(
            verb,
            "no scratch root declared (call scratch.declare first)",
        );
    };
    let joined = if Path::new(p).is_absolute() {
        PathBuf::from(p)
    } else {
        root.join(p)
    };
    let Some(lex) = lexical(&joined) else {
        return err(verb, format!("'{p}' climbs above the filesystem root"));
    };
    // The root itself (`.`): its parent is outside by definition.
    if lex == root {
        return Ok(root);
    }
    // Whatever the final component is, its PARENT must resolve under the root.
    let (parent, name) = match (lex.parent(), lex.file_name()) {
        (Some(pa), Some(n)) => (pa.to_path_buf(), n.to_os_string()),
        _ => return err(verb, format!("'{p}' has no file name")),
    };
    let parent_real = resolve_through_existing(&parent)
        .or_else(|e| err(verb, format!("cannot resolve '{p}': {e}")))?;
    if !parent_real.starts_with(&root) && parent_real != root {
        return err(
            verb,
            format!("'{p}' is outside the scratch root {}", root.display()),
        );
    }
    let candidate = parent_real.join(&name);
    if follow_last
        && let Ok(md) = std::fs::symlink_metadata(&candidate)
        && md.file_type().is_symlink()
    {
        let real = canon(&candidate)
            .or_else(|e| err(verb, format!("'{p}' is a dangling symlink: {e}")))?;
        if !real.starts_with(&root) {
            return err(
                verb,
                format!("'{p}' is a symlink that escapes the scratch root"),
            );
        }
        return Ok(real);
    }
    if !candidate.starts_with(&root) {
        return err(
            verb,
            format!("'{p}' is outside the scratch root {}", root.display()),
        );
    }
    Ok(candidate)
}

fn is_link(p: &Path) -> bool {
    std::fs::symlink_metadata(p)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
}

/// A held flock. Dropping the file releases the lock.
struct LockHandle {
    file: Option<std::fs::File>,
}

impl LuaUserData for LockHandle {
    fn add_methods<M: LuaUserDataMethods<Self>>(methods: &mut M) {
        methods.add_method_mut("release", |_, this, ()| {
            this.file = None;
            Ok(())
        });
        methods.add_method("held", |_, this, ()| Ok(this.file.is_some()));
    }
}

#[cfg(unix)]
fn try_flock(f: &std::fs::File, shared: bool) -> std::io::Result<bool> {
    use std::os::unix::io::AsRawFd;
    let op = if shared { libc::LOCK_SH } else { libc::LOCK_EX } | libc::LOCK_NB;
    // SAFETY: flock on a valid, owned fd; no memory is passed.
    let rc = unsafe { libc::flock(f.as_raw_fd(), op) };
    if rc == 0 {
        return Ok(true);
    }
    let e = std::io::Error::last_os_error();
    if e.raw_os_error() == Some(libc::EWOULDBLOCK) {
        Ok(false)
    } else {
        Err(e)
    }
}

#[cfg(not(unix))]
fn try_flock(_f: &std::fs::File, _shared: bool) -> std::io::Result<bool> {
    Err(std::io::Error::other("scratch.lock is unix-only"))
}

pub(crate) fn install(lua: &Lua) -> LuaResult<()> {
    let state = Arc::new(Mutex::new(State::default()));
    let t = lua.create_table()?;

    let s = state.clone();
    t.set(
        "declare",
        lua.create_function(move |_, p: String| {
            let mut st = s.lock().unwrap();
            let abs = if Path::new(&p).is_absolute() {
                PathBuf::from(&p)
            } else {
                let repo =
                    crate::lua_predicate::find_repo_root().map_err(LuaError::RuntimeError)?;
                repo.join(&p)
            };
            let Some(lex) = lexical(&abs) else {
                return err("declare", format!("'{p}' climbs above the filesystem root"));
            };
            let bases = allowed_bases();
            let under = |real: &Path| bases.iter().any(|b| real.starts_with(b));
            // Judge where it WOULD land before creating anything.
            let would = resolve_through_existing(&lex)
                .or_else(|e| err("declare", format!("cannot resolve '{p}': {e}")))?;
            if !under(&would) {
                return err(
                    "declare",
                    format!("'{p}' is not under $TMPDIR, <repo>/target or $CARGO_TARGET_DIR"),
                );
            }
            std::fs::create_dir_all(&lex)
                .or_else(|e| err("declare", format!("cannot create '{p}': {e}")))?;
            let real = canon(&lex).or_else(|e| err("declare", format!("'{p}': {e}")))?;
            if !under(&real) {
                return err(
                    "declare",
                    format!("'{p}' resolves outside the allowed bases"),
                );
            }
            if let Some(prev) = &st.root
                && *prev != real
            {
                return err(
                    "declare",
                    format!("a scratch root is already declared ({})", prev.display()),
                );
            }
            st.root = Some(real.clone());
            Ok(real.display().to_string())
        })?,
    )?;

    let s = state.clone();
    t.set(
        "root",
        lua.create_function(move |_, ()| {
            Ok(s.lock()
                .unwrap()
                .root
                .as_ref()
                .map(|r| r.display().to_string()))
        })?,
    )?;

    let s = state.clone();
    t.set(
        "mkdir",
        lua.create_function(move |_, p: String| {
            let path = resolve(&s.lock().unwrap(), "mkdir", &p, true)?;
            std::fs::create_dir_all(&path).or_else(|e| err("mkdir", format!("'{p}': {e}")))?;
            // A component created concurrently as a link would show here.
            let root = s.lock().unwrap().root.clone().unwrap();
            let real = canon(&path).or_else(|e| err("mkdir", format!("'{p}': {e}")))?;
            if !real.starts_with(&root) {
                return err("mkdir", format!("'{p}' resolved outside the scratch root"));
            }
            Ok(real.display().to_string())
        })?,
    )?;

    let s = state.clone();
    t.set(
        "write",
        lua.create_function(move |_, (p, data): (String, LuaString)| {
            let path = resolve(&s.lock().unwrap(), "write", &p, false)?;
            if is_link(&path) {
                return err(
                    "write",
                    format!("'{p}' is a symlink; a write would follow it"),
                );
            }
            std::fs::write(&path, data.as_bytes())
                .or_else(|e| err("write", format!("'{p}': {e}")))?;
            Ok(true)
        })?,
    )?;

    let s = state.clone();
    t.set(
        "read",
        lua.create_function(move |lua, p: String| {
            let path = resolve(&s.lock().unwrap(), "read", &p, true)?;
            let bytes = std::fs::read(&path).or_else(|e| err("read", format!("'{p}': {e}")))?;
            lua.create_string(&bytes)
        })?,
    )?;

    let s = state.clone();
    t.set(
        "exists",
        lua.create_function(move |_, p: String| {
            let path = resolve(&s.lock().unwrap(), "exists", &p, false)?;
            Ok(std::fs::symlink_metadata(&path).is_ok())
        })?,
    )?;

    let s = state.clone();
    t.set(
        "list",
        lua.create_function(move |lua, p: String| {
            let path = resolve(&s.lock().unwrap(), "list", &p, true)?;
            let files = lua.create_table()?;
            let dirs = lua.create_table()?;
            let rd = std::fs::read_dir(&path).or_else(|e| err("list", format!("'{p}': {e}")))?;
            let (mut fv, mut dv) = (Vec::new(), Vec::new());
            for e in rd {
                let e = e.or_else(|e| err("list", format!("'{p}': {e}")))?;
                let ft = e
                    .file_type()
                    .or_else(|e| err("list", format!("'{p}': {e}")))?;
                let n = e.file_name().to_string_lossy().into_owned();
                if ft.is_file() {
                    fv.push(n);
                } else if ft.is_dir() {
                    dv.push(n);
                }
            }
            fv.sort();
            dv.sort();
            for (i, n) in fv.into_iter().enumerate() {
                files.set(i + 1, n)?;
            }
            for (i, n) in dv.into_iter().enumerate() {
                dirs.set(i + 1, n)?;
            }
            Ok((files, dirs))
        })?,
    )?;

    let s = state.clone();
    t.set(
        "rm",
        lua.create_function(move |_, p: String| {
            let st = s.lock().unwrap();
            let path = resolve(&st, "rm", &p, false)?;
            if Some(&path) == st.root.as_ref() {
                return err("rm", "the scratch root itself is never removed");
            }
            let md = match std::fs::symlink_metadata(&path) {
                Ok(m) => m,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
                Err(e) => return err("rm", format!("'{p}': {e}")),
            };
            if md.is_dir() {
                std::fs::remove_dir_all(&path)
            } else {
                std::fs::remove_file(&path)
            }
            .or_else(|e| err("rm", format!("'{p}': {e}")))?;
            Ok(true)
        })?,
    )?;

    let s = state.clone();
    t.set(
        "chmod",
        lua.create_function(move |_, (p, mode): (String, u32)| {
            let path = resolve(&s.lock().unwrap(), "chmod", &p, true)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))
                    .or_else(|e| err("chmod", format!("'{p}': {e}")))?;
                Ok(true)
            }
            #[cfg(not(unix))]
            {
                let _ = (path, mode);
                err("chmod", "unix-only")
            }
        })?,
    )?;

    let s = state.clone();
    t.set(
        "lock",
        lua.create_function(move |lua, (p, opts): (String, Option<LuaTable>)| {
            let path = resolve(&s.lock().unwrap(), "lock", &p, false)?;
            if is_link(&path) {
                return err("lock", format!("'{p}' is a symlink"));
            }
            let (shared, timeout_ms) = match &opts {
                Some(o) => (
                    o.get::<Option<bool>>("shared")?.unwrap_or(false),
                    o.get::<Option<u64>>("timeout_ms")?.unwrap_or(0),
                ),
                None => (false, 0),
            };
            let f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .or_else(|e| err("lock", format!("'{p}': {e}")))?;
            let deadline = std::time::Instant::now() + std::time::Duration::from_millis(timeout_ms);
            loop {
                if try_flock(&f, shared).or_else(|e| err("lock", format!("'{p}': {e}")))? {
                    let h = lua.create_userdata(LockHandle { file: Some(f) })?;
                    return Ok((LuaValue::UserData(h), LuaValue::Nil));
                }
                if std::time::Instant::now() >= deadline {
                    return Ok((
                        LuaValue::Nil,
                        LuaValue::String(lua.create_string("timeout")?),
                    ));
                }
                // A bounded retry inside the caller's own deadline: flock(2)
                // has no timed wait, and a blocking call cannot be cancelled.
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        })?,
    )?;

    lua.globals().set("scratch", t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lexical_refuses_a_climb_above_the_start() {
        assert!(lexical(Path::new("a/../..")).is_none());
        assert_eq!(
            lexical(Path::new("/x/./y/../z")).unwrap(),
            PathBuf::from("/x/z")
        );
    }
}
