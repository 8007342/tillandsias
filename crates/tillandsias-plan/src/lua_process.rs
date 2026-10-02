// @trace order:1534-puyz, spec:command-runtime
//! Lua-side dispatch only. Executor supervisors never access this VM.
use super::{PreparedProc, prepare_proc, proc_result_to_lua, shell_result_to_lua};
use mlua::prelude::*;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tillandsias_exec::managed::{Event, Process, Scope};

struct Handler {
    stdout: Option<LuaFunction>,
    stderr: Option<LuaFunction>,
    delivered: Arc<AtomicBool>,
}
struct Dispatch {
    events: tokio::sync::mpsc::Receiver<Event>,
    handlers: BTreeMap<u64, Handler>,
}

#[derive(Clone)]
pub(crate) struct Host {
    pub scope: Scope,
    dispatch: Arc<Mutex<Dispatch>>,
    callback: Arc<AtomicBool>,
}

fn error(message: impl ToString) -> LuaError {
    LuaError::RuntimeError(message.to_string())
}

impl Host {
    pub fn new(deadline: Option<Instant>) -> Self {
        let (scope, events) = Scope::new(deadline);
        Self {
            scope,
            dispatch: Arc::new(Mutex::new(Dispatch {
                events,
                handlers: BTreeMap::new(),
            })),
            callback: Arc::new(AtomicBool::new(false)),
        }
    }
    fn open(&self) -> LuaResult<()> {
        if self.scope.stopped() {
            Err(error("script-scope-closed"))
        } else {
            Ok(())
        }
    }
    fn outside_callback(&self) -> LuaResult<()> {
        if self.callback.load(Ordering::Acquire) {
            self.scope.close();
            Err(error(
                "proc-callback-reentrancy: callbacks may not spawn, run, wait or kill",
            ))
        } else {
            self.open()
        }
    }
    // A single VM thread calls this only while the main coroutine is suspended.
    // Take the function out of the mutex BEFORE calling Lua: on_line may register
    // another callback, but recursive waiting is explicitly refused.
    fn pump(&self, lua: &Lua) -> LuaResult<()> {
        for _ in 0..128 {
            self.open()?;
            let event = self.dispatch.lock().unwrap().events.try_recv();
            let event = match event {
                Ok(event) => event,
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => return Ok(()),
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                    return Err(error("script-stream-closed"));
                }
            };
            match event {
                Event::Line { process, fd, bytes } => {
                    let callback = self
                        .dispatch
                        .lock()
                        .unwrap()
                        .handlers
                        .get(&process)
                        .and_then(|h| {
                            if fd == "stdout" {
                                h.stdout.clone()
                            } else {
                                h.stderr.clone()
                            }
                        });
                    if let Some(callback) = callback {
                        self.callback.store(true, Ordering::Release);
                        let result = lua
                            .create_string(&bytes)
                            .and_then(|line| callback.call::<()>(line));
                        self.callback.store(false, Ordering::Release);
                        if let Err(e) = result {
                            // Even pcall around wait cannot resurrect this scope.
                            self.scope.close();
                            return Err(e);
                        }
                        self.open()?;
                    }
                }
                Event::Finished(id) => {
                    if let Some(h) = self.dispatch.lock().unwrap().handlers.remove(&id) {
                        h.delivered.store(true, Ordering::Release);
                    }
                }
            }
        }
        Ok(())
    }
    async fn wait(
        &self,
        lua: Lua,
        process: Process,
        delivered: Arc<AtomicBool>,
        argv: Vec<String>,
        started: Instant,
    ) -> LuaResult<LuaTable> {
        self.outside_callback()?;
        loop {
            self.pump(&lua)?;
            if delivered.load(Ordering::Acquire)
                && let Some(result) = process.result()
            {
                let out = match result {
                    Ok(out) => out,
                    Err(e) => {
                        self.scope.close();
                        return Err(error(e));
                    }
                };
                return proc_result_to_lua(
                    &lua,
                    &argv,
                    Ok(out),
                    started.elapsed().as_millis() as u64,
                );
            }
            // Yield fairly across every managed process, not only the waited id.
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
    }
    fn handle(
        &self,
        lua: &Lua,
        process: Process,
        argv: Vec<String>,
        started: Instant,
    ) -> LuaResult<LuaTable> {
        let delivered = Arc::new(AtomicBool::new(false));
        self.dispatch.lock().unwrap().handlers.insert(
            process.id,
            Handler {
                stdout: None,
                stderr: None,
                delivered: delivered.clone(),
            },
        );
        let table = lua.create_table()?;
        let host = self.clone();
        let id = process.id;
        table.set(
            "on_line",
            lua.create_function(
                move |_, (this, fd, callback): (LuaTable, String, LuaFunction)| {
                    if fd != "stdout" && fd != "stderr" {
                        return Err(error("proc.on_line: fd must be stdout or stderr"));
                    }
                    host.open()?;
                    let mut dispatch = host.dispatch.lock().unwrap();
                    let handler = dispatch
                        .handlers
                        .get_mut(&id)
                        .ok_or_else(|| error("proc.on_line: stream already finished"))?;
                    if fd == "stdout" {
                        handler.stdout = Some(callback);
                    } else {
                        handler.stderr = Some(callback);
                    }
                    Ok(this)
                },
            )?,
        )?;
        for (name, kill) in [("wait", false), ("kill", true)] {
            let host = self.clone();
            let process = process.clone();
            let delivered = delivered.clone();
            let argv = argv.clone();
            let method = lua.create_async_function(move |lua, _: LuaTable| {
                let host = host.clone();
                let process = process.clone();
                let delivered = delivered.clone();
                let argv = argv.clone();
                async move {
                    host.outside_callback()?;
                    if kill {
                        process.kill();
                    }
                    host.wait(lua, process, delivered, argv, started).await
                }
            })?;
            // Check synchronously, BEFORE an async method can yield from a
            // callback. This makes reentrancy a named refusal, not a VM accident.
            let host = self.clone();
            let check = lua.create_function(move |_, ()| host.outside_callback())?;
            let wrapper: LuaFunction = lua.load("return function(check, method) return function(self) check(); return method(self) end end")
                .eval::<LuaFunction>()?.call((check, method))?;
            table.set(name, wrapper)?;
        }
        Ok(table)
    }
    pub fn release_callbacks(&self) {
        // Break host/VM registry cycles when a script drops its handles.
        self.dispatch.lock().unwrap().handlers.clear();
    }

    pub fn install(&self, lua: &Lua) -> LuaResult<()> {
        // Cacheable environments have neither table; never widen them here.
        let Ok(proc_table) = lua.globals().get::<LuaTable>("proc") else {
            return Ok(());
        };
        let host = self.clone();
        proc_table.set(
            "spawn",
            lua.create_async_function(move |lua, spec: LuaTable| {
                let host = host.clone();
                async move {
                    host.outside_callback()?;
                    match prepare_proc(&lua, spec, "proc.spawn", true)? {
                        PreparedProc::Refused(t) => Ok(t),
                        PreparedProc::Command { argv, command } => {
                            let started = Instant::now();
                            match host.scope.spawn(command, true) {
                                Ok(process) => host.handle(&lua, process, argv, started),
                                Err(e) => proc_result_to_lua(
                                    &lua,
                                    &argv,
                                    Err(e),
                                    started.elapsed().as_millis() as u64,
                                ),
                            }
                        }
                    }
                }
            })?,
        )?;
        // Keep synchronous proc.run semantics. Its blocking bridge supervises
        // off-thread, so the outer deadline does not depend on Lua yielding.
        let host = self.clone();
        proc_table.set(
            "run",
            lua.create_function(move |lua, spec: LuaTable| {
                host.outside_callback()?;
                match prepare_proc(lua, spec, "proc.run", false)? {
                    PreparedProc::Refused(t) => Ok(t),
                    PreparedProc::Command { argv, command } => {
                        let started = Instant::now();
                        let result = host.scope.run(command);
                        proc_result_to_lua(lua, &argv, result, started.elapsed().as_millis() as u64)
                    }
                }
            })?,
        )?;
        let host = self.clone();
        let shell = lua.create_function(move |lua, spec: LuaTable| {
            host.outside_callback()?;
            let argv: Vec<String> = spec
                .clone()
                .sequence_values::<String>()
                .collect::<LuaResult<_>>()?;
            if argv.is_empty() {
                return Err(error("expert.shell: refused — empty argv"));
            }
            let timeout: Option<u64> = spec.get("timeout_ms")?;
            if let Some(d) = super::policy_gate(&argv, None, "sh.run") {
                return Err(error(format!(
                    "{}\n  why: {}\n  remedy: {}",
                    d.token,
                    d.why.unwrap_or_default(),
                    d.remedy.unwrap_or_default()
                )));
            }
            // These legacy doors historically inherit the environment. Preserve
            // that behavior; ownership adds a group, not a new policy regime.
            let mut command = tillandsias_exec::Command::new(argv).group(true);
            if let Some(ms) = timeout {
                command = command.timeout(std::time::Duration::from_millis(ms));
            }
            let out = host.scope.run(command).map_err(error)?;
            shell_result_to_lua(lua, out)
        })?;
        lua.globals()
            .get::<LuaTable>("sh")?
            .set("run", shell.clone())?;
        lua.globals()
            .get::<LuaTable>("expert")?
            .set("shell", shell)?;
        Ok(())
    }
}
