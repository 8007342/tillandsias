//! Runtime diagnostics streaming.
//!
//! When the user passes `--diagnostics` (a superset of `--debug`), this
//! module spawns background tasks that stream logs from every WSL distro
//! and known service-log file, prefixed with `[<distro>/<source>]`, into
//! the calling terminal. Users can then `grep` by service to triage
//! runtime issues across the multi-container nested environment.
//!
//! On Windows, the implementation uses `wsl.exe -d <distro> --exec tail
//! -F <log>` and `wsl.exe -d <distro> --exec journalctl --no-pager`
//! variants. Linux/macOS implementations are pending Phase 2 (see
//! `openspec/changes/runtime-diagnostics-stream/specs/`).
//!
//! Streams are best-effort: a missing log file or a distro that isn't yet
//! running prints a single warning then moves on. The flag is intended for
//! development; production launches use the non-flag default.
//!
//! @trace spec:runtime-diagnostics-stream, spec:cross-platform,
//! spec:windows-wsl-runtime
//! @cheatsheet runtime/wsl-on-windows.md

#![allow(dead_code)] // many helpers are platform-specific; avoid warnings on non-Windows

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

/// One log source within a WSL distro that should be tail-streamed.
struct LogSource {
    /// WSL distro name, e.g., `tillandsias-git`.
    distro: &'static str,
    /// Short label printed in the prefix, e.g., `git-daemon`.
    label: &'static str,
    /// Absolute path inside the distro to `tail -F`.
    path: &'static str,
    /// User to run as. `git` for git distro, `forge` for forge, etc.
    user: &'static str,
}

/// Built-in log sources covered when `--diagnostics` is set.
///
/// Add new sources here as Phase 2 lands more services. Each entry survives
/// missing-file conditions gracefully (`tail -F` waits for the file to
/// appear; if the distro itself isn't imported, the wsl.exe call returns
/// non-zero and we log one warning, no retry storm).
const SOURCES: &[LogSource] = &[
    LogSource {
        distro: "tillandsias-git",
        label: "git-daemon",
        path: "/tmp/git-daemon.log",
        user: "git",
    },
    LogSource {
        distro: "tillandsias-forge",
        label: "forge-lifecycle",
        path: "/tmp/forge-lifecycle.log",
        user: "forge",
    },
    LogSource {
        distro: "tillandsias-proxy",
        label: "squid",
        path: "/var/log/squid/access.log",
        user: "proxy",
    },
    LogSource {
        distro: "tillandsias-router",
        label: "caddy",
        path: "/var/log/caddy.log",
        user: "caddy",
    },
    LogSource {
        distro: "tillandsias-inference",
        label: "ollama",
        path: "/var/log/ollama.log",
        user: "ollama",
    },
];

/// Handle to a running diagnostics stream. Drop kills all spawned processes.
pub struct DiagnosticsHandle {
    children: Vec<Child>,
    stop: Arc<AtomicBool>,
}

impl Drop for DiagnosticsHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        for child in self.children.iter_mut() {
            let _ = child.kill();
        }
    }
}

/// Start streaming diagnostics for all known log sources.
///
/// Each source spawns one `wsl.exe -d <distro> --user <user> --exec tail
/// -F <path>` child. Lines are read on a dedicated OS thread (no tokio
/// runtime required so this works from synchronous CLI mode), prefixed,
/// and printed to stdout. Errors are swallowed silently except for spawn
/// failures, which print one warning per source.
///
/// On non-Windows targets this is a no-op stub; the function returns an
/// empty handle and prints a single notice. Linux/macOS implementations
/// land with Phase 2 — see openspec/changes/runtime-diagnostics-stream.
///
/// @trace spec:runtime-diagnostics-stream, spec:cross-platform
pub fn start() -> DiagnosticsHandle {
    let stop = Arc::new(AtomicBool::new(false));

    #[cfg(not(target_os = "windows"))]
    {
        eprintln!(
            "[diagnostics] --diagnostics streaming is implemented only on Windows in this revision."
        );
        eprintln!(
            "[diagnostics] Linux/macOS spec: openspec/changes/runtime-diagnostics-stream/"
        );
        return DiagnosticsHandle {
            children: Vec::new(),
            stop,
        };
    }

    #[cfg(target_os = "windows")]
    {
        eprintln!(
            "[diagnostics] streaming logs from {} sources; prefix is [<distro>/<source>]",
            SOURCES.len()
        );
        eprintln!(
            "[diagnostics] grep tip: tillandsias <path> --diagnostics 2>&1 | findstr 'git-daemon'"
        );

        let mut children = Vec::new();
        for src in SOURCES {
            // We use `tail -F` (uppercase) so missing files don't kill the
            // tail — it waits for them to appear. `-n 0` skips the default
            // 10-line history so we don't bleed prior-session lines into
            // the current diagnostics stream.
            let prep_and_tail = format!(
                "mkdir -p \"$(dirname '{p}')\" 2>/dev/null; touch '{p}' 2>/dev/null; tail -F -n 0 '{p}' 2>/dev/null",
                p = src.path
            );

            let mut cmd = Command::new("wsl.exe");
            tillandsias_podman::no_window_sync(&mut cmd);
            // @cheatsheet runtime/wsl-on-windows.md
            // WSL_UTF8=1 makes wsl.exe emit UTF-8 instead of UTF-16 LE, so
            // its own error messages (e.g. "distro not found") show up in
            // the diagnostics stream as readable text instead of strings
            // with NUL-byte padding between each character.
            cmd.env("WSL_UTF8", "1");
            cmd.args([
                "-d",
                src.distro,
                "--user",
                src.user,
                "--exec",
                "/bin/sh",
                "-c",
                &prep_and_tail,
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // Detach stdin so the child doesn't share our terminal's input.
            .stdin(Stdio::null());

            match cmd.spawn() {
                Ok(mut child) => {
                    let prefix = format!("[{}/{}]", src.distro, src.label);
                    if let Some(stdout) = child.stdout.take() {
                        let p = prefix.clone();
                        let stop_flag = stop.clone();
                        thread::spawn(move || stream_with_prefix(stdout, &p, stop_flag));
                    }
                    if let Some(stderr) = child.stderr.take() {
                        let p = format!("{prefix}!"); // mark stderr lines
                        let stop_flag = stop.clone();
                        thread::spawn(move || stream_with_prefix(stderr, &p, stop_flag));
                    }
                    children.push(child);
                }
                Err(e) => {
                    eprintln!(
                        "[diagnostics] could not start tail for {}/{}: {}",
                        src.distro, src.label, e
                    );
                }
            }
        }
        DiagnosticsHandle { children, stop }
    }
}

/// Read lines from a child stream, print each prefixed with `prefix `, until
/// the stream closes or `stop` flips.
fn stream_with_prefix<R: std::io::Read>(read: R, prefix: &str, stop: Arc<AtomicBool>) {
    let reader = BufReader::new(read);
    for line in reader.lines() {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        match line {
            Ok(l) => println!("{prefix} {l}"),
            Err(_) => break,
        }
    }
}
