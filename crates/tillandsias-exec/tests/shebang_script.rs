// @trace order:2436-wsbg
//
// A `#!` script named as argv[0] runs, on every host, the way exec(2) runs it
// (2428-cens-c). Unix: the kernel reads the `#!`. Windows: CreateProcess runs
// only PE images, so before 2436 the spawn failed with os error 193 and every
// fixture whose stub `gh`/`git`/`podman` is a script was red on msys.

use tillandsias_exec::Command;

fn stub(dir: &std::path::Path, name: &str) -> std::path::PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, "#!/usr/bin/env bash\nprintf 'stub:%s\\n' \"$*\"\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    p
}

/// By path: a script with arguments runs and sees its argv.
#[tokio::test]
async fn a_shebang_script_named_by_path_runs() {
    let d = tempfile::tempdir().unwrap();
    let s = stub(d.path(), "fake-gh");
    let out = Command::new([s.as_os_str(), "pr".as_ref(), "list".as_ref()])
        .run()
        .await
        .expect("a #! script must spawn (os error 193 on Windows before 2436)");
    assert_eq!(out.stdout_lossy().trim(), "stub:pr list");
    assert!(out.completion.is_success());
}

/// By bare name on PATH: what a fixture does when it puts a stub dir first.
#[tokio::test]
async fn a_shebang_script_found_on_path_runs() {
    let d = tempfile::tempdir().unwrap();
    stub(d.path(), "fake-podman-2436");
    let path = std::env::join_paths(
        std::iter::once(d.path().to_path_buf())
            .chain(std::env::split_paths(&std::env::var_os("PATH").unwrap())),
    )
    .unwrap();
    let out = Command::new(["fake-podman-2436", "ps"])
        .env("PATH", &path)
        .run()
        .await
        .expect("a #! script found on the command's PATH must spawn");
    assert_eq!(out.stdout_lossy().trim(), "stub:ps");
}
