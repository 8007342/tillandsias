// @trace order:2110-unst
// proc.run / proc.spawn `unset = {...}`: the named variables are absent from
// the child whatever added them. Pre-fix the child env MERGED into an inherited
// base that always carries HOME, so a fixture that omitted HOME still passed it
// (measured on darwin 2026-11-20 porting 2109-umac). Pre-fix every arm fails:
// `unset` is an unknown proc field and raises.
#![cfg(unix)]
use std::fs;
use std::process::Output;

fn run(code: &str) -> Output {
    let d = tempfile::tempdir().unwrap();
    let repo = d.path().canonicalize().unwrap();
    fs::create_dir_all(repo.join(".git")).unwrap();
    let p = repo.join("t.lua");
    fs::write(&p, code).unwrap();
    std::process::Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .current_dir(&repo)
        .env("TILLANDSIAS_REPO_ROOT", &repo)
        .env("HOME", "/home-2110-unst")
        .args(["script", "run"])
        .arg(&p)
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

#[test]
fn omitting_home_still_passes_it_which_is_why_unset_exists() {
    // The control: the hazard the packet names. Without `unset`, HOME reaches
    // the child even though the call's env table leaves it out.
    let o = run(r#"
local r = proc.run{ argv = { "/usr/bin/env" }, env = { PATH = "/usr/bin:/bin" } }
assert(r.stdout:find("HOME=/home-2110-unst", 1, true), "control: HOME was expected to be inherited")
verdict.ok("unset")
"#);
    assert!(o.status.success(), "{}", detail(&o));
}

#[test]
fn proc_run_unset_removes_an_inherited_variable() {
    let o = run(r#"
local r = proc.run{ argv = { "/usr/bin/env" }, env = { PATH = "/usr/bin:/bin" }, unset = { "HOME" } }
assert(r.ok, "env ran")
assert(not r.stdout:find("\nHOME=", 1, true) and r.stdout:sub(1, 5) ~= "HOME=", "HOME reached the child: " .. r.stdout)
assert(r.stdout:find("PATH=/usr/bin:/bin", 1, true), "the rest of the env is untouched")
verdict.ok("unset")
"#);
    assert!(o.status.success(), "{}", detail(&o));
}

#[test]
fn proc_spawn_unset_removes_an_inherited_variable() {
    let o = run(r#"
local h = proc.spawn{ argv = { "/usr/bin/env" }, unset = { "HOME" }, timeout_ms = 10000 }
local r = h:wait()
assert(r.ok, "env ran")
assert(not r.stdout:find("\nHOME=", 1, true) and r.stdout:sub(1, 5) ~= "HOME=", "HOME reached the child: " .. r.stdout)
verdict.ok("unset")
"#);
    assert!(o.status.success(), "{}", detail(&o));
}

#[test]
fn unset_beats_a_fixed_variable_and_contradictions_raise() {
    // LC_ALL is one the builder FIXES (ENV_FIXED); unset still removes it.
    let o = run(r#"
local r = proc.run{ argv = { "/usr/bin/env" }, unset = { "LC_ALL" } }
assert(not r.stdout:find("LC_ALL=", 1, true), "a fixed variable came back: " .. r.stdout)
local ok, msg = pcall(proc.run, { argv = { "/usr/bin/true" }, env = { X = "1" }, unset = { "X" } })
assert(not ok and tostring(msg):find("both set in env and unset", 1, true), tostring(msg))
local ok2, msg2 = pcall(proc.run, { argv = { "/usr/bin/true" }, unset = "HOME" })
assert(not ok2 and tostring(msg2):find("unset must be a list", 1, true), tostring(msg2))
verdict.ok("unset")
"#);
    assert!(o.status.success(), "{}", detail(&o));
}
