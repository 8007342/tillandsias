// @trace order:1384-aixy, spec:ci-release
//
// proc.run{argv=...} — the synchronous first slice of 1384-aixy (design
// plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md section 4.1).
// One test per arm of the row's verifiable_closure that this slice covers:
// arms 1, 2, 3, 5, 6 and 7. Arm 4 (proc.spawn with line callbacks) belongs to
// the next slice. Each arm names what it FAILED on before this slice: there
// was no `proc` global at all, only the synchronous `sh.run`, whose deadline
// killed the child alone.
//
// These tests run real processes. They need bash (Linux, macOS, and Git for
// Windows all ship it) and SKIP BY NAME where it is absent.

use std::path::PathBuf;
use std::time::{Duration, Instant};
use tillandsias_plan::lua_predicate::{PredicateClass, build_environment};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap()
}

fn bash_available() -> bool {
    std::process::Command::new("bash")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Evaluate `chunk` in the OBSERVING class and return what it returns.
fn observing<T: mlua::FromLuaMulti>(chunk: &str) -> mlua::Result<T> {
    let lua = build_environment(PredicateClass::Observing).expect("observing environment");
    lua.load(chunk).eval::<T>()
}

fn lua_path(p: &std::path::Path) -> String {
    p.display().to_string().replace('\\', "/")
}

// @trace order:1534-puyz
// Linux-only slice evidence. Native Mac/Windows measurement remains open.
#[cfg(target_os = "linux")]
mod managed_script {
    use super::*;
    struct ScriptFixture {
        dir: tempfile::TempDir,
    }

    impl ScriptFixture {
        fn new() -> Self {
            let base = if std::path::Path::new("/tmp/opencode").is_dir() {
                PathBuf::from("/tmp/opencode")
            } else {
                std::env::temp_dir()
            };
            let dir = tempfile::Builder::new()
                .prefix("sol-1534-")
                .tempdir_in(base)
                .unwrap();
            std::fs::create_dir(dir.path().join(".git")).unwrap();
            std::fs::create_dir(dir.path().join(".tillandsias")).unwrap();
            Self { dir }
        }
        fn write(&self, name: &str, body: &str) -> String {
            let path = self.dir.path().join(name);
            std::fs::write(&path, body).unwrap();
            lua_path(&path)
        }
        fn run(&self, body: &str, timeout: &str) -> std::process::Output {
            let script = self.write("probe.lua", body);
            // Read-only red/green evidence can exercise the identical regression
            // against the pre-fix binary snapshot without rebuilding old source.
            let binary = std::env::var_os("TILLANDSIAS_LUA_PROC_TEST_BIN")
                .unwrap_or_else(|| env!("CARGO_BIN_EXE_tillandsias-plan").into());
            std::process::Command::new(binary)
                .args(["script", "run", &script, "--timeout", timeout])
                .env("TILLANDSIAS_REPO_ROOT", self.dir.path())
                .env_remove("TILLANDSIAS_POLICY_SEED")
                .env_remove("TILLANDSIAS_CONSENT_TOKEN")
                .env_remove("CI")
                .env_remove("TILLANDSIAS_SKILL")
                .env_remove("TILLANDSIAS_DESTRUCTIVE_RESET_OK")
                .env("TILLANDSIAS_POLICY_REGIME", "interactive")
                .env("TILLANDSIAS_CONSENT_DIR", self.dir.path().join("consent"))
                .current_dir(self.dir.path())
                .output()
                .unwrap()
        }
    }

    #[test]
    fn live_spawn_delivers_10000_ordered_lines_per_fd_before_wait_and_preserves_cr() {
        let f = ScriptFixture::new();
        let producer = f.write("producer.py", "import os\nfor i in range(10000):\n os.write(1, ('%d\\r\\n'%i).encode()); os.write(2, ('E%d\\r\\n'%i).encode())\nos.write(1,b'last')\n");
        let out = f.run(
            &format!(
                r#"
        local p = proc.spawn{{argv={{"python3", "{producer}"}}, capture_bytes=17}}
        local n, e, last = 0, 0, false
        p:on_line("stdout", function(line)
            if n == 10000 then assert(line == "last"); last=true
            else assert(line == tostring(n).."\r"); n=n+1 end
        end)
        p:on_line("stderr", function(line) assert(line == "E"..tostring(e).."\r"); e=e+1 end)
        local c = p:wait()
        assert(n == 10000 and e == 10000 and last)
        assert(c.status == "exited" and c.code == 0 and c.truncated and not c.ok)
        assert(#c.stdout == 17 and #c.stderr == 17 and c.dropped > 0)
        verdict.ok("ordered", n, e)
    "#
            ),
            "10s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&out.stdout),
            "ok:ordered:10000:10000\n"
        );
    }

    #[test]
    fn live_callback_acknowledgement_and_two_producers_prove_scope_wide_dispatch() {
        let f = ScriptFixture::new();
        let producer = f.write(
            "live.py",
            r#"import os,sys,time
n=sys.argv[1]
open('started-'+n,'w').write('started')
end=time.monotonic()+3
while not (os.path.exists('started-1') and os.path.exists('started-2')):
 if time.monotonic()>end: sys.exit(8)
 time.sleep(.005)
os.write(1,('READY'+n+'\n').encode())
while not os.path.exists('ack-'+n):
 if time.monotonic()>end: sys.exit(9)
 time.sleep(.005)
os.write(1,('DONE'+n+'\n').encode())
"#,
        );
        let out = f.run(
            &format!(
                r#"
        local a = proc.spawn{{argv={{"python3", "{producer}", "1"}}}}
        local b = proc.spawn{{argv={{"python3", "{producer}", "2"}}}}
        local ready, done = 0, 0
        local function line(s)
            local n = s:match("^READY([12])$")
            if n then
                assert(fs.exists("started-1") and fs.exists("started-2"))
                fs.write("ack-"..n, "ack"); ready=ready+1
            else assert(s:match("^DONE[12]$")); done=done+1 end
        end
        a:on_line("stdout", line); b:on_line("stdout", line)
        assert(a:wait().ok); assert(b:wait().ok)
        assert(ready == 2 and done == 2)
        verdict.ok("live-overlap")
    "#
            ),
            "6s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert_eq!(String::from_utf8_lossy(&out.stdout), "ok:live-overlap\n");
    }

    // This producer acknowledges BOTH processes before the outer timer fires.
    // Its long-deadline control proves delayed markers would appear without cleanup.
    const OWNED_PRODUCER: &str = r#"import os,sys,time,subprocess,json
def identity():
 return {'pid':os.getpid(),'pgid':os.getpgrp(),'start':open('/proc/self/stat').read().split()[21]}
if len(sys.argv)>1:
 open('grandchild-ack','w').write(json.dumps(identity()))
 time.sleep(1.1); open('grandchild-marker','w').write('survived')
 sys.exit(0)
p=subprocess.Popen([sys.executable,__file__,'grandchild'])
while not os.path.exists('grandchild-ack'): time.sleep(.005)
open('child-ack','w').write(json.dumps(identity()))
os.write(1,b'READY\n')
time.sleep(1.1); open('child-marker','w').write('survived')
p.wait()
"#;

    fn assert_acknowledged_tasks_stopped(f: &ScriptFixture) {
        for name in ["child", "grandchild"] {
            let ack: serde_json::Value = serde_json::from_str(
                &std::fs::read_to_string(f.dir.path().join(format!("{name}-ack")))
                    .expect("producer must acknowledge before cancellation"),
            )
            .unwrap();
            let pid = ack["pid"].as_u64().unwrap();
            if let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) {
                let fields: Vec<_> = stat.split_whitespace().collect();
                assert!(
                    fields[21] != ack["start"].as_str().unwrap() || fields[2] == "Z",
                    "{name} still running: {stat}"
                );
            }
        }
        std::thread::sleep(Duration::from_millis(1200));
        for name in ["child-marker", "grandchild-marker"] {
            assert!(!f.dir.path().join(name).exists(), "delayed {name}");
        }
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn outer_deadline_cancels_acknowledged_legacy_and_streaming_groups_with_positive_control() {
        for door in ["proc.run", "sh.run", "expert.shell", "proc.spawn"] {
            let f = ScriptFixture::new();
            let producer = f.write("owned.py", OWNED_PRODUCER);
            let call = if door == "sh.run" || door == "expert.shell" {
                format!(r#"{door}{{"python3", "{producer}", timeout_ms=4000}}"#)
            } else {
                format!(r#"{door}{{argv={{"python3", "{producer}"}},timeout_ms=4000}}"#)
            };
            let script = if door == "proc.spawn" {
                format!("local p={call}; p:wait(); verdict.ok('survived')")
            } else {
                format!("{call}; verdict.ok('survived')")
            };
            let t0 = Instant::now();
            let out = f.run(&script, "700ms");
            assert_eq!(
                out.status.code(),
                Some(124),
                "door={door}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            assert!(t0.elapsed() < Duration::from_secs(2), "door={door}");
            assert_acknowledged_tasks_stopped(&f);
        }
        let f = ScriptFixture::new();
        let producer = f.write("owned.py", OWNED_PRODUCER);
        let out = f.run(&format!(r#"assert(proc.run{{argv={{"python3","{producer}"}},timeout_ms=4000}}.ok); verdict.ok("control")"#), "3500ms");
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(f.dir.path().join("child-marker").exists());
        assert!(f.dir.path().join("grandchild-marker").exists());
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn script_lifetime_cancels_cpu_loop_error_verdict_and_dropped_handles() {
        for ending in [
            "while true do end",
            "error('script-broke')",
            "verdict.ok('early')",
            "p=nil; collectgarbage(); verdict.ok('dropped')",
            "pcall(verdict.ok,'caught'); while true do end",
        ] {
            let f = ScriptFixture::new();
            let producer = f.write("owned.py", OWNED_PRODUCER);
            let script = format!(
                r#"
            local p=proc.spawn{{argv={{"python3","{producer}"}}}}
            p:on_line("stdout", function(s) assert(s=="READY"); error("ack-stop") end)
            -- An acknowledged start without consuming the callback: legacy run
            -- blocks only Lua, while independent supervisors keep moving.
            proc.run{{argv={{"python3","-c","import os,time;\nwhile not os.path.exists('child-ack'): time.sleep(.005)"}}}}
            {ending}
        "#
            );
            let out = f.run(&script, "700ms");
            if ending == "while true do end" {
                assert_eq!(out.status.code(), Some(124));
            } else if ending.contains("error(") {
                assert_eq!(out.status.code(), Some(1));
            } else {
                assert!(
                    out.status.success(),
                    "{}",
                    String::from_utf8_lossy(&out.stderr)
                );
            }
            assert_acknowledged_tasks_stopped(&f);
        }
    }

    #[test]
    fn caught_callback_error_and_reentrant_wait_latch_scope_closure() {
        for action in [
            "error('callback-broke')",
            "p:wait()",
            "verdict.ok('callback-verdict')",
        ] {
            let f = ScriptFixture::new();
            let producer = f.write(
                "callback.py",
                "import os,time\nos.write(1,b'READY\\n')\ntime.sleep(30)\n",
            );
            let out = f.run(
                &format!(
                    r#"
            local p=proc.spawn{{argv={{"python3","{producer}"}}}}
            p:on_line("stdout", function(s) {action} end)
            pcall(function() p:wait() end)
            -- Closure must survive catching the callback's raised error.
            proc.spawn{{argv={{"python3","-c","open('escaped','w').write('bad')"}}}}
            verdict.ok("wrong")
        "#
                ),
                "2s",
            );
            assert!(!f.dir.path().join("escaped").exists());
            if action.contains("verdict") {
                assert!(out.status.success());
                assert_eq!(
                    String::from_utf8_lossy(&out.stdout),
                    "ok:callback-verdict\n"
                );
            } else {
                assert_eq!(out.status.code(), Some(1));
            }
        }
    }

    #[test]
    fn spawn_validation_missing_program_kill_and_line_limit_are_explicit() {
        let f = ScriptFixture::new();
        let out = f.run(
            r#"
        assert(not pcall(function() proc.spawn{argv={"true"}, group=false} end))
        assert(not pcall(function() proc.spawn{argv={"true"}, timeout=1} end))
        assert(proc.spawn{argv={"/definitely-no-such-program-1534"}}.status=="spawn_failed")
        local p=proc.spawn{argv={"sleep","30"}}
        assert(not pcall(function() p:on_line("merged",function() end) end))
        assert(not pcall(function() p:on_line("stdout",42) end))
        local c=p:kill(); assert(not c.ok and c.status=="signaled")
        verdict.ok("validation")
    "#,
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let producer = f.write(
            "busy.py",
            "import os\nwhile True: os.write(1,b'x\\n'*8192)\n",
        );
        let out = f.run(
            &format!(
                r#"
            local p=proc.spawn{{argv={{'python3','{producer}'}}}}
            -- Fill the delivery queue while Lua is synchronously elsewhere.
            proc.run{{argv={{'sleep','0.1'}}}}
            local n=0; p:on_line('stdout',function(s) assert(s=='x'); n=n+1 end)
            local c=p:kill(); assert(not c.ok and n>0)
            verdict.ok('kill-backpressure')
        "#
            ),
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let producer = f.write("huge.py", "import os\nos.write(1,b'x'*1048577)\n");
        let out = f.run(&format!(r#"local p=proc.spawn{{argv={{"python3","{producer}"}}}}; p:wait(); verdict.ok('wrong')"#), "3s");
        assert_eq!(out.status.code(), Some(1));
        assert!(String::from_utf8_lossy(&out.stderr).contains("proc-line-too-long"));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn callbacks_cancel_owned_groups_even_when_caught_or_cpu_bound() {
        for action in [
            "error('callback-broke')",
            "p:wait()",
            "p:kill()",
            "proc.run{argv={'true'}}",
            "proc.spawn{argv={'true'}}",
            "verdict.ok('callback-verdict')",
            "pcall(verdict.ok,'callback-verdict'); while true do end",
            "while true do end",
        ] {
            let f = ScriptFixture::new();
            let producer = f.write("owned.py", OWNED_PRODUCER);
            let out = f.run(
                &format!(
                    r#"
            local p=proc.spawn{{argv={{"python3","{producer}"}}}}
            p:on_line("stdout",function(s) assert(s=='READY'); {action} end)
            pcall(function() p:wait() end)
            while true do end
        "#
                ),
                "700ms",
            );
            if action == "while true do end" {
                assert_eq!(out.status.code(), Some(124));
            } else if action.contains("verdict") {
                assert!(out.status.success());
            } else {
                assert_eq!(
                    out.status.code(),
                    Some(1),
                    "{action}: {}",
                    String::from_utf8_lossy(&out.stderr)
                );
            }
            assert_acknowledged_tasks_stopped(&f);
        }
    }

    #[test]
    fn streaming_keeps_default_8mib_prefix_and_byte_exact_empty_binary_lines() {
        let f = ScriptFixture::new();
        let producer = f.write(
            "bytes.py",
            "import os\nos.write(1,b'\\n\\r\\nA\\x00\\xff\\r\\nlast')\nos.write(2,b'E\\n')\n",
        );
        let out = f.run(
            &format!(
                r#"
        local p=proc.spawn{{argv={{"python3","{producer}"}}}}
        local expected={{"", "\r", "A"..string.char(0,255).."\r", "last"}}
        local i=0
        p:on_line('stdout',function(s) i=i+1; assert(s==expected[i]) end)
        assert(p:wait().ok and i==4)
        verdict.ok('bytes')
    "#
            ),
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let producer = f.write(
            "cap.py",
            "import os\nfor i in range(9216): os.write(1,b'X'*1023+b'\\n')\n",
        );
        let out = f.run(
            &format!(
                r#"
        local p=proc.spawn{{argv={{"python3","{producer}"}}}}
        local n=0
        p:on_line('stdout',function(s) assert(#s==1023); n=n+1 end)
        local c=p:wait()
        assert(n==9216 and #c.stdout==8*1024*1024 and c.dropped==1024*1024)
        assert(c.stdout:sub(1,1024)==string.rep('X',1023)..'\n')
        assert(c.truncated and not c.ok and c.code==0)
        verdict.ok('bounded-prefix')
    "#
            ),
            "10s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn scoped_spawn_preserves_fixed_environment_stdin_and_cacheable_process_absence() {
        let f = ScriptFixture::new();
        let producer = f.write("env.py", "import os,sys\nassert os.environ['LC_ALL']=='C' and os.environ['LANG']=='C' and os.environ['TZ']=='UTC'\nassert os.environ['GIT_TERMINAL_PROMPT']=='0' and os.environ['EXPLICIT']=='yes'\nos.write(1,sys.stdin.buffer.read())\n");
        let out = f.run(
            &format!(
                r#"
        local bytes='stdin'..string.char(0,255)..'\r\n'
        local p=proc.spawn{{argv={{'python3','{producer}'}},env={{EXPLICIT='yes'}},stdin=bytes}}
        local c=p:wait(); assert(c.ok and c.stdout==bytes)
        assert(p:wait().run_id==c.run_id)
        verdict.ok('env-stdin')
    "#
            ),
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let root = lua_path(f.dir.path());
        let out=f.run(&format!(r#"
            for _,door in ipairs({{proc.run,proc.spawn}}) do
                local reads=0
                local spec=setmetatable({{argv={{'python3','-c','import os; print(os.getcwd())'}}}},{{__index=function(_,key)
                    if key=='cwd' then reads=reads+1; if reads==1 then return '{root}' else return '{root}/.git' end end
                end}})
                local p=door(spec)
                local c=p.wait and p:wait() or p
                assert(reads==1 and c.ok and c.stdout=='{root}\n', 'cwd snapshot drift')
            end
            verdict.ok('cwd-snapshot')
        "#), "3s");
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let out=f.run("-- @class cacheable\nassert(proc==nil and sh==nil and expert.shell==nil); verdict.ok('pure')", "3s");
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn finished_stream_releases_callback_captures_after_dropped_handle() {
        let f = ScriptFixture::new();
        let out = f.run(
            r#"
            local weak=setmetatable({}, {__mode='v'})
            do
                local marker={}; weak[1]=marker
                local p=proc.spawn{argv={'printf','line\n'}}
                p:on_line('stdout',function(s) assert(marker and s=='line') end)
                assert(p:wait().ok)
                assert(not pcall(function() p:on_line('stdout',function() end) end))
                p=nil
            end
            collectgarbage('collect'); collectgarbage('collect')
            assert(weak[1]==nil, 'host retained a finished callback')
            verdict.ok('callback-released')
        "#,
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    #[cfg(unix)]
    fn spawn_policy_seed_consent_and_programmer_validation_share_hardened_gate() {
        use std::os::unix::fs::PermissionsExt;
        use tillandsias_plan::command_policy as cp;
        let f = ScriptFixture::new();
        // Harmless marker executable named rm; NEVER the system rm.
        let program = f.write("rm", "#!/bin/sh\nprintf ran >> marker\n");
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        let argv = vec![
            program,
            "-rf".into(),
            lua_path(&f.dir.path().with_extension("outside-unused")),
        ];
        let args = argv
            .iter()
            .map(|s| format!("{s:?}"))
            .collect::<Vec<_>>()
            .join(",");
        let chunk = format!(
            r#"assert(proc.spawn{{argv={{{args}}}}}.status=='policy_consent_required'); verdict.ok('consent-required')"#
        );
        assert!(f.run(&chunk, "3s").status.success());
        assert!(!f.dir.path().join("marker").exists());
        let ctx = cp::ConsentCtx {
            dir: f.dir.path().join("consent"),
            host: cp::this_host(),
            now: chrono::Utc::now(),
            evidence: cp::HostKind::BareMetal,
            skill: None,
            reset_ok: None,
        };
        let (token, _) = cp::consent_grant(&ctx, "workspace-destroy", &argv, 1800).unwrap();
        let original = std::fs::read(&token).unwrap();
        for invalid in [
            "group=false",
            "timeout_ms='typo'",
            "capture_bytes=0",
            "env={X=42}",
            "cwd='relative'",
            "unknown=true",
            "env={X='a'..string.char(0)}",
        ] {
            let chunk = format!(
                r#"assert(not pcall(function() proc.spawn{{argv={{{args}}},{invalid}}} end)); verdict.ok('invalid')"#
            );
            let out = f.run(&chunk, "3s");
            assert!(
                out.status.success(),
                "{invalid}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            assert_eq!(
                std::fs::read(&token).unwrap(),
                original,
                "{invalid} consumed consent"
            );
            assert!(!f.dir.path().join("marker").exists());
        }
        let seed_path = f.dir.path().join(cp::SEED_RELATIVE_PATH);
        for bad in [
            "version: [",
            "version: 1\ndefault: allow\nrules:\n  - id: deny-rm\n    program: rm\n    decision: deny\n",
        ] {
            std::fs::write(&seed_path, bad).unwrap();
            let out=f.run(&format!(r#"assert(proc.spawn{{argv={{{args}}}}}.status=='policy_denied'); verdict.ok('denied')"#), "3s");
            assert!(
                out.status.success(),
                "seed={bad}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            assert_eq!(std::fs::read(&token).unwrap(), original);
            assert!(!f.dir.path().join("marker").exists());
        }
        // A default applies to UNMATCHED commands, not a classified floor rule.
        // Preserve that existing distinction rather than flipping policy semantics.
        let harmless = f.write("harmless", "#!/bin/sh\nprintf bad >> denied-marker\n");
        std::fs::set_permissions(&harmless, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(&seed_path, "version: 1\ndefault: deny\nrules: []\n").unwrap();
        let out=f.run(&format!(r#"assert(proc.spawn{{argv={{{harmless:?}}}}}.status=='policy_denied'); verdict.ok('default-denied')"#), "3s");
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(!f.dir.path().join("denied-marker").exists());
        assert_eq!(std::fs::read(&token).unwrap(), original);
        std::fs::remove_file(seed_path).unwrap();
        let out=f.run(&format!(r#"local p=proc.spawn{{argv={{{args}}}}}; assert(p:wait().ok); verdict.ok('approved')"#), "3s");
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(!token.exists());
        assert_eq!(
            std::fs::read_to_string(f.dir.path().join("marker")).unwrap(),
            "ran"
        );
        assert!(f.run(&chunk, "3s").status.success());
        assert_eq!(
            std::fs::read_to_string(f.dir.path().join("marker")).unwrap(),
            "ran"
        );
        assert_eq!(
            std::fs::read_to_string(f.dir.path().join("consent/consumed.jsonl"))
                .unwrap()
                .lines()
                .count(),
            1
        );
    }
}

/// ARM 1: a non-zero exit is DATA, not a Lua error; and argv is argv.
#[test]
fn arm1_a_failing_program_is_a_value_and_argv_is_not_reparsed() {
    if !bash_available() {
        eprintln!("skip:lua_proc:arm1:no-bash");
        return;
    }
    let (status, code, ok): (String, i64, bool) = observing(
        r#"local f = proc.run{argv = {"false"}}
           return f.status, f.code, f.ok"#,
    )
    .expect("a non-zero exit must not raise");
    assert_eq!((status.as_str(), code, ok), ("exited", 1, false));

    let out: String =
        observing(r#"return proc.run{argv = {"printf", "%s", "a b*c"}}.stdout"#).unwrap();
    assert_eq!(
        out, "a b*c",
        "one argv element stays one token, `*` unexpanded"
    );
}

/// ARM 2: 1 MiB on stdout AND 1 MiB on stderr both come back in full.
#[test]
fn arm2_both_fds_drain_concurrently_in_full() {
    if !bash_available() {
        eprintln!("skip:lua_proc:arm2:no-bash");
        return;
    }
    let (o, e, ok): (i64, i64, bool) = observing(
        r#"local r = proc.run{argv = {"bash", "scripts/fixtures/write-both-fds.sh"}, timeout_ms = 60000}
           return #r.stdout, #r.stderr, r.ok"#,
    )
    .unwrap();
    assert_eq!((o, e, ok), (1_048_576, 1_048_576, true));
}

/// ARM 3: a deadline kills the GROUP: timed_out, no code, under 2 s, and the
/// grandchild never writes its marker. The control runs the same fixture with
/// group = false, and the grandchild survives, which proves the grouped arm
/// is not passing because the grandchild never started.
#[test]
fn arm3_a_deadline_kills_the_whole_group() {
    if !bash_available() {
        eprintln!("skip:lua_proc:arm3:no-bash");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    for (group, expect_marker) in [(true, false), (false, true)] {
        let marker = dir.path().join(format!("survived-{group}"));
        let t0 = Instant::now();
        let (status, has_code): (String, bool) = observing(&format!(
            r#"local r = proc.run{{argv = {{"bash", "scripts/fixtures/spawn-grandchild.sh", "{m}"}},
                                   timeout_ms = 500, group = {group}}}
               return r.status, r.code ~= nil"#,
            m = lua_path(&marker)
        ))
        .unwrap();
        let elapsed = t0.elapsed();
        assert_eq!(status, "timed_out", "group={group}");
        assert!(
            !has_code,
            "a timed-out child produced no exit code (group={group})"
        );
        assert!(
            elapsed < Duration::from_secs(2),
            "deadline took {elapsed:?}"
        );
        std::thread::sleep(Duration::from_secs(6));
        assert_eq!(
            marker.exists(),
            expect_marker,
            "group={group}: grandchild {} its marker",
            if marker.exists() {
                "wrote"
            } else {
                "did not write"
            }
        );
    }
}

/// ARM 5: a shell handed a command STRING is refused. Since 1443-isrk the
/// refusal is the command policy's, returned as a VALUE naming its rule (it
/// used to be a Lua error with no rule id), and nothing is spawned.
#[test]
fn arm5_a_shell_string_is_refused() {
    let (status, rule, remedy): (String, String, String) = observing(
        r#"local r = proc.run{argv = {"bash", "-c", "true | false"}}
           return r.status, r.rule_id, r.remedy"#,
    )
    .expect("a policy refusal is a value, not an error");
    assert_eq!(status, "policy_denied");
    assert_eq!(rule, "no-shell-strings");
    assert!(remedy.contains("argv"), "{remedy}");
    // A script FILE given to bash is argv, not a string, and is allowed.
    if bash_available() {
        let ok: bool = observing(
            r#"return proc.run{argv = {"bash", "scripts/fixtures/write-both-fds.sh"}}.ok"#,
        )
        .unwrap();
        assert!(ok);
    }
}

/// ARM 6: bytes flow through a variable. A consumer that exits after one line
/// cannot SIGPIPE the producer, because the producer already finished.
#[test]
fn arm6_stdin_from_a_variable_has_no_pipe_to_invert() {
    if !bash_available() {
        eprintln!("skip:lua_proc:arm6:no-bash");
        return;
    }
    let (a_status, a_code, b_out): (String, i64, String) = observing(
        // The newlines come from printf's FORMAT (`%s\n`, a backslash and an
        // n), not from an argv element: a native Windows caller's embedded
        // newline is truncated by the MSYS runtime (measured: "one").
        r#"local a = proc.run{argv = {"printf", "%s\\n", "one", "two", "three"}}
           local b = proc.run{argv = {"head", "-n", "1"}, stdin = a.stdout}
           return a.status, a.code, b.stdout"#,
    )
    .unwrap();
    assert_eq!(
        (a_status.as_str(), a_code, b_out.as_str()),
        ("exited", 0, "one\n")
    );
}

/// ARM 7: the Cacheable class never gains a process.
#[test]
fn arm7_cacheable_has_no_proc() {
    let lua = build_environment(PredicateClass::Cacheable).unwrap();
    let t: String = lua.load("return type(proc)").eval().unwrap();
    assert_eq!(t, "nil");
    let t: String = observing("return type(proc) .. ':' .. type(proc.run)").unwrap();
    assert_eq!(t, "table:function");
}

/// Programmer errors RAISE: an unknown field (a misspelt `timeout` must not
/// mean "no deadline"), a relative cwd, a string argv, an empty argv.
#[test]
fn programmer_errors_raise_and_operational_failures_do_not() {
    for (chunk, needle) in [
        (
            r#"proc.run{argv = {"true"}, timeout = 5}"#,
            "unknown field 'timeout'",
        ),
        (
            r#"proc.run{argv = {"true"}, cwd = "relative/dir"}"#,
            "relative",
        ),
        (r#"proc.run{argv = "git status"}"#, "argv must be a table"),
        (r#"proc.run{argv = {}}"#, "argv is empty"),
        (r#"proc.run{"git", "status"}"#, "positional"),
    ] {
        let err = observing::<mlua::Value>(chunk).unwrap_err().to_string();
        assert!(err.contains(needle), "{chunk} -> {err}");
    }
    // A program that does not exist is DATA.
    let (status, ok): (String, bool) = observing(
        r#"local r = proc.run{argv = {"tillandsias-no-such-program-1384"}}
           return r.status, r.ok"#,
    )
    .unwrap();
    assert_eq!((status.as_str(), ok), ("spawn_failed", false));
}

/// The environment is the fixed base set: the caller's locale does not leak.
#[test]
fn the_child_environment_is_the_base_set() {
    if !bash_available() {
        eprintln!("skip:lua_proc:env:no-bash");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let script = dir.path().join("env.sh");
    std::fs::write(
        &script,
        "printf '%s|%s|%s' \"$LC_ALL\" \"$TZ\" \"${UNRELATED_1384:-unset}\"\n",
    )
    .unwrap();
    // SAFETY: this test owns this variable name; nothing else reads it.
    unsafe { std::env::set_var("UNRELATED_1384", "leaked") };
    let out: String = observing(&format!(
        r#"return proc.run{{argv = {{"bash", "{s}"}}, env = {{EXTRA = "x"}}}}.stdout"#,
        s = lua_path(&script)
    ))
    .unwrap();
    unsafe { std::env::remove_var("UNRELATED_1384") };
    assert_eq!(out, "C|UTC|unset");
    let _ = repo_root();
}

/// Order 1394-mdqj: a caller that PIPES the plan binary must not wait for a
/// grandchild the script's child leaked. The CLI runs with its stdout piped to
/// this test; its script runs an UNGROUPED child that leaves a background
/// grandchild, under a 500 ms deadline. Reading the CLI's stdout reaches EOF
/// promptly only if the child did not inherit the CLI's own stdout handle.
/// PRE-FIX RESULT (native Windows, yolanda 2026-09-26): about 30.4 s, the
/// grandchild's sleep (30558 / 30421 ms), against 745 / 723 ms redirected to a
/// file. Linux does not inherit that way; the test passes there too, and says
/// nothing about Windows unless it runs there.
#[test]
fn a_piped_caller_is_not_held_by_a_leaked_grandchild() {
    if !bash_available() {
        eprintln!("skip:lua_proc:piped-caller:no-bash");
        return;
    }
    use std::io::Read as _;
    let dir = tempfile::tempdir().unwrap();
    let marker = lua_path(&dir.path().join("m"));
    let script = format!(
        r#"local r = proc.run{{argv = {{"bash", "scripts/fixtures/spawn-grandchild.sh", "{marker}"}},
                               timeout_ms = 500, group = false}}
           print(r.status)"#
    );
    let t0 = Instant::now();
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .args(["lua", "-e", &script])
        .current_dir(repo_root())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn the plan CLI");
    let mut out = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut out)
        .unwrap();
    let eof_after = t0.elapsed();
    let _ = child.wait();
    assert!(
        out.contains("timed_out"),
        "the deadline must have fired: {out:?}"
    );
    assert!(
        eof_after < Duration::from_secs(3),
        "the caller's pipe stayed open {eof_after:?}: a leaked grandchild holds it"
    );
}

/// ORDER 1443-esm5, the proc.run arm: a capture clipped by `capture_bytes` is
/// NOT ok, even on a clean exit. The child writes 3 MiB under a 1 MiB cap, so
/// the result must say exited/0 AND ok=false, truncated=true, dropped=2 MiB,
/// and a Lua caller cannot read the clipped capture as a whole one.
/// PRE-FIX: FAILS — proc.run raised "unknown field 'capture_bytes'".
#[test]
fn capture_bytes_a_clipped_capture_is_not_ok() {
    if !bash_available() {
        eprintln!("skip:lua_proc:capture_bytes:no-bash");
        return;
    }
    let (status, code, ok, truncated, dropped, len): (String, i64, bool, bool, i64, i64) =
        observing(
            r#"local r = proc.run{argv = {"head", "-c", "3145728", "/dev/zero"},
                                  capture_bytes = 1048576, timeout_ms = 60000}
               return r.status, r.code, r.ok, r.truncated, r.dropped, #r.stdout"#,
        )
        .unwrap();
    assert_eq!(
        (status.as_str(), code, ok, truncated, dropped, len),
        ("exited", 0, false, true, 2 * 1_048_576, 1_048_576)
    );

    // NEGATIVE CONTROL: 100 bytes under the same cap is whole and ok.
    let (ok, truncated, dropped): (bool, bool, i64) = observing(
        r#"local r = proc.run{argv = {"head", "-c", "100", "/dev/zero"}, capture_bytes = 1048576}
           return r.ok, r.truncated, r.dropped"#,
    )
    .unwrap();
    assert_eq!((ok, truncated, dropped), (true, false, 0));

    // A cap that is not a positive integer is a programmer error and RAISES.
    let err = observing::<mlua::Value>(r#"return proc.run{argv = {"true"}, capture_bytes = 0}"#)
        .unwrap_err()
        .to_string();
    assert!(
        err.contains("capture_bytes must be a positive integer"),
        "{err}"
    );
}

/// ORDER 1443-8pur slice 1b, the proc.run half: proc.run shares the executor's
/// group run, so a grandchild that keeps stdout neither turns the leader's
/// exit 0 into a timeout nor survives the call.
/// PRE-FIX: FAILS — the call waited for the deadline and reported timed_out.
#[test]
fn a_grandchild_neither_times_out_nor_outlives_proc_run() {
    if !bash_available() {
        eprintln!("skip:lua_proc:group-exit:no-bash");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let script = dir.path().join("keep.sh");
    std::fs::write(&script, "sleep 30 &\necho $!\nexit 0\n").unwrap();
    let t0 = Instant::now();
    let (status, code, pid): (String, i64, String) = observing(&format!(
        r#"local r = proc.run{{argv = {{"bash", "{p}"}}, timeout_ms = 10000}}
           return r.status, r.code, r.stdout"#,
        p = lua_path(&script)
    ))
    .unwrap();
    assert_eq!((status.as_str(), code), ("exited", 0));
    assert!(
        t0.elapsed() < Duration::from_secs(4),
        "took {:?}",
        t0.elapsed()
    );
    let pid = pid.trim();
    std::thread::sleep(Duration::from_millis(50));
    let alive = std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .map(|s| {
            s.rsplit(')')
                .next()
                .map(|r| !r.trim_start().starts_with('Z'))
                .unwrap_or(false)
        })
        .unwrap_or(false);
    assert!(!alive, "grandchild {pid} outlived proc.run");
}
