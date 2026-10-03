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
    fn caught_advisory_prevents_new_proc_run_and_spawn() {
        for door in ["proc.run", "proc.spawn"] {
            let f = ScriptFixture::new();
            let out = f.run(
                &format!(
                    r#"
                pcall(verdict.advisory, "scope-probe (advisory)")
                local p={door}{{argv={{"touch","escaped"}}}}
                if p.wait then p:wait() end
                verdict.ok("wrong")
            "#
                ),
                "2s",
            );
            assert_eq!(out.status.code(), Some(0));
            assert_eq!(out.stdout, b"scope-probe (advisory)\n");
            assert!(
                !f.dir.path().join("escaped").exists(),
                "{door} escaped advisory closure"
            );
        }
    }

    #[test]
    fn caught_advisory_cpu_loop_preserves_bytes_and_cleans_acknowledged_groups_promptly() {
        let f = ScriptFixture::new();
        let producer = f.write("owned.py", OWNED_PRODUCER);
        let t0 = Instant::now();
        let out = f.run(&format!(r#"
            local p=proc.spawn{{argv={{"python3","{producer}"}}}}
            proc.run{{argv={{"python3","-c","import os,time;\nwhile not os.path.exists('child-ack'): time.sleep(.005)"}}}}
            pcall(verdict.advisory,"scope-probe (advisory)")
            while true do end
        "#), "2s");
        let elapsed = t0.elapsed();
        assert_acknowledged_tasks_stopped(&f);
        assert_eq!(out.status.code(), Some(0));
        assert_eq!(out.stdout, b"scope-probe (advisory)\n");
        assert!(
            elapsed < Duration::from_millis(1000),
            "advisory waited for outer deadline: {elapsed:?}"
        );
    }

    #[test]
    fn caught_callback_advisory_cancels_acknowledged_groups_and_preserves_bytes() {
        let f = ScriptFixture::new();
        let producer = f.write("owned.py", OWNED_PRODUCER);
        let t0 = Instant::now();
        let out = f.run(
            &format!(
                r#"
            local p=proc.spawn{{argv={{"python3","{producer}"}}}}
            p:on_line("stdout",function(s)
                assert(s=="READY")
                pcall(verdict.advisory,"callback scope-probe (advisory)")
                while true do end
            end)
            pcall(function() p:wait() end)
            proc.run{{argv={{"touch","escaped"}}}}
            verdict.ok("wrong")
        "#
            ),
            "2s",
        );
        let elapsed = t0.elapsed();
        assert_acknowledged_tasks_stopped(&f);
        assert_eq!(out.status.code(), Some(0));
        assert_eq!(out.stdout, b"callback scope-probe (advisory)\n");
        assert!(!f.dir.path().join("escaped").exists());
        assert!(
            elapsed < Duration::from_millis(1000),
            "callback advisory waited for deadline: {elapsed:?}"
        );
    }

    #[test]
    fn invalid_advisory_does_not_close_scope_or_publish_terminal_verdict() {
        let f = ScriptFixture::new();
        let out = f.run(r#"
            for _,line in ipairs({'not advisory','injected\nline (advisory)','injected\rline (advisory)'}) do
                assert(not pcall(verdict.advisory,line))
            end
            assert(proc.run{argv={'touch','valid-run'}}.ok)
            assert(proc.spawn{argv={'touch','valid-spawn'}}:wait().ok)
            verdict.ok('validation-before-close')
        "#, "2s");
        assert_eq!(out.status.code(), Some(0));
        assert_eq!(out.stdout, b"ok:validation-before-close\n");
        assert!(f.dir.path().join("valid-run").exists());
        assert!(f.dir.path().join("valid-spawn").exists());
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

    // 1538-pwdr: these are CLI-level composition contracts.  They deliberately
    // use acknowledged producers instead of sleeps to make scheduler progress
    // (rather than a fortunate process race) observable.
    #[test]
    fn composition_select_is_completion_ordered_non_consuming_and_pumps_every_producer() {
        let f = ScriptFixture::new();
        let producer = f.write(
            "select-producer.sh",
            r#"#!/bin/sh
 id=$1
 printf 'READY%s\n' "$id"
 while [ ! -f "ack-$id" ]; do sleep .01; done
 if [ "$id" = a ]; then
   while [ ! -f release-a ]; do sleep .01; done
 fi
 if [ "$id" = b ]; then
   while [ ! -f ack-x ]; do sleep .01; done
 fi
 printf '%s' "$id"
"#,
        );
        let out = f.run(
            &format!(
                r#"
            local a=proc.spawn{{argv={{'sh','{producer}','a'}}}}
            local b=proc.spawn{{argv={{'sh','{producer}','b'}}}}
            local other=proc.spawn{{argv={{'sh','{producer}','x'}}}}
            local exits={{a=false,b=false}}
            a:on_exit(function() exits.a=true end)
            b:on_exit(function() exits.b=true end)
            for _,p in ipairs({{a,b,other}}) do p:on_line('stdout',function(s)
                local id=s:match('^READY(.)$'); if id then fs.write('ack-'..id,'yes') end
            end) end
            local first=proc.select{{a,b}}
            assert(exits.b and not exits.a, 'select returned before the selected exit callback')
            assert(first==b and first:wait().stdout=='READYb\nb')
            assert(fs.exists('ack-x'), 'select did not pump non-member producer')
            fs.write('release-a','yes')
            assert(proc.select{{a,b}}==b, 'select must be non-consuming')
            local both=proc.all{{a,b}}
            assert(both[1].stdout=='READYa\na' and both[2].stdout=='READYb\nb')
            assert(other:wait().stdout=='READYx\nx', 'non-member producer was not pumped')
            verdict.ok('select-order')
        "#
            ),
            "4s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert_eq!(out.stdout, b"ok:select-order\n");
    }

    #[test]
    fn composition_select_timeout_is_nil_timed_out_and_does_not_cancel_child() {
        let f = ScriptFixture::new();
        let producer = f.write("slow-select.sh", "#!/bin/sh\nprintf 'READY\\n'\nwhile [ ! -f release-after-expiry ]; do sleep .01; done\nprintf done\n");
        let gate = f.write(
            "ack-gate.sh",
            "#!/bin/sh\nwhile [ ! -f ack ]; do sleep .01; done\nprintf gate\n",
        );
        let out = f.run(
            &format!(
                r#"
            local p=proc.spawn{{argv={{'sh','{producer}'}}}}
            p:on_line('stdout',function(s) if s=='READY' then fs.write('ack','yes') end end)
            local gate=proc.spawn{{argv={{'sh','{gate}'}}}}
            assert(gate:wait().stdout=='gate', 'gate wait must pump p READY callback')
            assert(fs.exists('ack'))
            local chosen,why=proc.select{{p,timeout_ms=10}}
            assert(chosen==nil and why=='timed_out')
            fs.write('release-after-expiry','yes')
            local c=p:wait(); assert(c.ok and c.stdout=='READY\ndone')
            assert(proc.select{{p}}==p, 'an omitted timeout uses the default and observes completion')
            verdict.ok('select-expiry')
        "#
            ),
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn composition_all_is_argument_ordered_and_empty_is_vacuous() {
        let f = ScriptFixture::new();
        let slow = f.write("slow-all.sh", "#!/bin/sh\nsleep .08\nprintf slow\n");
        let out = f.run(
            &format!(
                r#"
            local slow=proc.spawn{{argv={{'sh','{slow}'}}}}
            local fast=proc.spawn{{argv={{'printf','fast'}}}}
            local r=proc.all{{slow,fast}}
            assert(#r==2 and r[1].stdout=='slow' and r[2].stdout=='fast')
            assert(#proc.all{{}}==0)
            verdict.ok('all-order')
        "#
            ),
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn composition_all_pumps_nonmember_and_observes_member_exit_callbacks_before_return() {
        let f = ScriptFixture::new();
        let producer = f.write(
            "all-producer.sh",
            r#"#!/bin/sh
id=$1
printf 'READY%s\n' "$id"
while [ ! -f "all-ack-$id" ]; do sleep .01; done
if [ "$id" = a ]; then while [ ! -f all-release-a ]; do sleep .01; done; fi
printf '%s' "$id"
"#,
        );
        let out = f.run(
            &format!(
                r#"
            local a=proc.spawn{{argv={{'sh','{producer}','a'}}}}
            local b=proc.spawn{{argv={{'sh','{producer}','b'}}}}
            local x=proc.spawn{{argv={{'sh','{producer}','x'}}}}
            local exits={{a=false,b=false}}
            for _,p in ipairs({{a,b,x}}) do p:on_line('stdout',function(s)
              local id=s:match('^READY(.)$'); if id then
                fs.write('all-ack-'..id,'yes')
                if id=='x' then fs.write('all-release-a','yes') end
              end
            end) end
            a:on_exit(function() exits.a=true end); b:on_exit(function() exits.b=true end)
            local r=proc.all{{a,b}}
            assert(r[1].stdout=='READYa\na' and r[2].stdout=='READYb\nb')
            assert(exits.a and exits.b, 'all returned before member exit callbacks')
            assert(x:wait().stdout=='READYx\nx')
            verdict.ok('all-scope-wide')
        "#
            ),
            "4s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn composition_select_zero_has_no_own_deadline_and_outer_deadline_stops_owned_child() {
        let f = ScriptFixture::new();
        let producer = f.write("select-zero-owned.py", OWNED_PRODUCER);
        let out = f.run(
            &format!(
                r#"
            local p=proc.spawn{{argv={{'python3','{producer}'}}}}
            p:on_line('stdout',function(s) assert(s=='READY'); fs.write('zero-ack','yes') end)
            proc.select{{p,timeout_ms=0}}
            verdict.ok('wrong')
        "#
            ),
            "700ms",
        );
        assert_eq!(
            out.status.code(),
            Some(124),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(f.dir.path().join("zero-ack").exists());
        assert_acknowledged_tasks_stopped(&f);
    }

    #[test]
    fn composition_rejects_empty_select_and_invalid_handle_lists_before_waiting() {
        let f = ScriptFixture::new();
        let out = f.run(
            r#"
            local p=proc.spawn{argv={'printf','p'}}
            local q=proc.spawn{argv={'printf','q'}}
            assert(type(proc.select)=='function' and type(proc.all)=='function')
            assert(not pcall(function() proc.select{} end))
            assert(not pcall(function() proc.select{p,p} end))
            assert(not pcall(function() proc.all{[1]=p,[3]=q} end))
            assert(not pcall(function() proc.all{p,{}} end))
            assert(not pcall(function() proc.all{p,unexpected=q} end))
            local wait=p.wait
            assert(not pcall(function() wait({}) end), 'copied method accepts forged receiver')
            assert(p:wait().ok)
            assert(#proc.all{q}==1, 'a valid one-handle list remains valid')
            verdict.ok('list-validation')
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
    fn composition_chain_passes_binary_stdin_in_memory_and_retains_first_failure() {
        let f = ScriptFixture::new();
        let emit = f.write("emit.sh", "#!/bin/sh\nprintf 'A\\000\\377\\r\\n'\n");
        let fail = f.write("fail-seven.sh", "#!/bin/sh\ncat\nexit 7\n");
        let out = f.run(
            &format!(
                r#"
            local c=proc.chain{{
              {{argv={{'sh','{emit}'}}}},
              {{argv={{'cat'}}}},
              {{argv={{'sh','{fail}'}}}},
              {{argv={{'cat'}}}},
            }}
            assert(#c.stages==4 and not c.ok and c.first_failure==3)
            assert(c.stages[1].ok and c.stages[2].stdout=='A'..string.char(0,255)..'\r\n')
            assert(c.stages[3].status=='exited' and c.stages[3].code==7)
            assert(c.stages[4].stdout=='A'..string.char(0,255)..'\r\n')
            verdict.ok('chain-bytes')
        "#
            ),
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn composition_chain_validates_all_stages_before_earlier_execution() {
        let f = ScriptFixture::new();
        let marker = f.write("marker.sh", "#!/bin/sh\nprintf ran > earlier-ran\n");
        let out = f.run(
            &format!(
                r#"
            assert(type(proc.chain)=='function')
            assert(not pcall(function() proc.chain{{
              {{argv={{'sh','{marker}'}}}},
              {{argv={{'cat'}},stdin='illegal-later-stdin'}},
            }} end))
            assert(not fs.exists('earlier-ran'), 'invalid later stage started an earlier stage')
            assert(not pcall(function() proc.chain{{}} end))
            verdict.ok('chain-prevalidate')
        "#
            ),
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn composition_chain_retains_spawn_timeout_and_clipped_failures_before_success() {
        let f = ScriptFixture::new();
        let out = f.run(
            r#"
            local c=proc.chain{
              {argv={'tillandsias-composition-missing-program'}},
              {argv={'sleep','1'},timeout_ms=20},
              {argv={'head','-c','100','/dev/zero'},capture_bytes=10},
              {argv={'printf','last'}},
            }
            assert(#c.stages==4 and not c.ok and c.first_failure==1)
            assert(c.stages[1].status=='spawn_failed')
            assert(c.stages[2].status=='timed_out')
            assert(c.stages[3].status=='exited' and c.stages[3].code==0
              and c.stages[3].truncated and not c.stages[3].ok
              and #c.stages[3].stdout==10 and c.stages[3].dropped==90)
            assert(c.stages[4].ok and c.stages[4].stdout=='last')
            verdict.ok('chain-retained-failures')
        "#,
            "4s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn composition_chain_retains_policy_and_signal_failures_before_later_success() {
        let f = ScriptFixture::new();
        let signal = f.write("signal.sh", "#!/bin/sh\nkill -TERM $$\n");
        let out = f.run(
            &format!(
                r#"
            local policy=proc.chain{{
              {{argv={{'bash','-c','printf forbidden > shell-policy-marker'}}}},
              {{argv={{'printf','after-policy'}}}},
            }}
            assert(not policy.ok and policy.first_failure==1 and policy.stages[1].status=='policy_denied')
            assert(policy.stages[2].ok and policy.stages[2].stdout=='after-policy')
            local signal=proc.chain{{
              {{argv={{'sh','{signal}'}}}},
              {{argv={{'printf','after-signal'}}}},
            }}
            assert(not signal.ok and signal.first_failure==1 and signal.stages[1].status=='signaled')
            assert(signal.stages[2].ok and signal.stages[2].stdout=='after-signal')
            verdict.ok('chain-policy-signal')
        "#
            ),
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(!f.dir.path().join("shell-policy-marker").exists());
    }

    #[test]
    #[cfg(unix)]
    fn composition_chain_validates_before_consent_and_consumes_one_token_per_execution() {
        use std::os::unix::fs::PermissionsExt;
        use tillandsias_plan::command_policy as cp;

        let f = ScriptFixture::new();
        // This is an inert workspace-local executable merely named rm; it is
        // never the host rm and only records a successful authorized launch.
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
        let invalid = f.run(
            &format!(
                r#"
            assert(type(proc.chain)=='function')
            assert(not pcall(function() proc.chain{{
              {{argv={{{args}}}}},
              {{argv={{'printf','later'}},timeout='invalid'}},
            }} end))
            verdict.ok('chain-invalid-before-consent')
        "#
            ),
            "3s",
        );
        assert!(
            invalid.status.success(),
            "{}",
            String::from_utf8_lossy(&invalid.stderr)
        );
        assert_eq!(std::fs::read(&token).unwrap(), original);
        assert!(!f.dir.path().join("marker").exists());

        let valid = f.run(
            &format!(
                r#"
            local c=proc.chain{{
              {{argv={{{args}}}}},
              {{argv={{{args}}}}},
            }}
            assert(#c.stages==2 and not c.ok and c.first_failure==2)
            assert(c.stages[1].status=='exited' and c.stages[1].code==0 and c.stages[1].ok)
            assert(c.stages[2].status=='policy_consent_required'
              and c.stages[2].code==nil and c.stages[2].run_id==nil)
            verdict.ok('chain-consent-once')
        "#
            ),
            "3s",
        );
        assert!(
            valid.status.success(),
            "{}",
            String::from_utf8_lossy(&valid.stderr)
        );
        assert!(!token.exists());
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

    #[test]
    fn composition_chain_snapshots_all_stage_fields_before_callback_mutation() {
        let f = ScriptFixture::new();
        let old_dir = f.dir.path().join("old-cwd");
        let new_dir = f.dir.path().join("new-cwd");
        std::fs::create_dir(&old_dir).unwrap();
        std::fs::create_dir(&new_dir).unwrap();
        let first = f.write(
            "chain-first.sh",
            "#!/bin/sh\nprintf started > first-started\nprintf 'first-started\\n'\nwhile [ ! -f release-first ]; do sleep .01; done\ncat\n",
        );
        let mutator = f.write(
            "chain-mutator.sh",
            "#!/bin/sh\nwhile [ ! -f first-started ]; do sleep .01; done\nprintf 'MUTATE\\n'\n",
        );
        let second = f.write(
            "chain-second.sh",
            "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$1\" \"$EXTRA\" \"$PWD\"\ncat\n",
        );
        let old_dir = lua_path(&old_dir);
        let new_dir = lua_path(&new_dir);
        let out = f.run(
            &format!(
                r#"
            local x=proc.spawn{{argv={{'sh','{mutator}'}}}}
            local first={{argv={{'sh','{first}'}},stdin='old-stdin'}}
            local second={{argv={{'sh','{second}','old-argv'}},env={{EXTRA='old-env'}},cwd='{old_dir}'}}
            x:on_line('stdout',function(s)
              assert(s=='MUTATE')
              first.stdin='new-stdin'
              second.argv={{'sh','{second}','new-argv'}}
              second.env={{EXTRA='new-env'}}
              second.cwd='{new_dir}'
              second.stdin='new-illegal-after-validation'
              fs.write('release-first','yes')
            end)
            local c=proc.chain{{first,second}}
            assert(x:wait().ok and #c.stages==2 and c.ok)
            assert(c.stages[1].stdout=='first-started\nold-stdin')
            assert(c.stages[2].stdout=='old-argv|old-env|{old_dir}\nfirst-started\nold-stdin')
            verdict.ok('chain-snapshot')
        "#
            ),
            "4s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn composition_chain_validation_getter_reentrant_door_closes_scope_before_launch() {
        let f = ScriptFixture::new();
        let first = f.write(
            "getter-first.sh",
            "#!/bin/sh\nprintf first > first-launch\n",
        );
        let nested = f.write(
            "getter-nested.sh",
            "#!/bin/sh\nprintf nested > nested-launch\n",
        );
        let escape = f.write(
            "getter-escape.sh",
            "#!/bin/sh\nprintf escape > escape-launch\n",
        );
        let out = f.run(
            &format!(
                r#"
            assert(type(proc.chain)=='function')
            local second=setmetatable({{argv={{'printf','second'}}}},{{__index=function(_,key)
              if key=='cwd' then
                fs.write('getter-entered','yes')
                local ok,err=pcall(function() proc.run{{argv={{'sh','{nested}'}}}} end)
                assert(not ok and tostring(err):match('proc.*reentrancy') and not tostring(err):match('yield'))
                fs.write('getter-refused','yes')
              end
              return nil
            end}})
            local ok,err=pcall(function() proc.chain{{
              {{argv={{'sh','{first}'}}}}, second
            }} end)
            assert(not ok and fs.exists('getter-entered') and fs.exists('getter-refused'))
            local escaped=pcall(function() proc.spawn{{argv={{'sh','{escape}'}}}} end)
            assert(not escaped, 'caught getter reentrancy reopened the scope')
            error(tostring(err))
        "#
            ),
            "3s",
        );
        assert!(f.dir.path().join("getter-entered").exists());
        assert!(f.dir.path().join("getter-refused").exists());
        for marker in ["first-launch", "nested-launch", "escape-launch"] {
            assert!(!f.dir.path().join(marker).exists(), "{marker} launched");
        }
        assert_eq!(out.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("reentrancy") || stderr.contains("scope"),
            "{stderr}"
        );
        assert!(!stderr.contains("yield"), "{stderr}");
    }

    #[test]
    fn composition_exit_callback_reentrant_select_all_and_chain_close_scope() {
        for (name, attempt) in [
            ("select", "proc.select{p,timeout_ms=1}"),
            ("all", "proc.all{p}"),
            ("chain", "proc.chain{{argv={'sh','NESTED'}}}"),
        ] {
            let f = ScriptFixture::new();
            let producer = f.write(
                "callback-reentrant.sh",
                "#!/bin/sh\nprintf 'READY\\n'\nwhile [ ! -f callback-go ]; do sleep .01; done\n",
            );
            let nested = f.write("nested.sh", "#!/bin/sh\nprintf nested > nested-launch\n");
            let escape = f.write("escape.sh", "#!/bin/sh\nprintf escape > escape-launch\n");
            let attempt = attempt.replace("NESTED", &nested);
            let out = f.run(
                &format!(
                    r#"
                local p=proc.spawn{{argv={{'sh','{producer}'}}}}
                p:on_line('stdout',function(s) assert(s=='READY'); fs.write('callback-go','yes') end)
                p:on_exit(function()
                  fs.write('callback-entry','{name}')
                  local ok,err=pcall(function() {attempt} end)
                  assert(not ok and tostring(err):match('proc%-callback%-reentrancy')
                    and not tostring(err):match('yield'))
                  fs.write('callback-refused','{name}')
                end)
                pcall(function() p:wait() end)
                local escaped=pcall(function() proc.spawn{{argv={{'sh','{escape}'}}}} end)
                assert(not escaped, 'caught callback reentrancy reopened the scope')
                error('callback scope closed after {name}')
            "#
                ),
                "3s",
            );
            assert_eq!(
                std::fs::read_to_string(f.dir.path().join("callback-entry")).unwrap(),
                name
            );
            assert_eq!(
                std::fs::read_to_string(f.dir.path().join("callback-refused")).unwrap(),
                name
            );
            assert!(
                !f.dir.path().join("nested-launch").exists(),
                "{name} nested launch"
            );
            assert!(
                !f.dir.path().join("escape-launch").exists(),
                "{name} escaped launch"
            );
            assert_eq!(
                out.status.code(),
                Some(1),
                "{name}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            let stderr = String::from_utf8_lossy(&out.stderr);
            assert!(
                stderr.contains("scope") || stderr.contains("reentrancy"),
                "{name}: {stderr}"
            );
            assert!(!stderr.contains("yield"), "{name}: {stderr}");
        }
    }

    #[test]
    fn composition_on_exit_follows_lines_precedes_wait_and_result_tables_are_fresh() {
        let f = ScriptFixture::new();
        let producer = f.write(
            "exit-barrier.sh",
            "#!/bin/sh\nprintf 'line\\n'\nprintf 'err\\n' >&2\nwhile [ ! -f exit-ack ]; do sleep .01; done\n",
        );
        let out = f.run(
            &format!(
                r#"
            local p=proc.spawn{{argv={{'sh','{producer}'}}}}
            local order={{}}
            local lines=0
            local exit_count=0
            local exit_wall_ms
            p:on_line('stdout',function(s)
              assert(s=='line'); lines=lines+1; table.insert(order,'stdout'); fs.write('exit-ack','yes')
            end)
            p:on_line('stderr',function(s) assert(s=='err'); lines=lines+1; table.insert(order,'stderr') end)
            p:on_exit(function() error('replaced exit slot ran') end)
            p:on_exit(function(r)
              exit_count=exit_count+1; exit_wall_ms=r.wall_ms
              assert(lines==2, 'exit preceded final line delivery')
              table.insert(order,'exit'); assert(r.stdout=='line\n' and r.stderr=='err\n')
              local keep_status,keep_code,keep_id=r.status,r.code,r.run_id
              r.stdout='corrupt'; r.status='corrupt'; r.code=99; r.run_id='corrupt'
              fs.write('exit-observed',keep_status..':'..tostring(keep_code)..':'..keep_id)
            end)
            local r=p:wait(); table.insert(order,'wait')
            assert(lines==2 and order[#order-1]=='exit' and order[#order]=='wait')
            assert(r.status=='exited' and r.code==0 and r.stdout=='line\n' and r.stderr=='err\n')
            local repeated=p:wait(); local all=proc.all{{p}}
            assert(repeated.run_id==r.run_id and proc.select{{p}}==p and all[1].run_id==r.run_id)
            assert(exit_count==1, 'repeated observations dispatched exit more than once')
            assert(exit_wall_ms==r.wall_ms and repeated.wall_ms==r.wall_ms and all[1].wall_ms==r.wall_ms,
              'terminal duration changed on later observation')
            assert(fs.exists('exit-observed'))
            assert(not pcall(function() p:on_exit(function() end) end))
            verdict.ok('exit-barrier')
        "#
            ),
            "3s",
        );
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    #[test]
    fn composition_exit_callback_error_closes_scope_even_when_caught() {
        let f = ScriptFixture::new();
        let escape = f.write("escape.sh", "#!/bin/sh\nprintf bad > escaped\n");
        let producer = f.write(
            "exit-error.sh",
            "#!/bin/sh\nprintf 'READY\\n'\nwhile [ ! -f callback-go ]; do sleep .01; done\n",
        );
        let out = f.run(
            &format!(
                r#"
            local p=proc.spawn{{argv={{'sh','{producer}'}}}}
            assert(type(p.on_exit)=='function')
            p:on_line('stdout',function(s) assert(s=='READY'); fs.write('callback-go','yes') end)
            p:on_exit(function() fs.write('exit-callback-ran','yes'); error('exit-callback-broke') end)
            assert(not pcall(function() p:wait() end))
            proc.spawn{{argv={{'sh','{escape}'}}}}
            verdict.ok('wrong')
        "#
            ),
            "3s",
        );
        assert!(f.dir.path().join("exit-callback-ran").exists());
        assert!(!f.dir.path().join("escaped").exists());
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("exit-callback-broke") || stderr.contains("scope"),
            "{stderr}"
        );
        assert_eq!(
            out.status.code(),
            Some(1),
            "{}",
            String::from_utf8_lossy(&out.stderr)
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
