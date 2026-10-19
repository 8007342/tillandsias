// @trace order:1788-qlwq, spec:branch-discipline
//! 1788-qlwq slices 3-8: what a NEW project in a forge meets when it adopts
//! branch discipline (kumbia-kombat FORGE_DIAGNOSTICS.md, 2026-10-18). Every arm
//! drives the real binary through real git: scratch projects, a bare remote,
//! hooks installed by `discipline install-hooks`, and a scratch HOME and global
//! git config so nothing on the host leaks in.
#![cfg(unix)]
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const PLAN: &str = env!("CARGO_BIN_EXE_tillandsias-plan");

struct Box_ {
    dir: tempfile::TempDir,
}

impl Box_ {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("home")).unwrap();
        std::fs::write(
            dir.path().join("gitconfig"),
            "[user]\n\tname = fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = main\n",
        )
        .unwrap();
        Box_ { dir }
    }
    fn home(&self) -> PathBuf {
        self.dir.path().join("home")
    }
    fn env(&self, c: &mut Command) {
        c.env("HOME", self.home())
            .env("GIT_CONFIG_GLOBAL", self.dir.path().join("gitconfig"))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("TILLANDSIAS_PLAN_BIN", PLAN)
            .env_remove("PROJECT_ROOT")
            .env_remove("TILLANDSIAS_HOST_KIND")
            .env_remove("TILLANDSIAS_POLICY_AUDIT")
            .env_remove("TILLANDSIAS_POLICY_AUDIT_LOG")
            .env_remove("XDG_CACHE_HOME")
            .env_remove("GIT_AUTHOR_NAME")
            .env_remove("GIT_AUTHOR_EMAIL")
            .env_remove("GIT_COMMITTER_NAME")
            .env_remove("GIT_COMMITTER_EMAIL");
    }
    fn git(&self, root: &Path, args: &[&str]) -> Output {
        let mut c = Command::new("git");
        c.arg("-C").arg(root).args(args);
        self.env(&mut c);
        c.output().unwrap()
    }
    fn plan(&self, root: &Path, args: &[&str]) -> Output {
        let mut c = Command::new(PLAN);
        c.current_dir(root).args(args);
        self.env(&mut c);
        c.output().unwrap()
    }
    /// A project with one commit and a bare remote as origin.
    fn project(&self, name: &str) -> PathBuf {
        let p = self.dir.path().join(name);
        let remote = self.dir.path().join(format!("{name}-remote.git"));
        assert!(
            Command::new("git")
                .args(["init", "-q", "--bare"])
                .arg(&remote)
                .status()
                .unwrap()
                .success()
        );
        assert!(
            self.git(self.dir.path(), &["init", "-q", name])
                .status
                .success()
        );
        std::fs::write(p.join("README"), "one\n").unwrap();
        self.git(&p, &["add", "README"]);
        assert!(self.git(&p, &["commit", "-qm", "one"]).status.success());
        self.git(&p, &["remote", "add", "origin", remote.to_str().unwrap()]);
        p
    }
    fn commit(&self, p: &Path, line: &str) {
        let f = p.join("README");
        let mut t = std::fs::read_to_string(&f).unwrap();
        t.push_str(line);
        t.push('\n');
        std::fs::write(&f, t).unwrap();
        assert!(self.git(p, &["commit", "-qam", line]).status.success());
    }
}

fn text(o: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

/// Slice 3: `raise --to 2` writes the work_ref regex, real work refs then pass,
/// and a template-looking value is refused by name instead of silently
/// refusing every work ref.
#[test]
fn raise_to_two_writes_a_work_ref_regex_and_a_template_value_is_refused() {
    let b = Box_::new();
    let p = b.project("raise2");
    let out = b.plan(
        &p,
        &["discipline", "raise", "--to", "2", "--integration", "game"],
    );
    assert!(out.status.success(), "{}", text(&out));
    let seed = std::fs::read_to_string(p.join(".tillandsias/branch-discipline.yaml")).unwrap();
    assert!(
        seed.contains("work_ref: \"work/[0-9]{3,4}-[a-z0-9]{4}\""),
        "{seed}"
    );
    let ok = b.plan(
        &p,
        &["discipline", "check-ref", "refs/heads/work/1234-abcd"],
    );
    assert!(text(&ok).starts_with("ok:discipline:"), "{}", text(&ok));
    // An existing level-1 seed raised to 2 gets one too.
    let q = b.project("raise12");
    assert!(
        b.plan(&q, &["discipline", "raise", "--to", "1"])
            .status
            .success()
    );
    assert!(
        b.plan(&q, &["discipline", "raise", "--to", "2"])
            .status
            .success()
    );
    let seed = std::fs::read_to_string(q.join(".tillandsias/branch-discipline.yaml")).unwrap();
    assert_eq!(seed.matches("work_ref:").count(), 1, "{seed}");
    // NEGATIVE CONTROL: `work/<id>` is a template, refused as such.
    let t = std::fs::read_to_string(p.join(".tillandsias/branch-discipline.yaml"))
        .unwrap()
        .replace(
            "work_ref: \"work/[0-9]{3,4}-[a-z0-9]{4}\"",
            "work_ref: \"work/<id>\"",
        );
    std::fs::write(p.join(".tillandsias/branch-discipline.yaml"), t).unwrap();
    let show = b.plan(&p, &["discipline", "show"]);
    assert!(
        text(&show).contains("refused:discipline-seed:work-ref-template"),
        "{}",
        text(&show)
    );
}

/// Slices 4 and 6, through a real `git push`: the seed's own denied message is
/// printed by the pre-push refusal, and a push the rule only WARNS about says
/// that it will be accepted.
#[test]
fn the_pre_push_hook_prints_the_seeds_message_and_says_a_warned_push_is_accepted() {
    let b = Box_::new();
    let p = b.project("prepush");
    assert!(
        b.plan(&p, &["discipline", "install-hooks"])
            .status
            .success()
    );
    assert!(
        b.plan(
            &p,
            &["discipline", "raise", "--to", "1", "--integration", "game"]
        )
        .status
        .success()
    );
    let seed_path = p.join(".tillandsias/branch-discipline.yaml");
    let mut seed = std::fs::read_to_string(&seed_path).unwrap();
    seed.push_str("messages:\n  default_branch_denied: \"KUMBIA-1788: {default} is release-only; land on {integration}\"\n");
    std::fs::write(&seed_path, seed).unwrap();
    b.git(&p, &["add", "."]);
    assert!(b.git(&p, &["commit", "-qm", "seed"]).status.success());

    // Seed ahead of reality (no game on origin yet): warned, accepted, and SAID.
    let warned = b.git(&p, &["push", "origin", "main"]);
    let w = text(&warned);
    assert!(warned.status.success(), "{w}");
    assert!(
        w.contains("default-branch-protected:seed-ahead-of-reality"),
        "{w}"
    );
    assert!(
        w.contains("THIS PUSH WILL BE ACCEPTED: refs/heads/main"),
        "{w}"
    );

    // Once game exists on origin the rule refuses, in the seed's own words.
    assert!(
        b.git(&p, &["push", "-q", "origin", "HEAD:game"])
            .status
            .success()
    );
    b.git(&p, &["fetch", "-q", "origin"]);
    b.commit(&p, "two");
    let refused = b.git(&p, &["push", "origin", "main"]);
    let r = text(&refused);
    assert!(!refused.status.success(), "{r}");
    assert!(
        r.contains("KUMBIA-1788: main is release-only; land on game"),
        "{r}"
    );
    // NEGATIVE CONTROL: a refused push never claims it will be accepted.
    assert!(!r.contains("WILL BE ACCEPTED"), "{r}");
}

/// Slice 5: derive counts the hooks git actually runs, from core.hooksPath.
#[test]
fn derive_lists_hooks_installed_under_a_local_core_hooks_path() {
    let b = Box_::new();
    let p = b.project("derive");
    let hooks = p.join(".tillandsias/hooks");
    std::fs::create_dir_all(&hooks).unwrap();
    std::fs::write(hooks.join("pre-push"), "#!/bin/sh\nexit 0\n").unwrap();
    b.git(&p, &["config", "core.hooksPath", ".tillandsias/hooks"]);
    let out = b.plan(&p, &["discipline", "derive", "--json"]);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).expect("derive --json");
    let installed = v["observations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["name"] == "installed_hooks")
        .expect("installed_hooks observation")["value"]
        .clone();
    assert_eq!(installed, serde_json::json!(["pre-push"]), "{v}");
    // NEGATIVE CONTROL: with no hooksPath, the common dir's (empty) hooks count.
    let q = b.project("derive-plain");
    let out = b.plan(&q, &["discipline", "derive", "--json"]);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let installed = v["observations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["name"] == "installed_hooks")
        .unwrap()["value"]
        .clone();
    assert_eq!(installed, serde_json::json!([]), "{v}");
}

/// Slice 7: the command-policy door, as the forge's Bash hook runs it, writes
/// its audit under HOME, never a .cache/ in a non-Tillandsias project.
#[test]
fn the_policy_audit_never_writes_into_a_projects_root() {
    let b = Box_::new();
    let p = b.project("audit");
    let mut c = Command::new(PLAN);
    c.current_dir(&p)
        .args(["policy", "classify-bash", "--hook"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    b.env(&mut c);
    let mut child = c.spawn().unwrap();
    {
        use std::io::Write;
        let input = serde_json::json!({
            "tool_name": "Bash",
            "tool_input": { "command": "ls" },
            "cwd": p.to_str().unwrap(),
        });
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.to_string().as_bytes())
            .unwrap();
    }
    let out = child.wait_with_output().unwrap();
    assert!(
        !p.join(".cache").exists(),
        "a .cache/ appeared in the project: {}",
        text(&out)
    );
    let home_log = b
        .home()
        .join(".cache/tillandsias/metrics/command-policy-audit.jsonl");
    assert!(home_log.is_file(), "the audit went nowhere: {}", text(&out));
}

/// Slice 8: no discipline wording renders the integration branch with a
/// trailing slash ("game/ integration"), which git would read as a different,
/// invalid branch. Every rendering a new project meets is collected here.
#[test]
fn no_discipline_wording_renders_the_integration_branch_with_a_slash() {
    let b = Box_::new();
    let p = b.project("slash");
    let mut all = String::new();
    for args in [
        &["discipline", "raise", "--to", "2", "--integration", "game"][..],
        &["discipline", "show"],
        &["discipline", "derive"],
        &["discipline", "check-ref", "refs/heads/main"],
        &["discipline", "check-ref", "refs/heads/feature"],
        &["discipline", "target", "--platform", "forge"],
    ] {
        all.push_str(&text(&b.plan(&p, args)));
    }
    all.push_str(&text(&b.git(&p, &["push", "origin", "main"])));
    assert!(
        all.contains("game"),
        "the fixture rendered no integration wording: {all}"
    );
    let slash = regex::Regex::new(r"\bgame/(\s|$|[^\w<\[])").unwrap();
    assert!(!slash.is_match(&all), "{all}");
}
