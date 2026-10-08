//! `tillandsias --swap on|off|status [--prefix DIR] [--user NAME]` — order 1448-kmyn.
//!
//! Operator, 2026-09-27 (calmecacpilli, 8 GB RAM, no checkout): "Should our
//! tillandsias binary have an elevated tillandsias --swap on and tillandsias
//! --swap off to create and enable the swap file and services, and to remove the
//! file to reclaim the space and disable all services. Making sure it all gets
//! removed on uninstall as well."
//!
//! THE BINARY IS THE SOURCE. The assets of the per-launch swap service
//! (1376-8zdz; design plan/issues/forge-memory-swap-architecture-design-2026-09-26.md
//! §9) are embedded from `scripts/forge-swap/` with `include_str!`, and `--swap on`
//! writes exactly what `scripts/install-forge-swap-service.sh` writes, byte for
//! byte (scripts/test-forge-swap-service.sh compares the two trees), so a host
//! with no checkout installs the same service a checkout does.
//!
//! ROOT, ONCE. A live `on`/`off` (no `--prefix`) needs root. Run as a user, it
//! re-executes itself ONCE through `pkexec` with the resolved `--user`; where
//! pkexec is absent or declined it prints the `sudo` line for the operator and
//! exits 1. It never runs sudo itself (the tray never does).
//!
//! `--prefix DIR` installs/removes under DIR and takes NO system action (no
//! groupadd, no systemctl): the hermetic test uses it, with no root.
//!
//! `off` is the removal the uninstall calls (1437-evzi): [`removal_paths`] is
//! the one list, and it covers every path `on` installs (test arm 4).
// @trace order:1448-kmyn, order:1376-8zdz, spec:forge-hot-cold-split

use std::path::{Path, PathBuf};

const HELPER: &str = include_str!("../../../scripts/forge-swap/tillandsias-swap");
const UNIT_TEMPLATE: &str = include_str!("../../../scripts/forge-swap/tillandsias-swap@.service");
const UNIT_GC_SERVICE: &str =
    include_str!("../../../scripts/forge-swap/tillandsias-swap-gc.service");
const UNIT_GC_TIMER: &str = include_str!("../../../scripts/forge-swap/tillandsias-swap-gc.timer");
const POLKIT_RULE: &str = include_str!("../../../scripts/forge-swap/50-tillandsias-swap.rules");
const SWAP_CONF: &str = include_str!("../../../scripts/forge-swap/swap.conf");

pub(crate) const HELPER_PATH: &str = "/usr/local/libexec/tillandsias-swap";
const UNITS_DIR: &str = "/etc/systemd/system";
const POLKIT_PATH: &str = "/etc/polkit-1/rules.d/50-tillandsias-swap.rules";
const CONF_PATH: &str = "/etc/tillandsias/swap.conf";
const GROUP: &str = "tillandsias";
const UNITS: [(&str, &str); 3] = [
    ("tillandsias-swap@.service", UNIT_TEMPLATE),
    ("tillandsias-swap-gc.service", UNIT_GC_SERVICE),
    ("tillandsias-swap-gc.timer", UNIT_GC_TIMER),
];

/// Every path `--swap on` installs, relative to the root (`/` or `--prefix`).
/// `--swap off` removes each of them, and the uninstall reuses this list.
pub(crate) fn removal_paths() -> Vec<&'static str> {
    vec![
        HELPER_PATH,
        "/etc/systemd/system/tillandsias-swap@.service",
        "/etc/systemd/system/tillandsias-swap-gc.service",
        "/etc/systemd/system/tillandsias-swap-gc.timer",
        POLKIT_PATH,
        CONF_PATH,
    ]
}

struct Opts {
    verb: String,
    prefix: Option<PathBuf>,
    user: Option<String>,
}

fn parse(args: &[String]) -> Result<Opts, String> {
    let Some(i) = args.iter().position(|a| a == "--swap") else {
        return Err("usage".into());
    };
    let verb = args.get(i + 1).cloned().unwrap_or_default();
    if !["on", "off", "status"].contains(&verb.as_str()) {
        return Err(format!("unknown-verb:{verb}"));
    }
    let mut prefix = None;
    let mut user = None;
    let mut j = i + 2;
    while j < args.len() {
        match args[j].as_str() {
            "--prefix" => {
                prefix = Some(PathBuf::from(
                    args.get(j + 1).ok_or("prefix-needs-a-value")?,
                ));
                j += 2;
            }
            "--user" => {
                user = Some(args.get(j + 1).ok_or("user-needs-a-value")?.clone());
                j += 2;
            }
            "--debug" => j += 1,
            other => return Err(format!("unknown-argument:{other}")),
        }
    }
    Ok(Opts { verb, prefix, user })
}

fn valid_user(u: &str) -> bool {
    let b = u.as_bytes();
    !b.is_empty()
        && b.len() <= 32
        && (b[0].is_ascii_lowercase() || b[0] == b'_')
        && b[1..]
            .iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_' || *c == b'-')
}

/// The user the polkit rule names: `--user`, else the invoking user behind
/// sudo or pkexec, else `$USER`.
fn resolve_user(explicit: Option<&str>) -> Option<String> {
    if let Some(u) = explicit {
        return Some(u.to_string());
    }
    if let Ok(u) = std::env::var("SUDO_USER") {
        return Some(u);
    }
    // `id -nu` resolves through NSS, like everything else on the host.
    if let Ok(uid) = std::env::var("PKEXEC_UID")
        && uid.parse::<u32>().is_ok()
        && let Ok(out) = std::process::Command::new("id")
            .args(["-nu", &uid])
            .output()
    {
        let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if out.status.success() && !name.is_empty() {
            return Some(name);
        }
    }
    std::env::var("USER").ok()
}

fn root_join(root: &Path, abs: &str) -> PathBuf {
    root.join(abs.trim_start_matches('/'))
}

/// Write `bytes` at `path` with `mode`, only when the content differs, through
/// a temp file and a rename. Returns whether anything changed.
fn write_if_changed(path: &Path, bytes: &[u8], mode: u32) -> std::io::Result<bool> {
    use std::os::unix::fs::PermissionsExt;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let same = std::fs::read(path).map(|b| b == bytes).unwrap_or(false);
    if !same {
        let tmp = path.with_extension("tillandsias-tmp");
        std::fs::write(&tmp, bytes)?;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(mode))?;
        std::fs::rename(&tmp, path)?;
    }
    let cur = std::fs::metadata(path)?.permissions().mode() & 0o7777;
    if cur != mode {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))?;
        return Ok(true);
    }
    Ok(!same)
}

/// Install the service under `root`. `live` = the real `/`: then the helper
/// path is the absolute one and the system actions run; under a prefix the
/// helper path points into the prefix (as the installer's scratch install does)
/// and no system action runs.
fn install(root: &Path, live: bool, user: &str) -> Result<String, String> {
    let helper_path = if live {
        HELPER_PATH.to_string()
    } else {
        root_join(root, HELPER_PATH).display().to_string()
    };
    let io = |what: &str, e: std::io::Error| format!("refused:swap-on:write:{what}:{e}");
    write_if_changed(&root_join(root, HELPER_PATH), HELPER.as_bytes(), 0o755)
        .map_err(|e| io("helper", e))?;
    for (name, body) in UNITS {
        let p = root_join(root, UNITS_DIR).join(name);
        write_if_changed(&p, body.replace("@HELPER@", &helper_path).as_bytes(), 0o644)
            .map_err(|e| io(name, e))?;
    }
    write_if_changed(
        &root_join(root, POLKIT_PATH),
        POLKIT_RULE.replace("@INSTALL_USER@", user).as_bytes(),
        0o644,
    )
    .map_err(|e| io("polkit", e))?;
    // The operator's edits to the config win over a re-install.
    let conf = root_join(root, CONF_PATH);
    if !conf.exists() {
        write_if_changed(&conf, SWAP_CONF.as_bytes(), 0o644).map_err(|e| io("conf", e))?;
    }
    if live {
        for (prog, args) in [
            ("groupadd", vec!["-f", GROUP]),
            ("usermod", vec!["-aG", GROUP, user]),
            ("systemctl", vec!["daemon-reload"]),
            (
                "systemctl",
                vec!["enable", "--now", "tillandsias-swap-gc.timer"],
            ),
        ] {
            run_system(prog, &args).map_err(|e| format!("refused:swap-on:{prog}:{e}"))?;
        }
    }
    let prefix = if live {
        "/".to_string()
    } else {
        root.display().to_string()
    };
    Ok(format!(
        "ok:swap-on:prefix={prefix}:user={user}:helper={helper_path}"
    ))
}

/// The configured swap directory, read from the installed config (default
/// `/var/swap`), resolved under `root`.
fn swap_dir(root: &Path) -> PathBuf {
    let text = std::fs::read_to_string(root_join(root, CONF_PATH)).unwrap_or_default();
    let dir = text
        .lines()
        .filter_map(|l| l.trim().strip_prefix("SWAP_DIR="))
        .next_back()
        .map(|v| v.trim().trim_matches('"').to_string())
        .filter(|v| v.starts_with('/'))
        .unwrap_or_else(|| "/var/swap".to_string());
    root_join(root, &dir)
}

/// Remove everything `on` installed, and the per-launch swapfiles the helper
/// created (`<SWAP_DIR>/tillandsias-*`, and nothing else in that directory).
fn remove(root: &Path, live: bool) -> Result<String, String> {
    let dir = swap_dir(root);
    let mut removed = 0usize;
    let mut swapfiles = 0usize;
    if live {
        // Stop every live lease first, so no swapfile is in use when it goes.
        let _ = run_system("systemctl", &["stop", "tillandsias-swap@*.service"]);
        let _ = run_system(
            "systemctl",
            &["disable", "--now", "tillandsias-swap-gc.timer"],
        );
    }
    if let Ok(rd) = std::fs::read_dir(&dir) {
        let mut files: Vec<PathBuf> = rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("tillandsias-"))
                    && p.is_file()
            })
            .collect();
        files.sort();
        for f in files {
            if live {
                let _ = run_system("swapoff", &[&f.display().to_string()]);
            }
            std::fs::remove_file(&f)
                .map_err(|e| format!("refused:swap-off:remove:{}:{e}", f.display()))?;
            swapfiles += 1;
        }
    }
    for p in removal_paths() {
        let path = root_join(root, p);
        match std::fs::remove_file(&path) {
            Ok(()) => removed += 1,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("refused:swap-off:remove:{}:{e}", path.display())),
        }
    }
    // /etc/tillandsias only if it is now empty; anything else there is not ours.
    let _ = std::fs::remove_dir(root_join(root, "/etc/tillandsias"));
    if live {
        let _ = run_system("systemctl", &["daemon-reload"]);
        // The group has no other use in this project; remove it only if no
        // remaining polkit rule still refers to it.
        if !group_still_referenced(root) && group_exists() {
            let _ = run_system("groupdel", &[GROUP]);
        }
    }
    let prefix = if live {
        "/".to_string()
    } else {
        root.display().to_string()
    };
    Ok(format!(
        "ok:swap-off:prefix={prefix}:removed={removed}:swapfiles={swapfiles}"
    ))
}

fn group_still_referenced(root: &Path) -> bool {
    let needle = format!("isInGroup(\"{GROUP}\")");
    std::fs::read_dir(root_join(root, "/etc/polkit-1/rules.d"))
        .map(|rd| {
            rd.flatten().any(|e| {
                std::fs::read_to_string(e.path())
                    .map(|t| t.contains(&needle))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn group_exists() -> bool {
    std::fs::read_to_string("/etc/group")
        .map(|t| t.lines().any(|l| l.split(':').next() == Some(GROUP)))
        .unwrap_or(false)
}

fn status(root: &Path, live: bool) -> String {
    let paths = removal_paths();
    let present = paths.iter().filter(|p| root_join(root, p).exists()).count();
    let installed = match present {
        0 => "no".to_string(),
        n if n == paths.len() => "yes".to_string(),
        n => format!("partial-{n}/{}", paths.len()),
    };
    // Active per-launch swapfiles: /proc/swaps lines under SWAP_DIR.
    let active = if live {
        let dir = swap_dir(root).display().to_string();
        std::fs::read_to_string("/proc/swaps")
            .map(|t| {
                t.lines()
                    .filter(|l| l.starts_with(&format!("{dir}/tillandsias-")))
                    .count()
            })
            .unwrap_or(0)
    } else {
        0
    };
    format!("ok:swap-status:installed={installed}:active={active}")
}

fn run_system(prog: &str, args: &[&str]) -> Result<(), String> {
    let st = std::process::Command::new(prog)
        .args(args)
        .status()
        .map_err(|e| e.to_string())?;
    if st.success() {
        Ok(())
    } else {
        Err(format!("exit {}", st.code().unwrap_or(-1)))
    }
}

fn is_root() -> bool {
    // SAFETY: geteuid has no preconditions and cannot fail.
    unsafe { libc::geteuid() == 0 }
}

/// Re-execute this binary once through pkexec. Returns only if pkexec could
/// not be used; the caller then prints the sudo line.
fn elevate(verb: &str, user: &str) -> Option<i32> {
    let exe = std::env::current_exe().ok()?;
    let has_pkexec = std::env::var_os("PATH")
        .is_some_and(|p| std::env::split_paths(&p).any(|d| d.join("pkexec").is_file()));
    if !has_pkexec {
        return None;
    }
    eprintln!("[tillandsias] --swap {verb}: asking for administrator rights once (pkexec)");
    let st = std::process::Command::new("pkexec")
        .arg(&exe)
        .args(["--swap", verb, "--user", user])
        .status()
        .ok()?;
    // 126: the operator declined / not authorised; 127: pkexec could not run.
    match st.code() {
        Some(126) | Some(127) | None => None,
        Some(c) => Some(c),
    }
}

/// Entry point. Returns the process exit code.
pub(crate) fn run(args: &[String]) -> i32 {
    let o = match parse(args) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("usage: tillandsias --swap on|off|status [--prefix DIR] [--user NAME]");
            println!("refused:swap:{e}");
            return 2;
        }
    };
    let live = o.prefix.as_deref().is_none_or(|p| p == Path::new("/"));
    let root = o.prefix.clone().unwrap_or_else(|| PathBuf::from("/"));
    if o.verb == "status" {
        println!("{}", status(&root, live));
        return 0;
    }
    let user = resolve_user(o.user.as_deref()).unwrap_or_default();
    if o.verb == "on" && !valid_user(&user) {
        println!("refused:swap-on:user:'{user}' — pass --user NAME");
        return 1;
    }
    if live && !is_root() {
        if let Some(code) = elevate(&o.verb, &user) {
            return code;
        }
        let exe = std::env::current_exe()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| "tillandsias".into());
        println!("blocked:swap-{}:needs-root", o.verb);
        eprintln!(
            "  remedy: the operator runs, once:  sudo {exe} --swap {} --user {user}",
            o.verb
        );
        return 1;
    }
    let out = if o.verb == "on" {
        install(&root, live, &user)
    } else {
        remove(&root, live)
    };
    match out {
        Ok(v) => {
            println!("{v}");
            0
        }
        Err(v) => {
            println!("{v}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removal_covers_every_installed_path_and_off_undoes_on() {
        let d = tempfile::tempdir().unwrap();
        let out = install(d.path(), false, "tester").unwrap();
        assert!(out.starts_with("ok:swap-on:"), "{out}");
        for p in removal_paths() {
            assert!(root_join(d.path(), p).is_file(), "on did not install {p}");
        }
        let swapdir = root_join(d.path(), "/var/swap");
        std::fs::create_dir_all(&swapdir).unwrap();
        std::fs::write(swapdir.join("tillandsias-abc-1"), b"x").unwrap();
        std::fs::write(swapdir.join("forge-live.swap"), b"not ours").unwrap();
        let off = remove(d.path(), false).unwrap();
        assert_eq!(
            off,
            format!(
                "ok:swap-off:prefix={}:removed=6:swapfiles=1",
                d.path().display()
            )
        );
        for p in removal_paths() {
            assert!(!root_join(d.path(), p).exists(), "off left {p}");
        }
        assert!(
            swapdir.join("forge-live.swap").exists(),
            "off removed a file it did not create"
        );
    }

    #[test]
    fn hostile_users_are_refused() {
        for u in ["x; rm -rf /", "", "Root", "a b", &"a".repeat(33)] {
            assert!(!valid_user(u), "{u:?}");
        }
        assert!(valid_user("tlatoani"));
    }

    #[test]
    fn a_second_on_changes_nothing() {
        let d = tempfile::tempdir().unwrap();
        install(d.path(), false, "tester").unwrap();
        for p in removal_paths() {
            let path = root_join(d.path(), p);
            let before = std::fs::read(&path).unwrap();
            let changed = write_if_changed(&path, &before, {
                use std::os::unix::fs::PermissionsExt;
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o7777
            })
            .unwrap();
            assert!(!changed, "{p}");
        }
    }
}
