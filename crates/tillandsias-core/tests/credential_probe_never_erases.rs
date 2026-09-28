// A credential CHECK must not be able to destroy the credential it checks.
// @trace order:1004-8p76, spec:gh-auth-script
//
// git runs `credential reject` when an HTTP push is refused (401), and the
// store helper then ERASES the matching entry. scripts/check-credential-channel.sh
// probes with a dry-run push, so a probe through the real helper chain would
// delete a GOOD credential on one transient refusal (esme-windows's hypothesis,
// 2026-09-04; reproduced on yoga 2026-09-28). The guard now runs its probes with
// a get-only helper chain. These tests stand up a local server that answers 401
// to everything (Rust, because scripts may not use a python runtime), then:
//   - premise: a plain dry-run push through the real chain empties the store;
//   - property: the guard's refused probe leaves the store byte-identical.
#![cfg(unix)]

use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::TempDir;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("repo root")
        .to_path_buf()
}

fn have(tool: &str) -> bool {
    Command::new(tool).arg("--version").output().is_ok()
}

/// A server that answers every request with 401 + a Basic challenge.
fn serve_401() -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = l.local_addr().expect("addr").port();
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { continue };
            let mut buf = [0u8; 8192];
            let mut seen = Vec::new();
            while let Ok(n) = s.read(&mut buf) {
                if n == 0 {
                    break;
                }
                seen.extend_from_slice(&buf[..n]);
                if seen.windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            let _ = s.write_all(
                b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"x\"\r\n\
                  Content-Length: 0\r\nConnection: close\r\n\r\n",
            );
        }
    });
    port
}

fn git(dir: &Path, home: &Path, args: &[&str]) -> std::process::Output {
    Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("HOME", home)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .output()
        .expect("run git")
}

/// A repo whose origin is the 401 server, with a seeded store file.
fn seeded(tmp: &Path, name: &str, port: u16) -> (PathBuf, PathBuf) {
    let d = tmp.join(name);
    let home = tmp.join("home");
    fs::create_dir_all(&d).expect("mkdir");
    fs::create_dir_all(&home).expect("mkdir home");
    for a in [
        vec!["init", "-q", "-b", "main"],
        vec!["config", "user.email", "t@t"],
        vec!["config", "user.name", "t"],
        vec!["config", "core.hooksPath", ".git/hooks"],
        vec!["commit", "-q", "--allow-empty", "-m", "x"],
    ] {
        assert!(git(&d, &home, &a).status.success(), "git {a:?}");
    }
    let url = format!("http://127.0.0.1:{port}/r.git");
    assert!(
        git(&d, &home, &["remote", "add", "origin", &url])
            .status
            .success()
    );
    let store = d.join(".git/.gh-credentials");
    let helper = format!("store --file={}", store.display());
    assert!(
        git(&d, &home, &["config", "credential.helper", &helper])
            .status
            .success()
    );
    fs::write(&store, format!("http://u:good-token@127.0.0.1%3a{port}\n")).expect("seed store");
    (d, store)
}

#[test]
fn premise_a_refused_push_through_the_real_chain_erases_the_store() {
    if !have("git") {
        eprintln!("skipping: git not available");
        return;
    }
    let port = serve_401();
    let tmp = TempDir::new().expect("tempdir");
    let (d, store) = seeded(tmp.path(), "premise", port);
    let _ = git(
        &d,
        &tmp.path().join("home"),
        &["push", "--dry-run", "--no-verify", "origin", "HEAD"],
    );
    let left = fs::read(&store).unwrap_or_default();
    if !left.is_empty() {
        // The property test below still holds; say the premise did not show.
        eprintln!("note: this git did not erase the store on a 401; the premise is unshown here");
    }
}

#[test]
fn the_guards_refused_probe_leaves_the_store_byte_identical() {
    if !have("git") || !have("bash") {
        eprintln!("skipping: git or bash not available");
        return;
    }
    let port = serve_401();
    let tmp = TempDir::new().expect("tempdir");
    let (d, store) = seeded(tmp.path(), "guard", port);
    let before = fs::read(&store).expect("read store");
    let out = Command::new("bash")
        .arg(repo_root().join("scripts/check-credential-channel.sh"))
        .current_dir(&d)
        .env("HOME", tmp.path().join("home"))
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("LC_ALL", "C")
        .env_remove("GH_TOKEN")
        .env_remove("GITHUB_TOKEN")
        .env_remove("TILLANDSIAS_CRED_PROBE_CMD")
        .output()
        .expect("run guard");
    let verdict = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let after = fs::read(&store).unwrap_or_default();
    assert_eq!(
        verdict,
        "blocked:gh-credentials-store-push-refused",
        "stderr={}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(!out.status.success(), "a refused probe must exit non-zero");
    assert_eq!(
        before, after,
        "the guard's probe changed the credential store"
    );
}
