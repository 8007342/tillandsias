// @trace order:2106-scrt
// scratch.*: file verbs over ONE declared scratch root outside the repo-rooted
// fs.* doors, plus an advisory flock. Driven through the real
// `tillandsias-plan script run` with a scratch repo root (TILLANDSIAS_REPO_ROOT),
// never the checkout. Pre-fix every arm fails: `scratch` is nil, so the script
// dies with "attempt to index a nil value (global 'scratch')".
#![cfg(unix)]
use std::fs;
use std::path::Path;
use std::process::{Command, Output};

fn command(repo: &Path, tmp: &Path) -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"));
    c.current_dir(repo)
        .env("TILLANDSIAS_REPO_ROOT", repo)
        .env("TMPDIR", tmp)
        .env_remove("CARGO_TARGET_DIR")
        .env_remove("TILLANDSIAS_POLICY_REGIME")
        .env_remove("TILLANDSIAS_HOST_KIND")
        .env_remove("CI");
    c
}

struct Env {
    _d: tempfile::TempDir,
    repo: std::path::PathBuf,
    tmp: std::path::PathBuf,
    outside: std::path::PathBuf,
}

/// A fake repo, a fake $TMPDIR beside it, and a directory that is neither.
fn env() -> Env {
    let d = tempfile::tempdir().unwrap();
    let base = d.path().canonicalize().unwrap();
    let repo = base.join("repo");
    let tmp = base.join("tmp");
    let outside = base.join("outside");
    for p in [&repo, &tmp, &outside] {
        fs::create_dir_all(p).unwrap();
    }
    fs::create_dir_all(repo.join(".git")).unwrap();
    Env {
        _d: d,
        repo,
        tmp,
        outside,
    }
}

fn run(e: &Env, code: &str) -> Output {
    let p = e.repo.join("t.lua");
    fs::write(&p, code).unwrap();
    command(&e.repo, &e.tmp)
        .args(["script", "run"])
        .arg(p)
        .output()
        .unwrap()
}

fn detail(o: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

fn lua_str(p: &Path) -> String {
    format!("{:?}", p.display().to_string())
}

#[test]
fn a_root_under_tmpdir_gets_every_verb() {
    let e = env();
    let root = e.tmp.join("s1");
    let o = run(
        &e,
        &format!(
            r#"
local r = scratch.declare({root})
scratch.mkdir("d/e")
scratch.write("d/e/f.txt", "hi")
scratch.chmod("d/e/f.txt", tonumber("700", 8))
local files, dirs = scratch.list("d/e")
assert(#files == 1 and files[1] == "f.txt", "list files")
local _, top = scratch.list(".")
assert(#top == 1 and top[1] == "d", "list dirs")
assert(scratch.read("d/e/f.txt") == "hi", "read")
assert(scratch.rm("d") == true and not scratch.exists("d"), "rm tree")
verdict.ok("scratch", r)
"#,
            root = lua_str(&root)
        ),
    );
    assert!(o.status.success(), "{}", detail(&o));
}

#[test]
fn a_root_outside_every_allowed_base_is_refused() {
    let e = env();
    let o = run(
        &e,
        &format!(
            r#"
local ok, msg = pcall(scratch.declare, {p})
assert(not ok and tostring(msg):find("not under", 1, true), tostring(msg))
verdict.ok("scratch")
"#,
            p = lua_str(&e.outside.join("x"))
        ),
    );
    assert!(o.status.success(), "{}", detail(&o));
    assert!(
        !e.outside.join("x").exists(),
        "a refused root must not be created"
    );
}

#[test]
fn a_dotdot_escape_is_refused_for_every_verb() {
    let e = env();
    let o = run(
        &e,
        &format!(
            r#"
scratch.declare({root})
for _, f in ipairs({{
    function() scratch.write("../../outside/pwned", "x") end,
    function() scratch.mkdir("../../outside/d") end,
    function() scratch.rm("../../outside") end,
    function() scratch.chmod("../../outside", 511) end,
    function() scratch.list("..") end,
    function() scratch.write({abs}, "x") end,
}}) do
    local ok, msg = pcall(f)
    assert(not ok and tostring(msg):find("refused", 1, true), tostring(msg))
end
verdict.ok("scratch")
"#,
            root = lua_str(&e.tmp.join("s2")),
            abs = lua_str(&e.outside.join("pwned2"))
        ),
    );
    assert!(o.status.success(), "{}", detail(&o));
    assert!(
        fs::read_dir(&e.outside).unwrap().next().is_none(),
        "nothing may land outside"
    );
}

#[test]
fn a_symlink_escape_is_refused() {
    let e = env();
    let root = e.tmp.join("s3");
    fs::create_dir_all(&root).unwrap();
    std::os::unix::fs::symlink(&e.outside, root.join("link")).unwrap();
    fs::write(e.outside.join("secret"), "s").unwrap();
    std::os::unix::fs::symlink(e.outside.join("secret"), root.join("filelink")).unwrap();
    let o = run(
        &e,
        &format!(
            r#"
scratch.declare({root})
for _, f in ipairs({{
    function() scratch.write("link/pwned", "x") end,
    function() scratch.mkdir("link/d") end,
    function() scratch.read("link/secret") end,
    function() scratch.list("link") end,
    function() scratch.read("filelink") end,
    function() scratch.write("filelink", "x") end,
    function() scratch.chmod("filelink", 511) end,
}}) do
    local ok, msg = pcall(f)
    assert(not ok and tostring(msg):find("refused", 1, true), tostring(msg))
end
-- removing the LINK is fine and leaves its target alone
assert(scratch.rm("link") == true)
verdict.ok("scratch")
"#,
            root = lua_str(&root)
        ),
    );
    assert!(o.status.success(), "{}", detail(&o));
    assert_eq!(fs::read_to_string(e.outside.join("secret")).unwrap(), "s");
    assert!(!e.outside.join("pwned").exists());
}

#[test]
fn lock_contention_times_out_and_a_free_lock_is_taken() {
    let e = env();
    let root = e.tmp.join("s4");
    fs::create_dir_all(&root).unwrap();
    let lockp = root.join("the.lock");
    let held = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&lockp)
        .unwrap();
    use std::os::unix::io::AsRawFd;
    // SAFETY: flock on an owned, valid fd.
    assert_eq!(unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_SH) }, 0);
    let o = run(
        &e,
        &format!(
            r#"
scratch.declare({root})
local t0 = time.now_ms()
local h, why = scratch.lock("the.lock", {{ timeout_ms = 300 }})
local waited = time.now_ms() - t0
assert(h == nil and why == "timeout", "exclusive under a shared holder must time out")
assert(waited >= 280, "waited only " .. waited .. " ms")
local s = scratch.lock("the.lock", {{ shared = true, timeout_ms = 0 }})
assert(s ~= nil and s:held(), "a second shared lock coexists")
s:release()
assert(not s:held())
verdict.ok("scratch", waited)
"#,
            root = lua_str(&root)
        ),
    );
    assert!(o.status.success(), "{}", detail(&o));
    drop(held);
    let o = run(
        &e,
        &format!(
            r#"
scratch.declare({root})
local h = scratch.lock("the.lock", {{ timeout_ms = 0 }})
assert(h ~= nil, "a free lock is taken at once")
verdict.ok("scratch")
"#,
            root = lua_str(&root)
        ),
    );
    assert!(o.status.success(), "{}", detail(&o));
}

#[test]
fn a_second_root_is_refused_and_the_root_is_never_removed() {
    let e = env();
    let o = run(
        &e,
        &format!(
            r#"
scratch.declare({a})
local ok, msg = pcall(scratch.declare, {b})
assert(not ok and tostring(msg):find("already declared", 1, true), tostring(msg))
local ok2, msg2 = pcall(scratch.rm, ".")
assert(not ok2 and tostring(msg2):find("never removed", 1, true), tostring(msg2))
verdict.ok("scratch")
"#,
            a = lua_str(&e.tmp.join("a")),
            b = lua_str(&e.tmp.join("b"))
        ),
    );
    assert!(o.status.success(), "{}", detail(&o));
    assert!(e.tmp.join("a").is_dir());
}
