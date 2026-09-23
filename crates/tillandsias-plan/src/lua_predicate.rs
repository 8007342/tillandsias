// @trace order:1252-hsrz, spec:ci-release
//
// lua_predicate.rs — two predicate classes, and the cacheable one CANNOT REACH
// THE SHELL because the symbol is not in its environment.
//
// ── WHY THIS EXISTS AND WHAT IT IS NOT ──────────────────────────────────────
//
// OPERATOR DIRECTIVE 2026-09-18: an agent inside the forge has "no place to
// recompile their own binary when adding specs or work implementation". If
// predicates are Rust, a forge agent cannot validate a spec it just wrote. That
// makes the dynamic layer a RUNTIME REQUIREMENT, not a convenience.
//
// THIS DOES NOT REOPEN 920-pxg6. That audit pinned Lua to deterministic
// data-in/data-out work and deleted a PHANTOM sandbox claim from lua_runtime.rs.
// The division of labour survives intact: Lua DECLARES and DECIDES; Rust
// (1252-fg9e, tillandsias-exec) SPAWNS, owns fds, enforces timeouts and reaps.
// Nothing here moves fork/exec into Lua — `expert.shell` hands an argv vector to
// the Rust executor and gets a value back.
//
// ── CONTAINMENT: WHAT IT IS, AND WHAT IT IS NOT ─────────────────────────────
//
// CONTAINMENT IS: (1) a small audited verb set, enumerable at runtime via
// `expert.verbs()` and pinned by a test, and (2) the forge's existing container
// boundary.
//
// SELINUX IS NOT RELIED UPON AND MUST NOT BE CITED HERE. The SELinux policies in
// this project are PROSE — not enforced, not scoped, not required anywhere.
// Claiming SELinux containment would recreate precisely the phantom that
// 920-pxg6 deleted from lua_runtime.rs. If you are reading this looking for the
// guarantee, there isn't one beyond the two items above.
//
// PROVENANCE IS NOT SOLVED HERE, and this row does not close it. Today `lua/` is
// trusted code in the checkout. A forge agent authoring a predicate for
// uncommitted work moves the boundary from "code we shipped" to "code an agent
// just wrote". Bounding blast radius by the verb set is the mitigation this
// module delivers; SIGNING OR ATTESTING predicate provenance is a separate row
// and nothing here should be read as having addressed it.
//
// ── THE CACHE PURITY TRAP, WHICH IS WHY THERE ARE TWO CLASSES ───────────────
//
// The performance case wants cached predicate results. A cached result is sound
// only if the predicate is genuinely pure — and the moment a shell verb is in
// scope, predicates OBSERVE THE WORLD and are not. Cache those and you get stale
// verdicts indistinguishable from fresh ones: a green gate that ran nothing,
// which is the failure this whole programme exists to prevent.
//
// THE ENFORCEMENT IS STRUCTURAL, NOT DOCUMENTARY. A `Cacheable` predicate's
// environment simply DOES NOT CONTAIN `expert.shell`, so calling it raises
// "attempt to call a nil value" at call time. A documented rule drifts the first
// time someone is in a hurry; an absent symbol does not.
//
// `expert.now_ms` IS ALSO WITHHELD FROM THE CACHEABLE CLASS, and that is a
// finding rather than an inherited rule. The existing runtime exposes it to
// everything, and a clock read is an observation of the world exactly as a shell
// call is: a predicate that branches on `now_ms` and is then cached returns an
// answer computed at a time that has passed. The shell verb is the loud case;
// the clock is the quiet one, and a purity boundary that admits it is not a
// purity boundary.

use crate::lua_runtime::LuaError;
use mlua::prelude::*;
use std::collections::BTreeMap;
use std::path::Path;

/// Which capabilities a predicate is given, and therefore whether its result may
/// be cached. The class is what the environment is built FROM, not a label
/// attached to it afterwards.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PredicateClass {
    /// Pure: no shell, no clock. Results MAY be cached.
    Cacheable,
    /// Observes the world: shell and clock available. Results are NEVER cached.
    Observing,
}

impl PredicateClass {
    /// The audited verb set for this class, sorted. `expert.verbs()` returns
    /// exactly this, and a test pins it — so WIDENING THE CAPABILITY SET IS A
    /// VISIBLE DIFF rather than an accident.
    pub fn verbs(self) -> &'static [&'static str] {
        match self {
            // log_info is present in the pure class deliberately: it writes to
            // stderr and cannot affect the value the predicate returns, so it is
            // observationally pure with respect to the result being cached.
            PredicateClass::Cacheable => &["log_info", "verbs"],
            PredicateClass::Observing => &["log_info", "now_ms", "shell", "verbs"],
        }
    }

    /// Whether a result from this class may be served from cache.
    pub fn is_cacheable(self) -> bool {
        matches!(self, PredicateClass::Cacheable)
    }
}

/// What `expert.shell{...}` returns to Lua, mirroring tillandsias_exec::Output.
/// Three SEPARATE values plus the run identity — a predicate can tell stdout
/// from stderr, and a stale artifact from a fresh one.
fn shell_result_to_lua(lua: &Lua, out: tillandsias_exec::Output) -> LuaResult<LuaTable> {
    let t = lua.create_table()?;
    t.set("stdout", String::from_utf8_lossy(&out.stdout).to_string())?;
    t.set("stderr", String::from_utf8_lossy(&out.stderr).to_string())?;
    t.set("run_id", out.run.as_str().to_string())?;
    match out.completion {
        tillandsias_exec::Completion::Exited(code) => {
            t.set("status", "exited")?;
            t.set("code", code)?;
            t.set("ok", code == 0)?;
        }
        tillandsias_exec::Completion::Signaled(sig) => {
            t.set("status", "signaled")?;
            t.set("signal", sig)?;
            t.set("ok", false)?;
        }
        // A killed child produced NO exit status, so none is invented. A
        // predicate that wants to branch on "timed out" reads `status`, and
        // cannot mistake it for an ordinary non-zero exit.
        tillandsias_exec::Completion::TimedOut { after } => {
            t.set("status", "timed_out")?;
            t.set("after_ms", after.as_millis() as u64)?;
            t.set("ok", false)?;
        }
    }
    Ok(t)
}

/// The Lua globals a CACHEABLE predicate may reach, besides the `expert` table
/// (1367-upz6). Deterministic, side-effect-free library only: no `os`, no `io`,
/// no `print`, no `load`, no `collectgarbage`, and `math` without `random`.
/// Pinned from inside Lua by tests/lua_predicate_classes.rs.
pub const CACHEABLE_STDLIB_GLOBALS: &[&str] = &[
    "_G",
    "_VERSION",
    "assert",
    "error",
    "getmetatable",
    "ipairs",
    "math",
    "next",
    "pairs",
    "pcall",
    "rawequal",
    "rawget",
    "rawlen",
    "rawset",
    "select",
    "setmetatable",
    "string",
    "table",
    "tonumber",
    "tostring",
    "type",
    "utf8",
    "xpcall",
];

/// Build a Lua runtime whose `expert` table contains EXACTLY the verbs its class
/// is entitled to.
pub fn build_environment(class: PredicateClass) -> Result<Lua, LuaError> {
    let lua = Lua::new();

    // Same stdlib removals as lua_runtime::new. Repeated rather than shared
    // because this environment must not silently inherit a future widening of
    // that one — the two have different purposes and a common helper would make
    // a change there change the trust boundary here.
    {
        let globals = lua.globals();
        if let Ok(os_table) = globals.get::<LuaTable>("os") {
            let _ = os_table.set("execute", LuaValue::Nil);
            let _ = os_table.set("exit", LuaValue::Nil);
            let _ = os_table.set("getenv", LuaValue::Nil);
        }
        if let Ok(io_table) = globals.get::<LuaTable>("io") {
            let _ = io_table.set("open", LuaValue::Nil);
            let _ = io_table.set("popen", LuaValue::Nil);
            let _ = io_table.set("close", LuaValue::Nil);
            let _ = io_table.set("output", LuaValue::Nil);
            let _ = io_table.set("input", LuaValue::Nil);
        }
        let _ = globals.set("debug", LuaValue::Nil);
        let _ = globals.set("loadfile", LuaValue::Nil);
        let _ = globals.set("dofile", LuaValue::Nil);
        let _ = globals.set("require", LuaValue::Nil);
    }

    // ORDER 1367-upz6. The removals above are a DENY-list, and a deny-list
    // left os.time, os.clock, io.lines, os.remove and math.random reachable,
    // so a cacheable predicate could read the clock or the disk and have that
    // verdict replayed from cache. The cacheable class is therefore cut down
    // to an ALLOW-list: every global not named below is removed, and math
    // loses its non-deterministic half. The observing class keeps the wider
    // set; it is never cached and already holds the shell verb.
    if matches!(class, PredicateClass::Cacheable) {
        let globals = lua.globals();
        let mut drop: Vec<String> = Vec::new();
        for pair in globals.clone().pairs::<LuaValue, LuaValue>() {
            let (k, _) = pair.map_err(|e| LuaError::VmError(format!("globals: {e}")))?;
            if let LuaValue::String(name) = k {
                let name = name.to_string_lossy().to_string();
                if !CACHEABLE_STDLIB_GLOBALS.contains(&name.as_str()) {
                    drop.push(name);
                }
            }
        }
        for name in drop {
            globals
                .set(name.as_str(), LuaValue::Nil)
                .map_err(|e| LuaError::VmError(format!("remove {name}: {e}")))?;
        }
        if let Ok(math) = globals.get::<LuaTable>("math") {
            let _ = math.set("random", LuaValue::Nil);
            let _ = math.set("randomseed", LuaValue::Nil);
        }
    }

    let expert = lua
        .create_table()
        .map_err(|e| LuaError::VmError(format!("failed to create expert table: {e}")))?;

    // log_info — both classes.
    {
        let f = lua
            .create_function(|_, msg: String| {
                eprintln!("[lua-predicate] {msg}");
                Ok(())
            })
            .map_err(|e| LuaError::VmError(format!("log_info: {e}")))?;
        expert
            .set("log_info", f)
            .map_err(|e| LuaError::VmError(format!("log_info: {e}")))?;
    }

    // verbs() — both classes. Enumerable capability set.
    {
        let list: Vec<String> = class.verbs().iter().map(|s| s.to_string()).collect();
        let f = lua
            .create_function(move |lua, ()| {
                let t = lua.create_table()?;
                for (i, v) in list.iter().enumerate() {
                    t.set(i + 1, v.clone())?;
                }
                Ok(t)
            })
            .map_err(|e| LuaError::VmError(format!("verbs: {e}")))?;
        expert
            .set("verbs", f)
            .map_err(|e| LuaError::VmError(format!("verbs: {e}")))?;
    }

    if matches!(class, PredicateClass::Observing) {
        // now_ms — OBSERVING ONLY. See the header: a clock read is an
        // observation, and caching a predicate that branches on it returns an
        // answer computed at a time that has passed.
        {
            let f = lua
                .create_function(|_, ()| {
                    Ok(std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as u64)
                })
                .map_err(|e| LuaError::VmError(format!("now_ms: {e}")))?;
            expert
                .set("now_ms", f)
                .map_err(|e| LuaError::VmError(format!("now_ms: {e}")))?;
        }

        // shell{argv} — OBSERVING ONLY, and ARGV ONLY.
        //
        // The argument is a Lua SEQUENCE of strings, never a command line to be
        // parsed. There is deliberately no string form: that deletes quoting,
        // word-splitting, globbing and injection as a class, which is the single
        // constraint doing the most work in 1252-fg9e and the reason this verb
        // can be exposed to agent-authored code at all.
        //
        // Rust spawns, owns the fds, drains them concurrently, enforces the
        // timeout and reaps. Lua receives a VALUE.
        {
            let f = lua
                .create_function(|lua, spec: LuaTable| {
                    let mut argv: Vec<String> = Vec::new();
                    for pair in spec.clone().sequence_values::<String>() {
                        argv.push(pair?);
                    }
                    if argv.is_empty() {
                        return Err(mlua::Error::RuntimeError(
                            "expert.shell: refused — empty argv; pass a sequence like \
                             {\"git\",\"status\"}, never a command string"
                                .to_string(),
                        ));
                    }
                    let timeout_ms: Option<u64> = spec.get("timeout_ms").ok().flatten();

                    let mut cmd = tillandsias_exec::Command::new(argv);
                    if let Some(ms) = timeout_ms {
                        cmd = cmd.timeout(std::time::Duration::from_millis(ms));
                    }

                    // A dedicated current-thread runtime: this is called from
                    // synchronous Lua, and block_on inside an existing runtime
                    // would panic. Cheap relative to a process spawn.
                    let rt = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .map_err(|e| mlua::Error::RuntimeError(format!("runtime: {e}")))?;
                    let out = rt
                        .block_on(cmd.run())
                        .map_err(|e| mlua::Error::RuntimeError(format!("{e}")))?;
                    shell_result_to_lua(lua, out)
                })
                .map_err(|e| LuaError::VmError(format!("shell: {e}")))?;
            expert
                .set("shell", f)
                .map_err(|e| LuaError::VmError(format!("shell: {e}")))?;
        }
    }

    lua.globals()
        .set("expert", expert)
        .map_err(|e| LuaError::VmError(format!("failed to set expert global: {e}")))?;

    Ok(lua)
}

/// A registered predicate and the class it was registered in.
pub struct Predicate {
    pub name: String,
    pub class: PredicateClass,
    source: String,
}

/// Registry that owns each predicate's environment and the cache for the
/// cacheable class.
///
/// THE CACHE IS KEYED ON THE PREDICATE NAME AND ITS ARGUMENT, and it is
/// populated ONLY for `Cacheable`. There is no flag to override that: an
/// observing predicate has no cache entry to serve, so a stale verdict for one
/// is not something a caller can opt into by mistake.
#[derive(Default)]
pub struct PredicateRegistry {
    predicates: BTreeMap<String, Predicate>,
    cache: BTreeMap<(String, String), bool>,
    /// How many times a cached value was served, for tests that need to prove a
    /// second call did NOT re-execute.
    pub cache_hits: usize,
}

impl PredicateRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a predicate from Lua source. The source must define a global
    /// function named `name`.
    pub fn register(
        &mut self,
        name: &str,
        class: PredicateClass,
        source: &str,
    ) -> Result<(), LuaError> {
        // Compile it once here so a syntax error is a registration failure
        // rather than a surprise at the first call.
        let lua = build_environment(class)?;
        lua.load(source)
            .exec()
            .map_err(|e| LuaError::LoadError(format!("predicate {name}: {e}")))?;
        let _: LuaFunction = lua
            .globals()
            .get(name)
            .map_err(|e| LuaError::LoadError(format!("predicate {name} not defined: {e}")))?;
        self.predicates.insert(
            name.to_string(),
            Predicate {
                name: name.to_string(),
                class,
                source: source.to_string(),
            },
        );
        Ok(())
    }

    /// Load a predicate from a FILE, which is the forge-agent path: an agent
    /// writes a .lua file for an uncommitted spec and it executes with no
    /// recompilation of the host binary.
    pub fn register_file(
        &mut self,
        name: &str,
        class: PredicateClass,
        path: &Path,
    ) -> Result<(), LuaError> {
        let source = std::fs::read_to_string(path)
            .map_err(|e| LuaError::LoadError(format!("read {}: {e}", path.display())))?;
        self.register(name, class, &source)
    }

    pub fn names(&self) -> Vec<&str> {
        self.predicates.keys().map(|s| s.as_str()).collect()
    }

    pub fn class_of(&self, name: &str) -> Option<PredicateClass> {
        self.predicates.get(name).map(|p| p.class)
    }

    /// Evaluate a predicate against a string argument.
    ///
    /// A `Cacheable` result is memoised; an `Observing` result never is. The
    /// branch is on the CLASS, which is the thing the environment was built
    /// from, so the classification cannot drift away from what the predicate can
    /// actually reach.
    pub fn eval(&mut self, name: &str, arg: &str) -> Result<bool, LuaError> {
        let p = self
            .predicates
            .get(name)
            .ok_or_else(|| LuaError::LoadError(format!("no such predicate: {name}")))?;
        let class = p.class;
        let source = p.source.clone();
        let key = (name.to_string(), arg.to_string());

        if class.is_cacheable()
            && let Some(hit) = self.cache.get(&key)
        {
            self.cache_hits += 1;
            return Ok(*hit);
        }

        let lua = build_environment(class)?;
        lua.load(&source)
            .exec()
            .map_err(|e| LuaError::VmError(format!("predicate {name}: {e}")))?;
        let f: LuaFunction = lua
            .globals()
            .get(name)
            .map_err(|e| LuaError::VmError(format!("predicate {name}: {e}")))?;
        let verdict: bool = f
            .call(arg.to_string())
            .map_err(|e| LuaError::VmError(format!("predicate {name}: {e}")))?;

        if class.is_cacheable() {
            self.cache.insert(key, verdict);
        }
        Ok(verdict)
    }
}
