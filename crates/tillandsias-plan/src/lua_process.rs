// @trace order:1534-puyz, order:1538-pwdr, spec:command-runtime
//! Lua-side dispatch only. Executor supervisors never access this VM.
use super::{PreparedProc, authorize_proc, proc_result_to_lua, shell_result_to_lua, validate_proc};
use mlua::prelude::*;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tillandsias_exec::managed::{Event, Process, Scope};

struct Completed {
    output: tillandsias_exec::Output,
    wall_ms: u64,
    order: u64,
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    struct Fixture {
        host: Host,
        lua: Lua,
        events: Option<tokio::sync::mpsc::Sender<Event>>,
    }
    impl Fixture {
        fn new() -> Self {
            Self::with_events(false)
        }
        fn live() -> Self {
            Self::with_events(true)
        }
        fn with_events(live: bool) -> Self {
            let lua = Lua::new();
            for name in ["proc", "sh", "expert"] {
                lua.globals()
                    .set(name, lua.create_table().unwrap())
                    .unwrap();
            }
            let host = Host::new(Some(Instant::now() + Duration::from_secs(5)));
            host.install(&lua).unwrap();
            let (events, receiver) = tokio::sync::mpsc::channel(32);
            if !live {
                host.dispatch.lock().unwrap().events = receiver;
            }
            Self {
                host,
                lua,
                events: (!live).then_some(events),
            }
        }
        fn handle(&self, name: &str) -> (LuaTable, Arc<HandleState>, tillandsias_exec::Output) {
            new_handle(&self.host, &self.lua, name)
        }
        fn send(&self, event: Event) {
            self.events.as_ref().unwrap().try_send(event).unwrap();
        }
        fn eval(&self, body: &str) {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(self.lua.load(body).exec_async()).unwrap();
            runtime.shutdown_background();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.host.scope.cleanup().unwrap();
            self.host.release_callbacks();
        }
    }
    fn new_handle(
        host: &Host,
        lua: &Lua,
        name: &str,
    ) -> (LuaTable, Arc<HandleState>, tillandsias_exec::Output) {
        // A real, already-reaped direct child supplies an authentic Output and
        // Process. Only publication timing/events are synthetic in these tests.
        let process = host
            .scope
            .spawn(
                tillandsias_exec::Command::new(["/bin/true"]).group(true),
                false,
            )
            .unwrap();
        let end = Instant::now() + Duration::from_secs(2);
        let output = loop {
            if let Some(result) = process.result() {
                break result.unwrap();
            }
            assert!(Instant::now() < end, "fixture child did not finish");
            std::thread::yield_now();
        };
        let handle = host
            .handle(lua, process, vec!["/bin/true".into()], Instant::now())
            .unwrap();
        let state = host.identity(&handle).unwrap();
        *state.publication_override.lock().unwrap() = Some(None);
        lua.globals().set(name, handle.clone()).unwrap();
        (handle, state, output)
    }
    fn publish(state: &HandleState, output: tillandsias_exec::Output) {
        *state.publication_override.lock().unwrap() = Some(Some(Ok(output)));
    }

    #[test]
    fn pending_receipt_order_survives_publication_race_empty_queue_and_repeated_selection() {
        let f = Fixture::new();
        let (_, a, mut output_a) = f.handle("a");
        let (_, b, output_b) = f.handle("b");
        output_a.stdout = b"original\0\xff".to_vec();
        publish(&b, output_b);
        f.lua
            .load(
                r#"
            trace = {}
            a:on_line('stdout', function(s) table.insert(trace, 'line-a:'..s) end)
            b:on_line('stderr', function(s) table.insert(trace, 'line-b:'..s) end)
            a:on_exit(function() error('replaced slot must not run') end)
            assert(a:on_exit(function(r)
                table.insert(trace, 'exit-a')
                r.code = 99; r.stdout = 'mutated'; r.argv[1] = 'mutated'
            end) == a)
            b:on_exit(function() table.insert(trace, 'exit-b') end)
        "#,
            )
            .exec()
            .unwrap();
        f.send(Event::Line {
            process: a.process.id,
            fd: "stdout",
            bytes: b"one".to_vec(),
        });
        f.send(Event::Finished(a.process.id));
        f.send(Event::Line {
            process: b.process.id,
            fd: "stderr",
            bytes: b"two".to_vec(),
        });
        f.send(Event::Finished(b.process.id));
        f.host.pump(&f.lua).unwrap();
        assert!(!a.delivered.load(Ordering::Acquire));
        assert!(!b.delivered.load(Ordering::Acquire));
        let wall_ms = f
            .host
            .dispatch
            .lock()
            .unwrap()
            .pending
            .front()
            .unwrap()
            .wall_ms;
        f.lua
            .load("assert(table.concat(trace, ',') == 'line-a:one,line-b:two')")
            .exec()
            .unwrap();
        publish(&a, output_a);
        // No further event wakes the dispatcher: it MUST retry pending results.
        f.host.pump(&f.lua).unwrap();
        assert!(a.delivered.load(Ordering::Acquire));
        assert!(b.delivered.load(Ordering::Acquire));
        assert_eq!(
            a.completed.lock().unwrap().as_ref().unwrap().wall_ms,
            wall_ms
        );
        assert!(f.host.dispatch.lock().unwrap().handlers.is_empty());
        f.eval(
            r#"
            assert(table.concat(trace, ',') == 'line-a:one,line-b:two,exit-a,exit-b')
            assert(proc.select{b,a} == a)
            assert(proc.select{a,b,timeout_ms=0} == a)
            assert(not pcall(function() a:on_exit(function() end) end))
            local r = a:wait()
            assert(r.code == 0 and r.stdout == 'original\0\255' and r.argv[1] == '/bin/true')
            local wall = r.wall_ms
            r.code = 77; r.stdout = 'again'
            local all = proc.all{b,a}
            assert(all[1].ok and all[2].code == 0 and all[2].wall_ms == wall)
            assert(all[2].stdout == 'original\0\255' and #trace == 4)
        "#,
        );
    }

    #[test]
    fn terminal_executor_error_without_finished_closes_scope_instead_of_hanging() {
        let f = Fixture::new();
        let (_, a, _) = f.handle("a");
        let (_, b, _) = f.handle("b");
        f.send(Event::Finished(a.process.id));
        f.host.pump(&f.lua).unwrap();
        assert_eq!(f.host.dispatch.lock().unwrap().pending.len(), 1);
        *b.publication_override.lock().unwrap() =
            Some(Some(Err("synthetic-direct-child-reap-failed".into())));
        // No Finished for b, and a still has no result. Scope-wide error polling
        // must not depend on either the pending head or the selected argument.
        let e = f.host.pump(&f.lua).unwrap_err();
        assert!(e.to_string().contains("synthetic-direct-child-reap-failed"));
        assert!(f.host.scope.stopped());
        assert!(!a.delivered.load(Ordering::Acquire));
        assert!(!b.delivered.load(Ordering::Acquire));
        assert!(a.completed.lock().unwrap().is_none());
        assert!(b.completed.lock().unwrap().is_none());
    }

    #[test]
    fn copied_methods_foreign_handles_and_malformed_lists_are_rejected_before_waiting() {
        let f = Fixture::new();
        let (_, a, _) = f.handle("a");
        let (_, b, _) = f.handle("b");
        f.eval(
            r#"
            local bad = {
                {a,a}, {[2]=a}, {[1]=a,[3]=b}, {[0]=a}, {a, extra=true},
                {{wait=a.wait, kill=a.kill, on_line=a.on_line, on_exit=a.on_exit}},
            }
            for _, list in ipairs(bad) do
                assert(not pcall(proc.all, list)); assert(not pcall(proc.select, list))
            end
            assert(not pcall(proc.select, {}))
            assert(not pcall(proc.all, {a,timeout_ms=1}))
            assert(not pcall(proc.select, {a,timeout_ms=-1}))
            assert(#proc.all{} == 0)
            assert(not pcall(a.wait, b)); assert(not pcall(a.kill, b))
            assert(not pcall(a.on_exit, b, function() end))
            assert(not pcall(a.on_line, b, 'stdout', function() end))
            local got, why = proc.select{b,a,timeout_ms=1}
            assert(got == nil and why == 'timed_out')
        "#,
        );
        assert!(!f.host.scope.stopped());
        assert!(!a.delivered.load(Ordering::Acquire));
        assert!(!b.delivered.load(Ordering::Acquire));
        let foreign = Host::new(None);
        foreign.install(&f.lua).unwrap();
        let (_, c, _) = new_handle(&foreign, &f.lua, "c");
        f.eval(
            r#"
            assert(not pcall(proc.all, {a,c}))
            assert(not pcall(proc.select, {a,c}))
            assert(not pcall(c.wait, a)); assert(not pcall(a.wait, c))
        "#,
        );
        assert!(!c.delivered.load(Ordering::Acquire));
        foreign.scope.cleanup().unwrap();
        foreign.release_callbacks();
    }

    #[test]
    fn caught_exit_callback_reentrancy_latches_all_async_doors_closed_before_yield() {
        let f = Fixture::new();
        let (_, a, output) = f.handle("a");
        publish(&a, output);
        f.lua
            .load(
                r#"
            a:on_exit(function()
                assert(not pcall(function() a:on_exit(function() end) end))
                local ok, e = pcall(proc.select, {a})
                assert(not ok and tostring(e):find('proc%-callback%-reentrancy'))
            end)
        "#,
            )
            .exec()
            .unwrap();
        f.send(Event::Finished(a.process.id));
        assert!(f.host.pump(&f.lua).is_err());
        assert!(f.host.scope.stopped());
        assert!(!a.delivered.load(Ordering::Acquire));
        // Synchronous pcall/exec, not exec_async: these must refuse before any
        // mlua async yield, even though the callback caught its nested error.
        f.lua
            .load(
                r#"
            local spec = {argv={'/bin/true'}}
            for _, call in ipairs({
                function() proc.spawn(spec) end,
                function() proc.select{a} end,
                function() proc.all{a} end,
                function() proc.chain{spec} end,
                function() a:wait() end,
                function() a:kill() end,
                function() proc.run(spec) end,
            }) do
                local ok, e = pcall(call)
                assert(not ok and tostring(e):find('script%-scope%-closed'))
            end
        "#,
            )
            .exec()
            .unwrap();
    }

    #[test]
    fn caught_chain_getter_reentrancy_cannot_reopen_validation_scope() {
        let f = Fixture::new();
        f.eval(
            r#"
            local entered = false
            local stage = setmetatable({argv={'/bin/true'}}, {__index=function(_, key)
                if key == 'cwd' then
                    entered = true
                    local ok, e = pcall(proc.spawn, {argv={'/bin/true'}})
                    assert(not ok and tostring(e):find('proc%-callback%-reentrancy'))
                end
                return nil
            end})
            assert(not pcall(proc.chain, {stage, {argv={'/bin/true'}}}))
            assert(entered)
            local ok, e = pcall(proc.spawn, {argv={'/bin/true'}})
            assert(not ok and tostring(e):find('script%-scope%-closed'))
        "#,
        );
        assert!(f.host.scope.stopped());
        assert!(!f.host.validating.load(Ordering::Acquire));
        assert!(f.host.dispatch.lock().unwrap().handlers.is_empty());
    }

    #[test]
    fn weak_handle_identity_does_not_retain_completed_lua_tables() {
        let f = Fixture::new();
        let (table, state, output) = f.handle("a");
        publish(&state, output);
        f.send(Event::Finished(state.process.id));
        f.host.pump(&f.lua).unwrap();
        f.lua
            .load("weak = setmetatable({a}, {__mode='v'}); a=nil")
            .exec()
            .unwrap();
        drop(table);
        f.lua.gc_collect().unwrap();
        f.lua.gc_collect().unwrap();
        f.lua.load("assert(weak[1] == nil)").exec().unwrap();
        let identities = f.host.identities.lock().unwrap().clone().unwrap();
        assert_eq!(identities.pairs::<LuaValue, LuaValue>().count(), 0);
        assert!(f.host.dispatch.lock().unwrap().handlers.is_empty());
    }

    #[test]
    fn live_chain_snapshots_nested_fields_before_callbacks_and_passes_binary_stdin() {
        let f = Fixture::live();
        f.lua
            .globals()
            .set("cwd", std::env::current_dir().unwrap().to_str().unwrap())
            .unwrap();
        f.eval(
            r#"
            local cwd_reads, mutations = 0, 0
            local bytes = 'first\0\255\nsecond'
            local second = setmetatable({argv={'/bin/cat'}, env={COMPOSITION_PIN='original'}}, {
                __index=function(_, key)
                    if key == 'cwd' then cwd_reads=cwd_reads+1; return cwd end
                    return nil
                end
            })
            local p = proc.spawn{argv={'/usr/bin/printf','READY\n'}}
            p:on_line('stdout', function(s)
                assert(s == 'READY')
                mutations=mutations+1
                second.argv[1]='/missing/changed-after-yield'
                second.env.COMPOSITION_PIN={}
                second.cwd='relative'; second.stdin='poison'; second.timeout_ms=-1
            end)
            local result = proc.chain{{argv={'/bin/cat'}, stdin=bytes}, second}
            assert(mutations == 1 and cwd_reads == 1)
            assert(result.ok and result.first_failure == nil and #result.stages == 2)
            assert(result.stages[1].stdout == bytes and result.stages[2].stdout == bytes)
            assert(result.stages[2].argv[1] == '/bin/cat')
            assert(proc.all{p}[1].ok)
        "#,
        );
        assert!(f.host.dispatch.lock().unwrap().handlers.is_empty());
    }

    #[test]
    fn live_chain_retains_nonzero_spawn_policy_timeout_and_truncation_before_later_success() {
        let f = Fixture::live();
        f.eval(
            r#"
            local r = proc.chain{
                {argv={'/bin/false'}},
                {argv={'/bin/cat'}},
                {argv={'/missing/composition-test-program'}},
                {argv={'/usr/bin/printf','%s','later'}},
                {argv={'/bin/cat'}},
            }
            assert(not r.ok and r.first_failure == 1 and #r.stages == 5)
            assert(r.stages[1].status == 'exited' and r.stages[1].code ~= 0)
            assert(r.stages[2].ok and r.stages[2].stdout == '')
            assert(r.stages[3].status == 'spawn_failed' and not r.stages[3].ok)
            assert(r.stages[4].ok and r.stages[5].ok and r.stages[5].stdout == 'later')
            local denied = proc.chain{{argv={'bash','-c','printf forbidden'}}, {argv={'/bin/true'}}}
            assert(not denied.ok and denied.first_failure == 1 and #denied.stages == 2)
            assert(denied.stages[1].status == 'policy_denied' and denied.stages[2].ok)
            local clipped = proc.chain{
                {argv={'/usr/bin/printf','%s','abcd'}, capture_bytes=2},
                {argv={'/bin/cat'}},
                {argv={'/bin/sleep','1'}, timeout_ms=20},
                {argv={'/bin/cat'}},
            }
            assert(not clipped.ok and clipped.first_failure == 1 and #clipped.stages == 4)
            assert(clipped.stages[1].truncated and not clipped.stages[1].ok)
            assert(clipped.stages[2].ok and clipped.stages[2].stdout == 'ab')
            assert(clipped.stages[3].status == 'timed_out' and clipped.stages[3].code == nil)
            assert(clipped.stages[4].ok and clipped.stages[4].stdout == '')
        "#,
        );
        assert!(f.host.dispatch.lock().unwrap().handlers.is_empty());
    }

    #[test]
    fn chain_validates_every_stage_and_later_stdin_before_any_execution() {
        let f = Fixture::live();
        f.eval(
            r#"
            assert(not pcall(proc.chain, {}))
            assert(not pcall(proc.chain, {[1]={argv={'/bin/true'}},[3]={argv={'/bin/true'}}}))
            for _, later in ipairs({
                {argv={}}, {argv={'/bin/true'},env={BAD={}}},
                {argv={'/bin/true'},cwd='relative'}, {argv={'/bin/true'},timeout_ms=-1},
                {argv={'/bin/true'},group=false}, {argv={'/bin/true'},capture_bytes=0},
                {argv={'/bin/true'},stdin=''}, {argv={'/bin/true'},unexpected=true},
                {argv={[1]='/bin/true',[3]='hole'}},
            }) do
                assert(not pcall(proc.chain, {{argv={'/bin/true'}},later}))
            end
        "#,
        );
        let mut dispatch = f.host.dispatch.lock().unwrap();
        assert_eq!(dispatch.next_completion, 0);
        assert!(dispatch.handlers.is_empty());
        assert!(dispatch.pending.is_empty());
        assert!(matches!(
            dispatch.events.try_recv(),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty)
        ));
        assert!(!f.host.scope.stopped());
    }
}
struct HandleState {
    process: Process,
    argv: Vec<String>,
    started: Instant,
    completed: Mutex<Option<Completed>>,
    publication: Mutex<Option<Result<tillandsias_exec::Output, String>>>,
    // A narrow deterministic dispatcher seam, absent from production builds.
    #[cfg(test)]
    publication_override: Mutex<Option<Option<Result<tillandsias_exec::Output, String>>>>,
    delivered: AtomicBool,
}
impl HandleState {
    fn poll_publication(&self) {
        if self.completed.lock().unwrap().is_some() {
            return;
        }
        let mut publication = self.publication.lock().unwrap();
        if publication.is_none() {
            #[cfg(test)]
            if let Some(result) = self.publication_override.lock().unwrap().as_ref() {
                *publication = result.clone();
                return;
            }
            *publication = self.process.result();
        }
    }
    fn result(&self, lua: &Lua) -> LuaResult<LuaTable> {
        let (output, wall_ms) = {
            let completed = self.completed.lock().unwrap();
            let completed = completed
                .as_ref()
                .ok_or_else(|| error("proc: not completed"))?;
            (completed.output.clone(), completed.wall_ms)
        };
        proc_result_to_lua(lua, &self.argv, Ok(output), wall_ms)
    }
}

// Only a private weak-key table contains these identities. Neither public
// fields, copied methods, metatables nor a reused table address can forge one.
struct HandleIdentity(Arc<HandleState>);
impl LuaUserData for HandleIdentity {}

struct Handler {
    stdout: Option<LuaFunction>,
    stderr: Option<LuaFunction>,
    exit: Option<LuaFunction>,
    exit_started: bool,
    state: Arc<HandleState>,
}
struct Pending {
    id: u64,
    order: u64,
    wall_ms: u64,
}
struct Dispatch {
    events: tokio::sync::mpsc::Receiver<Event>,
    handlers: BTreeMap<u64, Handler>,
    pending: VecDeque<Pending>,
    next_completion: u64,
}

#[derive(Clone)]
pub(crate) struct Host {
    pub scope: Scope,
    dispatch: Arc<Mutex<Dispatch>>,
    identities: Arc<Mutex<Option<LuaTable>>>,
    callback: Arc<AtomicBool>,
    validating: Arc<AtomicBool>,
}

fn error(message: impl ToString) -> LuaError {
    LuaError::RuntimeError(message.to_string())
}

// Also resets after failed Lua getters. Closing the scope, however, is a latch
// and cannot be undone by catching a nested process-door refusal with pcall.
struct ValidationGuard(Arc<AtomicBool>);
impl Drop for ValidationGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

// Raw list traversal rejects holes and unexpected keys without consulting an
// __index that could manufacture entries. Entries are snapshotted before waits.
fn sequence(table: &LuaTable, timeout: bool, caller: &str) -> LuaResult<Vec<LuaTable>> {
    let mut entries = BTreeMap::new();
    for pair in table.clone().pairs::<LuaValue, LuaValue>() {
        let (key, value) = pair?;
        match key {
            LuaValue::Integer(i) if i > 0 => {
                let LuaValue::Table(value) = value else {
                    return Err(error(format!("{caller}: entries must be tables")));
                };
                entries.insert(i, value);
            }
            LuaValue::String(s) if timeout && s.as_bytes().as_ref() == b"timeout_ms" => {}
            _ => return Err(error(format!("{caller}: unexpected list key"))),
        }
    }
    for (expected, actual) in (1..).zip(entries.keys()) {
        if expected != *actual {
            return Err(error(format!("{caller}: list must have no holes")));
        }
    }
    Ok(entries.into_values().collect())
}

impl Host {
    pub fn new(deadline: Option<Instant>) -> Self {
        let (scope, events) = Scope::new(deadline);
        Self {
            scope,
            dispatch: Arc::new(Mutex::new(Dispatch {
                events,
                handlers: BTreeMap::new(),
                pending: VecDeque::new(),
                next_completion: 0,
            })),
            identities: Arc::new(Mutex::new(None)),
            callback: Arc::new(AtomicBool::new(false)),
            validating: Arc::new(AtomicBool::new(false)),
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
        if self.callback.load(Ordering::Acquire) || self.validating.load(Ordering::Acquire) {
            self.scope.close();
            Err(error(
                "proc-callback-reentrancy: callbacks/chain getters may not spawn, run, wait, select, all, chain or kill",
            ))
        } else {
            self.open()?;
            self.check_failures()
        }
    }
    fn identity(&self, table: &LuaTable) -> LuaResult<Arc<HandleState>> {
        let identities = self.identities.lock().unwrap().clone();
        let identities = identities.ok_or_else(|| error("proc: foreign or forged handle"))?;
        let value: LuaValue = identities.raw_get(table.clone())?;
        let LuaValue::UserData(value) = value else {
            return Err(error("proc: foreign or forged handle"));
        };
        Ok(value.borrow::<HandleIdentity>()?.0.clone())
    }
    fn receiver(&self, table: &LuaTable, state: &Arc<HandleState>) -> LuaResult<()> {
        if !Arc::ptr_eq(&self.identity(table)?, state) {
            return Err(error("proc: foreign or forged method receiver"));
        }
        Ok(())
    }
    fn handles(
        &self,
        table: &LuaTable,
        timeout: bool,
        caller: &str,
    ) -> LuaResult<Vec<(LuaTable, Arc<HandleState>)>> {
        let mut seen = BTreeSet::new();
        sequence(table, timeout, caller)?
            .into_iter()
            .map(|table| {
                let state = self.identity(&table)?;
                if !seen.insert(state.process.id) {
                    return Err(error(format!("{caller}: duplicate handle")));
                }
                Ok((table, state))
            })
            .collect()
    }
    fn invoke(&self, callback: LuaFunction, argument: LuaValue) -> LuaResult<()> {
        self.callback.store(true, Ordering::Release);
        let result = callback.call::<()>(argument);
        self.callback.store(false, Ordering::Release);
        if let Err(e) = result {
            self.scope.close();
            return Err(e);
        }
        self.open()
    }
    // Supervisors may fail without emitting Finished. Check all owned producers,
    // not just the waited one; never turn an infrastructure error into success.
    fn check_failures(&self) -> LuaResult<()> {
        let failure = self
            .dispatch
            .lock()
            .unwrap()
            .handlers
            .values()
            .find_map(|h| {
                h.state.poll_publication();
                match h.state.publication.lock().unwrap().as_ref() {
                    Some(Err(e)) => Some(e.clone()),
                    _ => None,
                }
            });
        if let Some(e) = failure {
            self.scope.close();
            return Err(error(e));
        }
        Ok(())
    }
    // Keep receipt order even when the FIRST result has not yet been published.
    // This retry runs on an empty event queue too. No Lua executes under a lock.
    fn completions(&self, lua: &Lua) -> LuaResult<()> {
        loop {
            self.open()?;
            self.check_failures()?;
            let ready = {
                let mut dispatch = self.dispatch.lock().unwrap();
                let Some(pending) = dispatch.pending.front() else {
                    return Ok(());
                };
                let id = pending.id;
                let Some(handler) = dispatch.handlers.get(&id) else {
                    dispatch.pending.pop_front();
                    continue;
                };
                let Some(result) = handler.state.publication.lock().unwrap().take() else {
                    return Ok(());
                };
                let output = result.map_err(error)?;
                let pending = dispatch.pending.pop_front().unwrap();
                let handler = dispatch.handlers.get_mut(&id).unwrap();
                handler.exit_started = true;
                *handler.state.completed.lock().unwrap() = Some(Completed {
                    output,
                    order: pending.order,
                    wall_ms: pending.wall_ms,
                });
                (id, handler.state.clone(), handler.exit.take())
            };
            let (id, state, callback) = ready;
            if let Some(callback) = callback {
                self.invoke(callback, LuaValue::Table(state.result(lua)?))?;
            }
            self.open()?;
            state.delivered.store(true, Ordering::Release);
            // Release ALL function captures immediately, not only on teardown.
            let retired = self.dispatch.lock().unwrap().handlers.remove(&id);
            drop(retired);
        }
    }
    // A single VM thread calls this while the main coroutine is suspended.
    fn pump(&self, lua: &Lua) -> LuaResult<()> {
        let result = self.pump_inner(lua);
        if result.is_err() {
            self.scope.close();
        }
        result
    }
    fn pump_inner(&self, lua: &Lua) -> LuaResult<()> {
        self.check_failures()?;
        for _ in 0..128 {
            self.open()?;
            let event = self.dispatch.lock().unwrap().events.try_recv();
            let event = match event {
                Ok(event) => event,
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                    self.scope.close();
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
                        self.invoke(callback, LuaValue::String(lua.create_string(&bytes)?))?;
                    }
                }
                Event::Finished(id) => {
                    let mut dispatch = self.dispatch.lock().unwrap();
                    if let Some(handler) = dispatch.handlers.get(&id) {
                        let wall_ms = handler.state.started.elapsed().as_millis() as u64;
                        let order = dispatch.next_completion;
                        dispatch.next_completion += 1;
                        dispatch.pending.push_back(Pending { id, order, wall_ms });
                    }
                }
            }
            self.completions(lua)?;
        }
        self.completions(lua)
    }
    async fn wait(&self, lua: Lua, state: Arc<HandleState>) -> LuaResult<LuaTable> {
        self.outside_callback()?;
        loop {
            self.pump(&lua)?;
            if state.delivered.load(Ordering::Acquire) {
                self.open()?;
                return state.result(&lua);
            }
            // Yield fairly across every managed producer, not only the waited id.
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }
    fn track(&self, process: Process, argv: Vec<String>, started: Instant) -> Arc<HandleState> {
        let state = Arc::new(HandleState {
            process,
            argv,
            started,
            completed: Mutex::new(None),
            publication: Mutex::new(None),
            #[cfg(test)]
            publication_override: Mutex::new(None),
            delivered: AtomicBool::new(false),
        });
        self.dispatch.lock().unwrap().handlers.insert(
            state.process.id,
            Handler {
                stdout: None,
                stderr: None,
                exit: None,
                exit_started: false,
                state: state.clone(),
            },
        );
        state
    }
    // All async doors need a synchronous check BEFORE mlua yields. A caught
    // nested-door error must latch closed rather than becoming a VM yield error.
    fn async_door(&self, lua: &Lua, method: LuaFunction) -> LuaResult<LuaFunction> {
        let host = self.clone();
        let check = lua.create_function(move |_, ()| host.outside_callback())?;
        lua.load("return function(check, method) return function(...) check(); return method(...) end end")
            .eval::<LuaFunction>()?.call((check, method))
    }
    fn handle(
        &self,
        lua: &Lua,
        process: Process,
        argv: Vec<String>,
        started: Instant,
    ) -> LuaResult<LuaTable> {
        let state = self.track(process, argv, started);
        let table = lua.create_table()?;
        let identities = self
            .identities
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| error("proc: identities unavailable"))?;
        identities.raw_set(
            table.clone(),
            lua.create_userdata(HandleIdentity(state.clone()))?,
        )?;
        let host = self.clone();
        let receiver = state.clone();
        table.set(
            "on_line",
            lua.create_function(
                move |_, (this, fd, callback): (LuaTable, String, LuaFunction)| {
                    host.open()?;
                    host.receiver(&this, &receiver)?;
                    if fd != "stdout" && fd != "stderr" {
                        return Err(error("proc.on_line: fd must be stdout or stderr"));
                    }
                    let mut dispatch = host.dispatch.lock().unwrap();
                    let handler = dispatch
                        .handlers
                        .get_mut(&receiver.process.id)
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
        let host = self.clone();
        let receiver = state.clone();
        table.set(
            "on_exit",
            lua.create_function(move |_, (this, callback): (LuaTable, LuaFunction)| {
                host.open()?;
                host.receiver(&this, &receiver)?;
                let mut dispatch = host.dispatch.lock().unwrap();
                let handler = dispatch
                    .handlers
                    .get_mut(&receiver.process.id)
                    .filter(|h| !h.exit_started)
                    .ok_or_else(|| error("proc.on_exit: completion dispatch already started"))?;
                handler.exit = Some(callback);
                Ok(this)
            })?,
        )?;
        for (name, kill) in [("wait", false), ("kill", true)] {
            let host = self.clone();
            let state = state.clone();
            let method = lua.create_async_function(move |lua, this: LuaTable| {
                let host = host.clone();
                let state = state.clone();
                async move {
                    host.outside_callback()?;
                    host.receiver(&this, &state)?;
                    if kill {
                        state.process.kill();
                    }
                    host.wait(lua, state).await
                }
            })?;
            table.set(name, self.async_door(lua, method)?)?;
        }
        Ok(table)
    }
    pub fn release_callbacks(&self) {
        // Break host/VM registry cycles when a script drops its handles.
        let mut dispatch = self.dispatch.lock().unwrap();
        dispatch.handlers.clear();
        dispatch.pending.clear();
        *self.identities.lock().unwrap() = None;
    }

    pub fn install(&self, lua: &Lua) -> LuaResult<()> {
        // Cacheable environments have neither table; never widen them here.
        let Ok(proc_table) = lua.globals().get::<LuaTable>("proc") else {
            return Ok(());
        };
        let identities = lua.create_table()?;
        let metatable = lua.create_table()?;
        metatable.set("__mode", "k")?;
        identities.set_metatable(Some(metatable));
        *self.identities.lock().unwrap() = Some(identities);
        let host = self.clone();
        let spawn = lua.create_async_function(move |lua, spec: LuaTable| {
            let host = host.clone();
            async move {
                host.outside_callback()?;
                let snapshot = validate_proc(spec, "proc.spawn", true)?;
                host.outside_callback()?;
                match authorize_proc(&lua, snapshot, "proc.spawn")? {
                    PreparedProc::Refused(t) => Ok(t),
                    PreparedProc::Command { argv, command } => {
                        host.outside_callback()?;
                        let started = Instant::now();
                        match host.scope.spawn(command, true) {
                            Ok(process) => host.handle(&lua, process, argv, started),
                            Err(e) => {
                                let result = proc_result_to_lua(
                                    &lua,
                                    &argv,
                                    Err(e),
                                    started.elapsed().as_millis() as u64,
                                );
                                if result.is_err() {
                                    host.scope.close();
                                }
                                result
                            }
                        }
                    }
                }
            }
        })?;
        proc_table.set("spawn", self.async_door(lua, spawn)?)?;

        let host = self.clone();
        let select = lua.create_async_function(move |lua, spec: LuaTable| {
            let host = host.clone();
            async move {
                host.outside_callback()?;
                let handles = host.handles(&spec, true, "proc.select")?;
                if handles.is_empty() {
                    return Err(error("proc.select: empty list"));
                }
                let timeout_ms = match spec.raw_get::<LuaValue>("timeout_ms")? {
                    LuaValue::Nil => super::PROC_RUN_DEFAULT_TIMEOUT_MS,
                    LuaValue::Integer(i) if i >= 0 => i as u64,
                    _ => {
                        return Err(error(
                            "proc.select: timeout_ms must be a non-negative integer",
                        ));
                    }
                };
                let deadline = if timeout_ms == 0 {
                    None
                } else {
                    Some(
                        Instant::now()
                            .checked_add(Duration::from_millis(timeout_ms))
                            .ok_or_else(|| error("proc.select: timeout_ms out of range"))?,
                    )
                };
                loop {
                    host.pump(&lua)?;
                    host.open()?;
                    let first = handles
                        .iter()
                        .filter_map(|(table, state)| {
                            if !state.delivered.load(Ordering::Acquire) {
                                return None;
                            }
                            state
                                .completed
                                .lock()
                                .unwrap()
                                .as_ref()
                                .map(|c| (c.order, table))
                        })
                        .min_by_key(|(order, _)| *order);
                    if let Some((_, table)) = first {
                        return Ok((Some(table.clone()), None::<String>));
                    }
                    host.open()?; // The outer scope deadline always wins.
                    if deadline.is_some_and(|d| Instant::now() >= d) {
                        return Ok((None, Some("timed_out".to_owned())));
                    }
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
            }
        })?;
        proc_table.set("select", self.async_door(lua, select)?)?;

        let host = self.clone();
        let all = lua.create_async_function(move |lua, spec: LuaTable| {
            let host = host.clone();
            async move {
                host.outside_callback()?;
                let handles = host.handles(&spec, false, "proc.all")?;
                let results = lua.create_table()?;
                for (i, (_, state)) in handles.into_iter().enumerate() {
                    results.raw_set(i + 1, host.wait(lua.clone(), state).await?)?;
                }
                Ok(results)
            }
        })?;
        proc_table.set("all", self.async_door(lua, all)?)?;

        let host = self.clone();
        let chain = lua.create_async_function(move |lua, spec: LuaTable| {
            let host = host.clone();
            async move {
                host.outside_callback()?;
                let snapshots = {
                    host.validating.store(true, Ordering::Release);
                    let _guard = ValidationGuard(host.validating.clone());
                    let stages = sequence(&spec, false, "proc.chain")?;
                    if stages.is_empty() {
                        return Err(error("proc.chain: empty list"));
                    }
                    let mut snapshots = Vec::with_capacity(stages.len());
                    for (i, stage) in stages.into_iter().enumerate() {
                        let snapshot = validate_proc(stage, "proc.chain", true)?;
                        host.open()?;
                        if i > 0 && snapshot.explicit_stdin {
                            return Err(error(
                                "proc.chain: stdin is allowed only on the first stage",
                            ));
                        }
                        snapshots.push(snapshot);
                    }
                    snapshots
                };
                host.outside_callback()?;
                let stages = lua.create_table()?;
                let mut bytes = Vec::new();
                let mut first_failure = None;
                for (i, mut snapshot) in snapshots.into_iter().enumerate() {
                    host.outside_callback()?;
                    if i > 0 {
                        snapshot.command = snapshot.command.stdin_bytes(std::mem::take(&mut bytes));
                    }
                    let result = match authorize_proc(&lua, snapshot, "proc.chain")? {
                        PreparedProc::Refused(t) => t,
                        PreparedProc::Command { argv, command } => {
                            host.outside_callback()?;
                            let started = Instant::now();
                            match host.scope.spawn(command, true) {
                                Ok(process) => {
                                    let state = host.track(process, argv, started);
                                    host.wait(lua.clone(), state).await?
                                }
                                Err(e) => {
                                    let result = proc_result_to_lua(
                                        &lua,
                                        &argv,
                                        Err(e),
                                        started.elapsed().as_millis() as u64,
                                    );
                                    if result.is_err() {
                                        host.scope.close();
                                    }
                                    result?
                                }
                            }
                        }
                    };
                    host.open()?;
                    bytes = match result.raw_get::<LuaValue>("stdout")? {
                        LuaValue::String(s) => s.as_bytes().to_vec(),
                        _ => Vec::new(),
                    };
                    if !result.raw_get::<bool>("ok")? && first_failure.is_none() {
                        first_failure = Some(i + 1);
                    }
                    stages.raw_set(i + 1, result)?;
                }
                let result = lua.create_table()?;
                result.set("stages", stages)?;
                result.set("ok", first_failure.is_none())?;
                result.set("first_failure", first_failure)?;
                Ok(result)
            }
        })?;
        proc_table.set("chain", self.async_door(lua, chain)?)?;

        // Keep synchronous proc.run semantics, including legacy group=false.
        let host = self.clone();
        proc_table.set(
            "run",
            lua.create_function(move |lua, spec: LuaTable| {
                host.outside_callback()?;
                let snapshot = validate_proc(spec, "proc.run", false)?;
                host.outside_callback()?;
                match authorize_proc(lua, snapshot, "proc.run")? {
                    PreparedProc::Refused(t) => Ok(t),
                    PreparedProc::Command { argv, command } => {
                        host.outside_callback()?;
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
            host.outside_callback()?;
            if let Some(d) = super::policy_gate(&argv, None, "sh.run") {
                return Err(error(format!(
                    "{}\n  why: {}\n  remedy: {}",
                    d.token,
                    d.why.unwrap_or_default(),
                    d.remedy.unwrap_or_default()
                )));
            }
            host.outside_callback()?;
            // These legacy doors historically inherit the environment.
            let mut command = tillandsias_exec::Command::new(argv).group(true);
            if let Some(ms) = timeout {
                command = command.timeout(Duration::from_millis(ms));
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
