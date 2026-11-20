//! ORDER 2115-jkdv — `tillandsias-plan lock run`: serialize destructive or
//! shared-resource smoke/e2e work across concurrent agents on one host.
//!
//! Replaces scripts/with-smoke-lock.sh (coordinator ruling 2026-11-19, option
//! 1). The shell wrapper's contract is kept, and the ruling's constraints are
//! structural here rather than spelled in shell:
//!
//! * THE CHILD NEVER HOLDS THE LOCK. The lock file is opened by std, which sets
//!   O_CLOEXEC, so the payload and every descendant (a launched forge agent
//!   session) start without the fd. The shell spelled this `"$@" 9>&-`: an
//!   orphaned descendant that inherited fd 9 kept the flock held for up to its
//!   own 90-minute cap and deadlocked the next gate for 16 minutes (order 283).
//!   Only this process's lifetime holds the lease; if it dies, the kernel
//!   releases the lock.
//! * THE CHILD INHERITS THE TTY, STDIN, STDOUT AND STDERR. Nothing is captured
//!   or framed; an hours-long interactive e2e payload behaves as if run bare.
//! * THE TIMEOUT IS OPTIONAL AND UNCAPPED. `--timeout <secs>` bounds the WAIT
//!   for the lock only (exit 75 when it elapses); `--timeout none` waits
//!   forever. The payload itself is never timed out here.
//!
//! Environment defaults (unchanged from the shell): TILLANDSIAS_SMOKE_LOCK_NAME
//! (smoke-e2e), TILLANDSIAS_SMOKE_LOCK_ROOT (${XDG_RUNTIME_DIR:-/tmp}/tillandsias-locks),
//! TILLANDSIAS_SMOKE_LOCK_TIMEOUT_SECS (7200), TILLANDSIAS_SMOKE_LOCK_LOG.
//!
//! Exit codes: the payload's own code (128+signal when it was killed);
//! 64 usage; 75 lock wait timed out; 71 the lock could not be opened.

#[cfg(unix)]
use std::fs::File;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

pub const USAGE: &str = "usage: tillandsias-plan lock run [--name NAME] [--timeout SECS|none] [--root DIR] [--log FILE] -- COMMAND [ARG...]";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LockRun {
    pub name: String,
    pub root: PathBuf,
    /// `None` waits forever.
    pub timeout: Option<u64>,
    pub log: Option<PathBuf>,
    pub command: Vec<String>,
}

fn env_nonempty(k: &str) -> Option<String> {
    std::env::var(k).ok().filter(|v| !v.is_empty())
}

fn parse_timeout(v: &str) -> Result<Option<u64>, String> {
    if v == "none" {
        return Ok(None);
    }
    v.parse::<u64>()
        .map(Some)
        .map_err(|_| format!("lock timeout must be an integer or none: {v}"))
}

fn valid_name(n: &str) -> bool {
    !n.is_empty()
        && n.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
}

/// Parse the arguments after `lock run`.
pub fn parse(args: &[String]) -> Result<LockRun, String> {
    let mut name =
        env_nonempty("TILLANDSIAS_SMOKE_LOCK_NAME").unwrap_or_else(|| "smoke-e2e".into());
    let mut root = env_nonempty("TILLANDSIAS_SMOKE_LOCK_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env_nonempty("XDG_RUNTIME_DIR").unwrap_or_else(|| "/tmp".into()))
                .join("tillandsias-locks")
        });
    let mut timeout = parse_timeout(
        &env_nonempty("TILLANDSIAS_SMOKE_LOCK_TIMEOUT_SECS").unwrap_or_else(|| "7200".into()),
    )?;
    let mut log = env_nonempty("TILLANDSIAS_SMOKE_LOCK_LOG").map(PathBuf::from);
    let mut i = 0;
    while i < args.len() {
        let value = || args.get(i + 1).cloned().ok_or_else(|| USAGE.to_string());
        match args[i].as_str() {
            "--name" => name = value()?,
            "--timeout" => timeout = parse_timeout(&value()?)?,
            "--root" => root = PathBuf::from(value()?),
            "--log" => log = Some(PathBuf::from(value()?)),
            "--" => {
                let command = args[i + 1..].to_vec();
                if command.is_empty() {
                    return Err(USAGE.into());
                }
                if !valid_name(&name) {
                    return Err(format!("lock name contains unsupported characters: {name}"));
                }
                return Ok(LockRun {
                    name,
                    root,
                    timeout,
                    log,
                    command,
                });
            }
            _ => return Err(USAGE.into()),
        }
        i += 2;
    }
    Err(USAGE.into())
}

fn utc_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn log_line(run: &LockRun, msg: &str) {
    let line = format!("{} smoke_lock[{}] {}", utc_now(), run.name, msg);
    eprintln!("{line}");
    if let Some(path) = &run.log {
        if let Some(dir) = path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(f, "{line}");
        }
    }
}

fn holder_text(command: &[String]) -> String {
    let cwd = std::env::current_dir()
        .and_then(|p| p.canonicalize())
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    format!(
        "pid={}\nhost={}\ncwd={}\ncommand={}\nacquired_at={}\n",
        std::process::id(),
        crate::command_policy::this_host(),
        cwd,
        command.join(" "),
        utc_now()
    )
}

#[cfg(unix)]
fn signal_code(status: &std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    128 + status.signal().unwrap_or(0)
}

#[cfg(not(unix))]
fn signal_code(_: &std::process::ExitStatus) -> i32 {
    1
}

/// Run the payload with stdio inherited and return its exit code.
fn run_child(command: &[String]) -> i32 {
    match Command::new(&command[0]).args(&command[1..]).status() {
        Ok(status) => status.code().unwrap_or_else(|| signal_code(&status)),
        Err(e) => {
            eprintln!("lock run: cannot start {}: {e}", command[0]);
            if e.kind() == std::io::ErrorKind::NotFound {
                127
            } else {
                126
            }
        }
    }
}

fn deadline_passed(start: Instant, timeout: Option<u64>) -> bool {
    matches!(timeout, Some(t) if start.elapsed() >= Duration::from_secs(t))
}

#[cfg(unix)]
fn try_flock(file: &File) -> bool {
    use std::os::unix::io::AsRawFd;
    // SAFETY: a valid, open fd owned by `file` for the duration of the call.
    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0 }
}

/// flock(2) on `<root>/<name>.lock`. The returned File holds the lease.
#[cfg(unix)]
fn acquire(run: &LockRun) -> Result<Option<(File, PathBuf)>, i32> {
    let path = run.root.join(format!("{}.lock", run.name));
    // std opens with O_CLOEXEC: the payload never inherits this fd.
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&path)
        .map_err(|e| {
            eprintln!("lock run: cannot open {}: {e}", path.display());
            71
        })?;
    let t = run
        .timeout
        .map(|t| format!("{t}s"))
        .unwrap_or_else(|| "none".into());
    log_line(run, &format!("waiting path={} timeout={t}", path.display()));
    let start = Instant::now();
    loop {
        if try_flock(&file) {
            return Ok(Some((file, path)));
        }
        if deadline_passed(start, run.timeout) {
            log_line(run, &format!("timeout path={}", path.display()));
            return Ok(None);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// Run `run.command` under the named lock. Returns the process exit code.
pub fn execute(run: &LockRun) -> i32 {
    if let Err(e) = fs::create_dir_all(&run.root) {
        eprintln!("lock run: cannot create {}: {e}", run.root.display());
        return 71;
    }
    #[cfg(unix)]
    {
        let (mut file, path) = match acquire(run) {
            Ok(Some(held)) => held,
            Ok(None) => return 75,
            Err(rc) => return rc,
        };
        let _ = file.set_len(0);
        let _ = file.write_all(holder_text(&run.command).as_bytes());
        let _ = file.flush();
        log_line(run, &format!("acquired path={}", path.display()));
        let rc = run_child(&run.command);
        log_line(run, &format!("released path={} exit={rc}", path.display()));
        drop(file);
        rc
    }
    #[cfg(not(unix))]
    {
        execute_lockdir(run)
    }
}

/// No flock(2): an atomic mkdir lease, removed when the payload ends.
#[cfg(not(unix))]
fn execute_lockdir(run: &LockRun) -> i32 {
    let dir = run.root.join(format!("{}.lockdir", run.name));
    let t = run
        .timeout
        .map(|t| format!("{t}s"))
        .unwrap_or_else(|| "none".into());
    log_line(
        run,
        &format!("waiting path={} timeout={t} fallback=mkdir", dir.display()),
    );
    let start = Instant::now();
    while fs::create_dir(&dir).is_err() {
        if deadline_passed(start, run.timeout) {
            log_line(
                run,
                &format!("timeout path={} fallback=mkdir", dir.display()),
            );
            return 75;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    let _ = fs::write(dir.join("holder"), holder_text(&run.command));
    log_line(
        run,
        &format!("acquired path={} fallback=mkdir", dir.display()),
    );
    let rc = run_child(&run.command);
    log_line(
        run,
        &format!("released path={} exit={rc} fallback=mkdir", dir.display()),
    );
    let _ = fs::remove_dir_all(&dir);
    rc
}

/// Entry point for `tillandsias-plan lock <verb> ...`.
pub fn main(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        Some("run") => match parse(&args[1..]) {
            Ok(run) => execute(&run),
            Err(msg) => {
                eprintln!("{msg}");
                64
            }
        },
        _ => {
            eprintln!("{USAGE}");
            64
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn parse_requires_a_command_after_the_separator() {
        assert!(parse(&s(&["--name", "x"])).is_err());
        assert!(parse(&s(&["--name", "x", "--"])).is_err());
        let r = parse(&s(&["--name", "x", "--timeout", "none", "--", "true"])).unwrap();
        assert_eq!(r.name, "x");
        assert_eq!(r.timeout, None);
        assert_eq!(r.command, s(&["true"]));
    }

    #[test]
    fn parse_refuses_a_name_that_escapes_the_lock_root() {
        assert!(parse(&s(&["--name", "../x", "--", "true"])).is_err());
        assert!(parse(&s(&["--timeout", "soon", "--", "true"])).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn a_second_holder_times_out_while_the_first_holds_the_lease() {
        let root = std::env::temp_dir().join(format!("lockrun-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let held = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .open(root.join("t.lock"))
            .unwrap();
        assert!(try_flock(&held));
        let run = LockRun {
            name: "t".into(),
            root: root.clone(),
            timeout: Some(0),
            log: None,
            command: s(&["true"]),
        };
        assert_eq!(execute(&run), 75);
        drop(held);
        assert_eq!(execute(&run), 0);
        let _ = fs::remove_dir_all(&root);
    }
}
