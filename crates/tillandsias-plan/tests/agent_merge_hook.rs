//! ORDER 2094-h3rq (coordinator ruling 2026-11-17): the PreToolUse hook
//! resolves a merge's head through `gh` and FAILS CLOSED. The fixture puts a
//! stub `gh` first on the hook's PATH: a symlink to `false` (every lookup
//! fails) or to `echo` (every lookup "succeeds" with a non-licences head, the
//! premise control proving the stub is the `gh` the hook runs). No script, no
//! interpreter: both stubs are system binaries.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const PLAN: &str = env!("CARGO_BIN_EXE_tillandsias-plan");

fn scratch(tag: &str) -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("agent-merge-hook-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("bin")).unwrap();
    std::fs::create_dir_all(d.join("home")).unwrap();
    d
}

fn which(prog: &str) -> PathBuf {
    for dir in ["/usr/bin", "/bin"] {
        let p = Path::new(dir).join(prog);
        if p.exists() {
            return p;
        }
    }
    panic!("no {prog} in /usr/bin or /bin");
}

/// Run the hook on `cmd` with `gh` -> `stub`; (exit code, stderr).
fn hook(dir: &Path, stub: &str, cmd: &str) -> (i32, String) {
    let gh = dir.join("bin").join("gh");
    let _ = std::fs::remove_file(&gh);
    std::os::unix::fs::symlink(which(stub), &gh).unwrap();
    let mut child = Command::new(PLAN)
        .current_dir(dir)
        .args(["policy", "classify-bash", "--hook"])
        .env(
            "PATH",
            format!("{}:/usr/bin:/bin", dir.join("bin").display()),
        )
        .env("HOME", dir.join("home"))
        .env_remove("TILLANDSIAS_PRETOOLUSE_HOOK")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let input = serde_json::json!({
        "tool_name": "Bash",
        "tool_input": { "command": cmd },
        "cwd": dir.to_str().unwrap(),
    });
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.to_string().as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

const MERGES: [&str; 4] = [
    "gh pr merge 12 --merge",
    "gh api -X PUT repos/o/r/pulls/12/merge",
    "gh api repos/o/r/pulls/12/merge",
    "gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"PR_kw1\"}){clientMutationId}}'",
];

/// NEGATIVE CONTROL: every lookup fails, so every merge form is refused with
/// the retry remedy.
#[test]
fn a_failing_head_lookup_refuses_every_merge_form() {
    let d = scratch("false");
    for cmd in MERGES {
        let (rc, err) = hook(&d, "false", cmd);
        assert_eq!(rc, 2, "{cmd}: {err}");
        assert!(
            err.contains("refused:bash-policy:no-agent-merge"),
            "{cmd}: {err}"
        );
        assert!(
            err.contains("retry when GitHub is reachable"),
            "{cmd}: {err}"
        );
    }
}

/// PREMISE CONTROL: the same commands are allowed when the stub `gh` answers
/// with a non-licences head, so the refusal above came from the lookup.
#[test]
fn a_resolved_non_licence_head_is_allowed() {
    let d = scratch("echo");
    for cmd in MERGES {
        let (rc, err) = hook(&d, "echo", cmd);
        assert_eq!(rc, 0, "{cmd}: {err}");
    }
    // A command that is not a merge never consults gh at all.
    let (rc, err) = hook(&d, "false", "gh pr view 12");
    assert_eq!(rc, 0, "{err}");
}
