// @trace order:1532-u9en
// Scratch-only controls. No process-wide cwd/env mutation; each CLI/worker is
// isolated. These tests do not claim filesystem confinement for spawned children.
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use tillandsias_plan::lua_predicate::{PredicateClass, build_environment};

fn scratch() -> tempfile::TempDir {
    let base = if Path::new("/tmp/opencode").is_dir() {
        PathBuf::from("/tmp/opencode")
    } else {
        std::env::temp_dir()
    };
    tempfile::Builder::new()
        .prefix("lua-boundary-")
        .tempdir_in(base)
        .unwrap()
}

fn setup() -> tempfile::TempDir {
    let d = scratch();
    for p in [
        "repo/.git",
        "repo/scope",
        "repo/files",
        "outside/deep",
        "repo-sibling",
        "declared",
        "declared-sibling",
    ] {
        fs::create_dir_all(d.path().join(p)).unwrap();
    }
    for p in [
        "outside/deep/secret.txt",
        "repo-sibling/secret.txt",
        "declared/allowed.txt",
        "declared-sibling/secret.txt",
        "repo/files/z.txt",
        "repo/files/a.txt",
        "repo/files/b.rs",
    ] {
        fs::write(d.path().join(p), "scratch-control\n").unwrap();
    }
    d
}

fn command(root: &Path) -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"));
    c.current_dir(root)
        .env("TILLANDSIAS_REPO_ROOT", root)
        .env("TILLANDSIAS_POLICY_REGIME", "fixture")
        .env("TILLANDSIAS_FIXTURE_SCOPE", root.join("scope"))
        .env_remove("TILLANDSIAS_HOST_KIND")
        .env_remove("TILLANDSIAS_SKILL")
        .env_remove("CI");
    c
}

fn detail(o: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

fn script(root: &Path, header: &str, code: &str) -> Output {
    let p = root.join("boundary.lua");
    fs::write(&p, format!("{header}\n{code}\nverdict.ok('boundary')\n")).unwrap();
    command(root)
        .args(["script", "run"])
        .arg(p)
        .env(
            "BOUNDARY_READ_ROOT",
            root.parent().unwrap().join("declared"),
        )
        .output()
        .unwrap()
}

fn success(o: Output) {
    assert!(o.status.success(), "{}", detail(&o));
    assert!(
        String::from_utf8_lossy(&o.stdout).contains("ok:boundary"),
        "{}",
        detail(&o)
    );
}

#[test]
fn sandboxed_classes_withhold_unmanaged_io_and_every_loader_alias() {
    for class in [PredicateClass::Cacheable, PredicateClass::Observing] {
        let lua = build_environment(class).unwrap();
        lua.load(r#"
            for _, name in ipairs({'package', 'require', 'loadfile', 'dofile', 'debug'}) do
                assert(_G[name] == nil, name)
            end
            if io then
                for k in pairs(io) do
                    assert(k == 'write' or k == 'flush' or k == 'lines' or k == 'stdout' or k == 'stderr', 'io.' .. k)
                end
                assert(io.tmpfile == nil and io.stdin == nil)
                assert(type(io.stderr) == 'table' and io.stderr.read == nil and io.stderr.close == nil)
                assert(not pcall(function() io.lines('outside.txt') end))
            end
            if os then
                for k in pairs(os) do
                    assert(k == 'time' or k == 'date' or k == 'clock' or k == 'difftime', 'os.' .. k)
                end
            end
            assert(json.parse('{"ok":true}').ok and yaml.parse('ok: true').ok)
            assert(path.basename('a/b') == 'b' and string.upper('ok') == 'OK')
            assert(table.concat({1, 2}, ':') == '1:2')
            expert.log_info('boundary helpers preserved')
        "#).exec().unwrap();
    }
}

#[test]
fn observing_fixed_stream_io_preserves_hook_input_and_logging_without_file_handles() {
    let d = setup();
    let root = d.path().join("repo");
    let mut c = command(&root);
    let mut child = c
        .args([
            "lua",
            "-e",
            r#"
        local lines = {}
        for line in io.lines() do lines[#lines + 1] = line end
        assert(table.concat(lines, ':') == 'one:two')
        assert(io.write('stdout-control') == nil)
        assert(io.stderr:write('stderr-control') == nil)
        assert(io.stdout:write('-proxy') == nil)
        assert(io.stderr.close == nil and io.stdout.read == nil)
        assert(not pcall(function() io.lines(nil, '*a') end))
        assert(not pcall(function() package.loaded.io.lines('file') end))
    "#,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"one\ntwo\n")
        .unwrap();
    let o = child.wait_with_output().unwrap();
    assert!(o.status.success(), "{}", detail(&o));
    assert_eq!(String::from_utf8_lossy(&o.stdout), "stdout-control-proxy");
    assert_eq!(String::from_utf8_lossy(&o.stderr), "stderr-control");
}

// Worker permits direct Cacheable/Observing filesystem tests without shared env.
#[test]
fn boundary_worker() {
    let Ok(code) = std::env::var("BOUNDARY_LUA") else {
        return;
    };
    let class = if std::env::var("BOUNDARY_CLASS").as_deref() == Ok("cacheable") {
        PredicateClass::Cacheable
    } else {
        PredicateClass::Observing
    };
    build_environment(class).unwrap().load(code).exec().unwrap();
}

#[test]
fn scratch_read_write_rename_delete_fail_but_rooted_read_works_in_both_classes() {
    let d = setup();
    let root = d.path().join("repo");
    let outside = d.path().join("outside/deep/secret.txt");
    let destination = d.path().join("outside/new.txt");
    for class in ["cacheable", "observing"] {
        let code = format!(
            r#"
            assert(fs.read('files/a.txt') == 'scratch-control\n')
            local calls = {{
                function() return fs.read({outside:?}) end,
                function() return io.lines({outside:?})() end,
                function() return io.open({destination:?}, 'w') end,
                function() return io.tmpfile() end,
                function() return os.rename({outside:?}, {destination:?}) end,
                function() return os.remove({outside:?}) end,
                function() return package.loaded.io.lines({outside:?})() end,
                function() return package.loaded.os.remove({outside:?}) end,
                function() return package.loadlib({outside:?}, 'x') end,
                function() return require('io').lines({outside:?})() end,
                function() return loadfile({outside:?}) end,
                function() return dofile({outside:?}) end,
                function() return debug.getregistry() end,
            }}
            for i, call in ipairs(calls) do assert(not pcall(call), 'bypass ' .. i) end
        "#,
            outside = outside.to_str().unwrap(),
            destination = destination.to_str().unwrap()
        );
        let template = command(&root);
        let mut worker = Command::new(std::env::current_exe().unwrap());
        worker.current_dir(&root);
        for (k, v) in template.get_envs() {
            if let Some(v) = v {
                worker.env(k, v);
            } else {
                worker.env_remove(k);
            }
        }
        let o = worker
            .args(["--exact", "boundary_worker", "--nocapture"])
            .env("BOUNDARY_LUA", code)
            .env("BOUNDARY_CLASS", class)
            .output()
            .unwrap();
        assert!(o.status.success(), "{class}: {}", detail(&o));
        assert_eq!(fs::read_to_string(&outside).unwrap(), "scratch-control\n");
        assert!(!destination.exists());
    }
    // Positive raw-VM control: the scratch file is readable/writable, not merely
    // inaccessible due to OS permissions. Trusted opt-in remains unchanged.
    let raw = mlua::Lua::new();
    raw.load(format!(r#"
        local f = assert(io.open({outside:?})); assert(f:read('*a') == 'scratch-control\n'); f:close()
        local f = assert(io.open({destination:?}, 'w')); f:write('raw-control'); f:close()
        assert(os.rename({destination:?}, {renamed:?})); assert(os.remove({renamed:?}))
    "#, outside = outside.to_str().unwrap(), destination = destination.to_str().unwrap(), renamed = d.path().join("outside/renamed.txt").to_str().unwrap())).exec().unwrap();
}

#[test]
fn script_rooted_writes_keep_fixture_scope_and_declared_env_controls() {
    let d = setup();
    let root = d.path().join("repo");
    success(script(
        &root,
        "-- @env BOUNDARY_READ_ROOT",
        r#"
        assert(env.get('BOUNDARY_READ_ROOT') ~= nil)
        assert(not pcall(function() env.get('UNDECLARED') end))
        fs.write('scope/new.txt', 'allowed')
        assert(fs.read('scope/new.txt') == 'allowed')
        assert(not pcall(function() fs.write('files/denied.txt', 'denied') end))
        assert(not pcall(function() fs.write('../outside/denied.txt', 'denied') end))
        assert(type(proc.run) == 'function' and type(sh.run) == 'function')
        assert(type(time.now_ms()) == 'number')
    "#,
    ));
    assert!(!root.join("files/denied.txt").exists());
    success(script(
        &root,
        "-- @class cacheable",
        "assert(fs.walk == nil and fs.write == nil and env == nil)",
    ));
}

#[cfg(unix)]
#[test]
fn script_walk_refuses_start_and_intermediate_escape_without_following_descendants() {
    use std::os::unix::fs::symlink;
    let d = setup();
    let root = d.path().join("repo");
    symlink(d.path().join("outside"), root.join("start-out")).unwrap();
    symlink("files", root.join("alias")).unwrap();
    symlink(d.path().join("outside"), root.join("files/descendant")).unwrap();
    symlink(
        d.path().join("outside/deep/secret.txt"),
        root.join("files/file-link.txt"),
    )
    .unwrap();
    symlink(d.path().join("outside"), d.path().join("declared/escape")).unwrap();
    symlink(d.path().join("declared"), d.path().join("declared-alias")).unwrap();
    let quoted = |p: PathBuf| format!("{:?}", p.to_str().unwrap());
    success(script(
        &root,
        "-- @read-env BOUNDARY_READ_ROOT",
        &format!(
            r#"
        for _, p in ipairs({{'start-out', 'start-out/deep', 'start-out/missing', '../outside', {outside}, {sibling}, {declared_escape}, {declared_sibling}}}) do
            local ok, e = pcall(function() return fs.walk(p) end)
            assert(not ok and tostring(e):find('fs.walk:'), 'walk escape ' .. p)
        end
        assert(not pcall(function() fs.read('start-out/deep/secret.txt') end))
        assert(table.concat(fs.walk('files', {{suffix='.txt'}}), ',') == 'files/a.txt,files/z.txt')
        assert(table.concat(fs.walk('alias', {{suffix='.txt'}}), ',') == 'alias/a.txt,alias/z.txt')
        assert(#fs.walk('missing/deep') == 0)
        assert(#fs.walk({absolute_alias}, {{suffix='.txt'}}) == 2)
        assert(fs.walk({absolute_alias}, {{suffix='.txt'}})[1] == {absolute_alias} .. '/a.txt')
        assert(#fs.walk({declared_alias}) == 1)
        assert(fs.walk({declared_alias})[1] == {declared_alias} .. '/allowed.txt')
        assert(fs.read({declared_alias} .. '/allowed.txt') == 'scratch-control\n')
        assert(not pcall(function() fs.walk('start-out/deep') end))
        assert(not pcall(function() fs.read({declared_escape} .. '/deep/secret.txt') end))
    "#,
            outside = quoted(d.path().join("outside")),
            sibling = quoted(d.path().join("repo-sibling")),
            declared_escape = quoted(d.path().join("declared/escape")),
            declared_sibling = quoted(d.path().join("declared-sibling")),
            absolute_alias = quoted(root.join("alias")),
            declared_alias = quoted(d.path().join("declared-alias"))
        ),
    ));
    // Declared read capabilities widen ABSOLUTE paths only, not repo-relative links.
    symlink(d.path().join("declared"), root.join("relative-declared")).unwrap();
    success(script(
        &root,
        "-- @read-env BOUNDARY_READ_ROOT",
        "assert(not pcall(function() fs.walk('relative-declared') end))",
    ));
    success(script(
        &root,
        "",
        &format!(
            "assert(not pcall(function() fs.walk({}) end))",
            quoted(d.path().join("declared"))
        ),
    ));
}
