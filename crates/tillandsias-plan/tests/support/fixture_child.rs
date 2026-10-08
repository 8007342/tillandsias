// @trace order:1551-geib, spec:command-runtime
//! The child programs the Lua process tests supervise, in Rust.
//!
//! WHY THIS EXISTS. The managed-process tests need real children that do
//! specific things: write exact bytes, acknowledge through files, start a
//! grandchild, outlive a deadline. The command policy refuses `sh -c <string>`,
//! so the tests that landed with 1534-puyz and 1538-pwdr ran thirteen Python
//! programs (ten written into temp files, three passed with `-c`) through
//! twenty-three `python3` invocations — in the test suite of
//! the runtime whose purpose is to retire ad hoc scripting, and against
//! `tlatoani_hard_no_python`. The no-Python guard did not see them: it scanned
//! `scripts/` for lines beginning with `python`, never a Rust test source or
//! an argv string.
//!
//! Each mode below is a line-for-line port of one of those programs; the test
//! that uses it names the mode. Nothing here is linked into a shipped binary:
//! it is its own `[[bin]]`, built for the integration tests, and no installer
//! copies it.
//!
//! All paths are relative to the cwd the runtime gives the child, exactly as
//! the programs it replaces.

use std::io::{Read, Write};
use std::path::Path;
use std::process::exit;
use std::time::{Duration, Instant};

fn out(bytes: &[u8]) {
    // One write per call and no buffering: the tests assert on line framing
    // and on what was already delivered when a child is killed.
    let mut stdout = std::io::stdout().lock();
    if stdout
        .write_all(bytes)
        .and_then(|_| stdout.flush())
        .is_err()
    {
        exit(0); // the reader went away; a producer has nothing left to say
    }
}

fn err(bytes: &[u8]) {
    let mut stderr = std::io::stderr().lock();
    let _ = stderr.write_all(bytes).and_then(|_| stderr.flush());
}

fn write_file(path: &str, contents: &str) {
    std::fs::write(path, contents).unwrap_or_else(|e| {
        err(format!("fixture-child: cannot write {path}: {e}\n").as_bytes());
        exit(70);
    });
}

fn wait_for(path: &str, poll: Duration, deadline: Option<Instant>) -> bool {
    while !Path::new(path).exists() {
        if deadline.is_some_and(|d| Instant::now() > d) {
            return false;
        }
        std::thread::sleep(poll);
    }
    true
}

#[cfg(unix)]
fn pgid() -> i64 {
    // SAFETY: getpgrp takes no arguments and cannot fail.
    i64::from(unsafe { libc::getpgrp() })
}
#[cfg(not(unix))]
fn pgid() -> i64 {
    0
}

/// `{pid, pgid, start}` as JSON. `start` is field 22 of /proc/self/stat (the
/// process start time), kept as a STRING: the observer in the test compares it
/// textually to tell this process from a later reuse of its pid.
fn identity() -> String {
    let start = std::fs::read_to_string("/proc/self/stat")
        .ok()
        .and_then(|stat| {
            let (_, details) = stat.rsplit_once(") ")?;
            details.split_whitespace().nth(19).map(str::to_owned)
        })
        .unwrap_or_default();
    format!(
        r#"{{"pid":{},"pgid":{},"start":"{}"}}"#,
        std::process::id(),
        pgid(),
        start
    )
}

fn spawn_self(mode: &str) -> std::process::Child {
    let exe = std::env::current_exe().unwrap_or_else(|e| {
        err(format!("fixture-child: current_exe: {e}\n").as_bytes());
        exit(70);
    });
    // Inherits stdout and stderr on purpose: a grandchild holding the pipe is
    // part of what the supervisor has to cope with.
    std::process::Command::new(exe)
        .args([mode, "grandchild"])
        .spawn()
        .unwrap_or_else(|e| {
            err(format!("fixture-child: spawn grandchild: {e}\n").as_bytes());
            exit(70);
        })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let arg = |i: usize| args.get(i).map(String::as_str);
    match arg(0) {
        // 10000 CRLF lines on each fd, interleaved, then an unterminated tail.
        Some("lines") => {
            for i in 0..10000 {
                out(format!("{i}\r\n").as_bytes());
                err(format!("E{i}\r\n").as_bytes());
            }
            out(b"last");
        }
        // Two of these overlap: each announces itself, waits for BOTH to have
        // started, says READY, waits for the script's acknowledgement, says DONE.
        Some("live") => {
            let n = arg(1).unwrap_or("0");
            write_file(&format!("started-{n}"), "started");
            let end = Instant::now() + Duration::from_secs(3);
            let poll = Duration::from_millis(5);
            if !(wait_for("started-1", poll, Some(end)) && wait_for("started-2", poll, Some(end))) {
                exit(8);
            }
            out(format!("READY{n}\n").as_bytes());
            if !wait_for(&format!("ack-{n}"), poll, Some(end)) {
                exit(9);
            }
            out(format!("DONE{n}\n").as_bytes());
        }
        // Acknowledges BOTH processes before a deadline can fire, then leaves
        // delayed markers that only appear if nothing killed the group.
        Some("owned") => {
            if arg(1).is_some() {
                write_file("grandchild-ack", &identity());
                std::thread::sleep(Duration::from_millis(1100));
                write_file("grandchild-marker", "survived");
                exit(0);
            }
            let mut grandchild = spawn_self("owned");
            wait_for("grandchild-ack", Duration::from_millis(5), None);
            write_file("child-ack", &identity());
            out(b"READY\n");
            std::thread::sleep(Duration::from_millis(1100));
            write_file("child-marker", "survived");
            let _ = grandchild.wait();
        }
        // A known-live control: acknowledges both processes and never exits.
        Some("observer") => {
            if arg(1).is_some() {
                write_file("grandchild-ack", &identity());
            } else {
                // It never exits on its own (the fixture kills the group); the
                // waiter thread only keeps it from lingering as a zombie if it
                // ever does.
                let mut grandchild = spawn_self("observer");
                std::thread::spawn(move || {
                    let _ = grandchild.wait();
                });
                wait_for("grandchild-ack", Duration::from_millis(1), None);
                write_file("child-ack", &identity());
            }
            loop {
                std::thread::sleep(Duration::from_secs(1));
            }
        }
        // Block until a file exists (the script's way to wait for an ack
        // without consuming a callback).
        Some("wait-for") => {
            wait_for(
                arg(1).unwrap_or("child-ack"),
                Duration::from_millis(5),
                None,
            );
        }
        // Says READY and then outlives any reasonable test.
        Some("ready-sleep") => {
            out(b"READY\n");
            std::thread::sleep(Duration::from_secs(30));
        }
        // Writes its own pid to a file, then outlives any reasonable test.
        Some("pid-sleep") => {
            write_file(
                arg(1).unwrap_or("child.pid"),
                &std::process::id().to_string(),
            );
            std::thread::sleep(Duration::from_secs(30));
        }
        Some("write-file") => {
            write_file(arg(1).unwrap_or("escaped"), arg(2).unwrap_or("bad"));
        }
        // Never stops producing: 8192 short lines per write.
        Some("busy") => {
            let block = b"x\n".repeat(8192);
            loop {
                out(&block);
            }
        }
        // One unterminated line, one byte past the stream's line bound.
        Some("huge") => out(&vec![b'x'; 1_048_577]),
        // Empty line, bare CR, NUL and 0xff, CRLF, an unterminated tail.
        Some("bytes") => {
            out(b"\n\r\nA\x00\xff\r\nlast");
            err(b"E\n");
        }
        // 9216 lines of 1023 bytes: 9 MiB, one past the default capture.
        Some("cap") => {
            let mut line = vec![b'X'; 1023];
            line.push(b'\n');
            for _ in 0..9216 {
                out(&line);
            }
        }
        // The fixed environment and an explicit addition must be present;
        // then stdin is echoed byte for byte.
        Some("env-stdin") => {
            for (key, want) in [
                ("LC_ALL", "C"),
                ("LANG", "C"),
                ("TZ", "UTC"),
                ("GIT_TERMINAL_PROMPT", "0"),
                ("EXPLICIT", "yes"),
            ] {
                if std::env::var(key).ok().as_deref() != Some(want) {
                    err(format!("fixture-child: {key} is not {want}\n").as_bytes());
                    exit(1);
                }
            }
            let mut bytes = Vec::new();
            if std::io::stdin().lock().read_to_end(&mut bytes).is_err() {
                exit(1);
            }
            out(&bytes);
        }
        Some("cwd") => match std::env::current_dir() {
            Ok(dir) => out(format!("{}\n", dir.display()).as_bytes()),
            Err(_) => exit(1),
        },
        other => {
            err(format!("fixture-child: unknown mode {other:?}\n").as_bytes());
            exit(64);
        }
    }
}
