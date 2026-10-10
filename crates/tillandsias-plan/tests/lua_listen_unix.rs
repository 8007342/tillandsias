// @trace order:1576-luas
// fs.listen_unix: the smallest socket primitive a Lua fixture needs. Driven
// through the real `tillandsias-plan script run` against a scratch repo root
// (TILLANDSIAS_REPO_ROOT), never the checkout. Pre-fix every arm fails: the
// runtime had no socket primitive, so `fs.listen_unix` is nil and the script
// errors with "attempt to call a nil value".
use std::fs;
use std::path::Path;
use std::process::{Command, Output};

fn command(root: &Path) -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"));
    c.current_dir(root)
        .env("TILLANDSIAS_REPO_ROOT", root)
        .env_remove("TILLANDSIAS_POLICY_REGIME")
        .env_remove("TILLANDSIAS_HOST_KIND")
        .env_remove("CI");
    c
}

fn run(root: &Path, code: &str) -> Output {
    let p = root.join("sock.lua");
    fs::write(&p, code).unwrap();
    command(root)
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

/// A short scratch root under /tmp: the macOS TMPDIR alone is 49 bytes, which
/// leaves too little of sun_path for a nested socket (measured on 1428-3kdu).
fn root() -> tempfile::TempDir {
    let d = tempfile::Builder::new()
        .prefix("lsu")
        .tempdir_in(if Path::new("/tmp").is_dir() {
            Path::new("/tmp").to_path_buf()
        } else {
            std::env::temp_dir()
        })
        .unwrap();
    fs::create_dir_all(d.path().join(".git")).unwrap();
    fs::create_dir_all(d.path().join("run")).unwrap();
    d
}

/// The socket is REAL (the kernel reports a socket inode while the handle is
/// held) and is unlinked when the handle is closed.
#[cfg(unix)]
#[test]
fn listen_unix_binds_a_real_socket_and_close_unlinks_it() {
    let d = root();
    let o = run(
        d.path(),
        r#"
local h = fs.listen_unix("run/p.sock")
local held = proc.run{argv={"test", "-S", "run/p.sock"}}
h:close()
local after = proc.run{argv={"test", "-e", "run/p.sock"}}
if held.ok and not after.ok then
    verdict.emit("ok:listen-unix:bound-then-unlinked", 0)
else
    verdict.emit("violation:listen-unix:held=" .. tostring(held.ok) .. ":after=" .. tostring(after.ok), 1)
end
"#,
    );
    assert!(o.status.success(), "{}", detail(&o));
    assert!(
        String::from_utf8_lossy(&o.stdout).contains("ok:listen-unix:bound-then-unlinked"),
        "{}",
        detail(&o)
    );
}

/// Without an explicit close, the handle's socket goes when the script ends.
#[cfg(unix)]
#[test]
fn listen_unix_unlinks_when_the_script_ends() {
    let d = root();
    let o = run(
        d.path(),
        r#"
local h = fs.listen_unix("run/q.sock")
verdict.emit("ok:listen-unix:held", 0)
"#,
    );
    assert!(o.status.success(), "{}", detail(&o));
    assert!(
        !d.path().join("run/q.sock").exists(),
        "the socket must not outlive the script: {}",
        detail(&o)
    );
}

/// Contained like fs.write: a path outside the repository root is refused.
#[cfg(unix)]
#[test]
fn listen_unix_refuses_a_path_outside_the_root() {
    let d = root();
    let outside = tempfile::tempdir().unwrap();
    let target = outside.path().join("x.sock");
    let o = run(
        d.path(),
        &format!(
            r#"
local ok, err = pcall(fs.listen_unix, "{}")
if not ok and tostring(err):find("outside the repository root", 1, true) then
    verdict.emit("ok:listen-unix:refused-outside", 0)
else
    verdict.emit("violation:listen-unix:admitted-outside", 1)
end
"#,
            target.display()
        ),
    );
    assert!(o.status.success(), "{}", detail(&o));
    assert!(!target.exists(), "nothing may be bound outside the root");
}

/// An over-long path is refused BY NAME, before the kernel's unnamed error.
#[cfg(unix)]
#[test]
fn listen_unix_names_an_over_long_path() {
    let d = root();
    let deep = "run/".to_string() + &"d".repeat(120) + ".sock";
    let o = run(
        d.path(),
        &format!(
            r#"
local ok, err = pcall(fs.listen_unix, "{deep}")
if not ok and tostring(err):find("sun-path-too-long", 1, true) then
    verdict.emit("ok:listen-unix:named-too-long", 0)
else
    verdict.emit("violation:listen-unix:" .. tostring(err), 1)
end
"#
        ),
    );
    assert!(o.status.success(), "{}", detail(&o));
}

/// Off Unix the primitive says `unsupported`, which is what the ported fixture
/// turns into its named skip.
#[cfg(not(unix))]
#[test]
fn listen_unix_is_unsupported_off_unix() {
    let d = root();
    let o = run(
        d.path(),
        r#"
local ok, err = pcall(fs.listen_unix, "run/p.sock")
if not ok and tostring(err):find("unsupported", 1, true) then
    verdict.emit("ok:listen-unix:unsupported", 0)
else
    verdict.emit("violation:listen-unix:supported-off-unix", 1)
end
"#,
    );
    assert!(o.status.success(), "{}", detail(&o));
}
