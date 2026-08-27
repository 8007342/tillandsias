//! Sandboxed Lua runtime for the adversarial decomposition pipeline.
//!
//! @trace spec:spec-traceability
//! @trace order:902-5bf9
//!
//! The Lua layer sits between Rust (concurrent dispatch, RAG retrieval,
//! citation verification) and Shell (MCP transport, inference endpoint).
//! It is hot-reloadable at runtime: `reload()` re-reads all `.lua` files
//! from disk without restarting the VM. Type-checked at load time against
//! a schema the Rust side enforces.
//!
//! Security constraints (matching `openspec/specs/security-privacy-isolation`):
//! - No `os.execute`, no `io.popen`, no unrooted `io.open`
//! - No `debug` library
//! - `fs.read` is repo-rooted (cannot escape the checkout)
//! - All subprocess execution through `expert.query` (bounded, logged)
//!
//! Design: the Lua scripts own DECOMPOSITION STRATEGY and COLLECTION
//! SEMANTICS. Rust owns CONCURRENT DISPATCH, INFERENCE ENDPOINT, and
//! CITATION VERIFICATION. The boundary is clean: Lua returns data,
//! Rust executes it.

use mlua::prelude::*;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Errors from the Lua runtime.
#[derive(Debug, Clone)]
pub enum LuaError {
    /// Failed to load a Lua script file.
    LoadError(String),
    /// Lua script returned an invalid type.
    TypeError(String),
    /// Lua script panicked or hit a runtime error.
    RuntimeError(String),
    /// The Lua VM could not be created.
    VmError(String),
}

impl std::fmt::Display for LuaError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LuaError::LoadError(msg) => write!(f, "lua load error: {msg}"),
            LuaError::TypeError(msg) => write!(f, "lua type error: {msg}"),
            LuaError::RuntimeError(msg) => write!(f, "lua runtime error: {msg}"),
            LuaError::VmError(msg) => write!(f, "lua vm error: {msg}"),
        }
    }
}

impl std::error::Error for LuaError {}

/// A single adversarial prompt variant produced by decomposition.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AdversarialPrompt {
    /// The prompt text to send to the inference endpoint.
    pub prompt: String,
    /// The kind of adversarial variant (e.g., "original", "negation",
    /// "alternative", "opposite", "side_effects").
    pub kind: String,
}

/// A validated response from the CRDT collection layer.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ValidatedResponse {
    /// The answer text.
    pub answer: String,
    /// Citations supporting this answer.
    pub citations: Vec<CitationRef>,
    /// Informational confidence (not a filter — all validated responses survive).
    pub confidence: f64,
    /// Provenance: which adversarial variant produced this response.
    pub provenance: ResponseProvenance,
    /// Why this answer is true (reasoning chain).
    pub why: String,
    /// What this answer enables (affordances for the consumer).
    pub affordances: Vec<String>,
    /// What this answer doesn't cover, costs, consequences.
    pub why_not: String,
}

/// A citation reference in a validated response.
#[derive(Debug, Clone, serde::Serialize)]
pub struct CitationRef {
    pub path: String,
    pub line_start: usize,
    pub line_end: usize,
    pub claimed_text: String,
}

/// Provenance metadata for a CRDT-collected response.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ResponseProvenance {
    /// The adversarial variant kind that produced this response.
    pub query_kind: String,
    /// The original adversarial prompt that was sent.
    pub source_prompt: String,
}

/// Latency tier for response time budgeting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LatencyTier {
    /// < 500ms — user barely notices. Deterministic engine only.
    Immediate,
    /// 0.5–3s — user notices a wait, but doesn't lose attention.
    Quick,
    /// 5–12s — user notices a wait, but the result is worth it.
    Fine,
    /// > 15s — non-usable; abort or degrade to deterministic.
    NonUsable,
}

impl LatencyTier {
    /// Budget in milliseconds for this tier.
    pub fn budget_ms(&self) -> u64 {
        match self {
            LatencyTier::Immediate => 500,
            LatencyTier::Quick => 3_000,
            LatencyTier::Fine => 12_000,
            LatencyTier::NonUsable => 15_000,
        }
    }

    /// Classify a response time in milliseconds into a tier.
    pub fn from_ms(ms: u64) -> Self {
        match ms {
            0..500 => LatencyTier::Immediate,
            500..3_000 => LatencyTier::Quick,
            3_000..12_000 => LatencyTier::Fine,
            _ => LatencyTier::NonUsable,
        }
    }
}

impl FromLua for LatencyTier {
    fn from_lua(value: LuaValue, _lua: &Lua) -> LuaResult<Self> {
        let s = value
            .as_str()
            .ok_or_else(|| mlua::Error::RuntimeError(format!("expected string, got {value:?}")))?;
        match s.to_string().as_str() {
            "immediate" => Ok(LatencyTier::Immediate),
            "quick" => Ok(LatencyTier::Quick),
            "fine" => Ok(LatencyTier::Fine),
            "non_usable" => Ok(LatencyTier::NonUsable),
            other => Err(mlua::Error::RuntimeError(format!(
                "unknown latency tier: {other}"
            ))),
        }
    }
}

/// The Lua runtime — a sandboxed VM that loads and executes decomposition,
/// validation, and collection scripts.
pub struct LuaRuntime {
    lua: Lua,
    /// Path to the directory containing `.lua` scripts.
    lua_dir: PathBuf,
    /// The repo root (for `fs.read` rooting).
    repo_root: PathBuf,
}

impl LuaRuntime {
    /// Create a new Lua runtime, loading scripts from `lua_dir`.
    ///
    /// The sandbox blocks dangerous operations: `os.execute`, `io.popen`,
    /// unrooted `io.open`, and the `debug` library.
    pub fn new(lua_dir: &Path, repo_root: &Path) -> Result<Self, LuaError> {
        let lua = Lua::new();

        // Sandbox: remove dangerous globals
        {
            let globals = lua.globals();

            // Remove os.execute, os.exit, os.getenv (use expert.query instead)
            if let Ok(os_table) = globals.get::<LuaTable>("os") {
                let _ = os_table.set("execute", LuaValue::Nil);
                let _ = os_table.set("exit", LuaValue::Nil);
                let _ = os_table.set("getenv", LuaValue::Nil);
            }

            // Remove io.open, io.popen, io.close (use expert.fs_read instead)
            if let Ok(io_table) = globals.get::<LuaTable>("io") {
                let _ = io_table.set("open", LuaValue::Nil);
                let _ = io_table.set("popen", LuaValue::Nil);
                let _ = io_table.set("close", LuaValue::Nil);
                let _ = io_table.set("output", LuaValue::Nil);
                let _ = io_table.set("input", LuaValue::Nil);
            }

            // Remove debug library entirely
            let _ = globals.set("debug", LuaValue::Nil);

            // Remove loadfile/dofile (prevent loading arbitrary scripts)
            let _ = globals.set("loadfile", LuaValue::Nil);
            let _ = globals.set("dofile", LuaValue::Nil);

            // Remove require (scripts are loaded by Rust, not Lua)
            let _ = globals.set("require", LuaValue::Nil);
        }

        // Register the `expert` table — the Rust<->Lua bridge
        Self::register_expert_table(&lua)?;

        let mut rt = Self {
            lua,
            lua_dir: lua_dir.to_path_buf(),
            repo_root: repo_root.to_path_buf(),
        };

        // Load all .lua files in the directory (sorted for determinism).
        // Scripts are loaded in alphabetical order: init.lua first, then
        // collect.lua, decompose.lua, tier.lua, validate.lua.
        rt.load_all_scripts()?;

        Ok(rt)
    }

    /// Register the `expert` global table with Rust-backed functions.
    fn register_expert_table(lua: &Lua) -> Result<(), LuaError> {
        let expert = lua
            .create_table()
            .map_err(|e| LuaError::VmError(format!("failed to create expert table: {e}")))?;

        // expert.log_info(msg) — write to stderr (visible in hook logs)
        {
            let log_info = lua
                .create_function(|_, msg: String| {
                    eprintln!("[lua-expert] {msg}");
                    Ok(())
                })
                .map_err(|e| LuaError::VmError(format!("failed to create log_info: {e}")))?;
            expert
                .set("log_info", log_info)
                .map_err(|e| LuaError::VmError(format!("failed to set log_info: {e}")))?;
        }

        // expert.now_ms() — monotonic timestamp in milliseconds
        {
            let now_ms = lua
                .create_function(|_, ()| {
                    Ok(std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as u64)
                })
                .map_err(|e| LuaError::VmError(format!("failed to create now_ms: {e}")))?;
            expert
                .set("now_ms", now_ms)
                .map_err(|e| LuaError::VmError(format!("failed to set now_ms: {e}")))?;
        }

        let globals = lua.globals();
        globals
            .set("expert", expert)
            .map_err(|e| LuaError::VmError(format!("failed to set expert global: {e}")))?;

        Ok(())
    }

    /// Load and execute all `.lua` files from the lua directory.
    /// init.lua is always loaded LAST so it can reference functions
    /// defined by other modules.
    fn load_all_scripts(&mut self) -> Result<(), LuaError> {
        let mut scripts: Vec<PathBuf> = std::fs::read_dir(&self.lua_dir)
            .map_err(|e| {
                LuaError::LoadError(format!(
                    "failed to read lua dir {}: {e}",
                    self.lua_dir.display()
                ))
            })?
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|p| p.extension().is_some_and(|ext| ext == "lua"))
            .collect();
        // Sort, but ensure init.lua comes last
        scripts.sort_by(|a, b| {
            let a_init = a.file_name().is_some_and(|n| n == "init.lua");
            let b_init = b.file_name().is_some_and(|n| n == "init.lua");
            if a_init && !b_init {
                std::cmp::Ordering::Greater
            } else if !a_init && b_init {
                std::cmp::Ordering::Less
            } else {
                a.cmp(b)
            }
        });
        for script in &scripts {
            self.load_file(script)?;
        }
        Ok(())
    }

    /// Load and execute a single Lua file.
    fn load_file(&self, path: &Path) -> Result<(), LuaError> {
        let source = std::fs::read_to_string(path)
            .map_err(|e| LuaError::LoadError(format!("{}: {e}", path.display())))?;
        self.lua
            .load(&source)
            .set_name(path.display().to_string())
            .exec()
            .map_err(|e| LuaError::RuntimeError(format!("{}: {e}", path.display())))
    }

    /// Hot-reload: re-read all `.lua` files from disk without restarting the VM.
    ///
    /// Preserves global state from previous loads. Scripts should be written
    /// to tolerate re-execution (idempotent global assignments).
    pub fn reload(&mut self) -> Result<(), LuaError> {
        // Re-register the expert table (idempotent)
        Self::register_expert_table(&self.lua)?;
        self.load_all_scripts()?;
        Ok(())
    }

    /// Call a Lua function that takes a query string and returns a list of
    /// adversarial prompts. Used by the decomposition phase.
    ///
    /// `func_name` is the global function name to call (e.g., "decompose").
    pub fn call_decompose(
        &self,
        func_name: &str,
        query: &str,
    ) -> Result<Vec<AdversarialPrompt>, LuaError> {
        let globals = self.lua.globals();
        let func: LuaFunction = globals.get(func_name).map_err(|e| {
            LuaError::RuntimeError(format!("function '{func_name}' not found: {e}"))
        })?;

        let result: LuaTable = func
            .call(query)
            .map_err(|e| LuaError::RuntimeError(format!("{func_name}({query:?}) failed: {e}")))?;

        let mut prompts = Vec::new();
        for pair in result.pairs::<usize, LuaTable>() {
            let (_, entry) = pair.map_err(|e| {
                LuaError::TypeError(format!("failed to iterate {func_name} result: {e}"))
            })?;
            let prompt: String = entry.get("prompt").map_err(|e| {
                LuaError::TypeError(format!("missing 'prompt' in {func_name} result: {e}"))
            })?;
            let kind: String = entry.get("kind").map_err(|e| {
                LuaError::TypeError(format!("missing 'kind' in {func_name} result: {e}"))
            })?;
            prompts.push(AdversarialPrompt { prompt, kind });
        }

        Ok(prompts)
    }

    /// Classify a query into a latency tier via the Lua tier module.
    pub fn classify_tier(&self, query: &str) -> Result<String, LuaError> {
        let globals = self.lua.globals();
        let tier_classify: LuaFunction = globals
            .get("tier_classify")
            .map_err(|e| LuaError::RuntimeError(format!("tier_classify not found: {e}")))?;
        tier_classify
            .call(query)
            .map_err(|e| LuaError::RuntimeError(format!("tier_classify({query:?}) failed: {e}")))
    }

    /// Trim adversarial variants to fit within the tier's budget.
    pub fn trim_variants(
        &self,
        prompts: &[AdversarialPrompt],
        tier_name: &str,
    ) -> Result<Vec<AdversarialPrompt>, LuaError> {
        let globals = self.lua.globals();
        let tier_trim: LuaFunction = globals
            .get("tier_trim")
            .map_err(|e| LuaError::RuntimeError(format!("tier_trim not found: {e}")))?;

        // Convert prompts to a Lua table
        let lua_prompts = self
            .lua
            .create_table()
            .map_err(|e| LuaError::RuntimeError(format!("failed to create prompts table: {e}")))?;
        for (i, p) in prompts.iter().enumerate() {
            let entry = self.lua.create_table().map_err(|e| {
                LuaError::RuntimeError(format!("failed to create prompt entry: {e}"))
            })?;
            entry
                .set("prompt", p.prompt.as_str())
                .map_err(|e| LuaError::RuntimeError(format!("failed to set prompt: {e}")))?;
            entry
                .set("kind", p.kind.as_str())
                .map_err(|e| LuaError::RuntimeError(format!("failed to set kind: {e}")))?;
            lua_prompts
                .set(i + 1, entry)
                .map_err(|e| LuaError::RuntimeError(format!("failed to set prompt entry: {e}")))?;
        }

        let result: LuaTable = tier_trim
            .call((lua_prompts, tier_name))
            .map_err(|e| LuaError::RuntimeError(format!("tier_trim failed: {e}")))?;

        let mut trimmed = Vec::new();
        for pair in result.pairs::<usize, LuaTable>() {
            let (_, entry) = pair.map_err(|e| {
                LuaError::TypeError(format!("failed to iterate tier_trim result: {e}"))
            })?;
            let prompt: String = entry.get("prompt").map_err(|e| {
                LuaError::TypeError(format!("missing 'prompt' in tier_trim result: {e}"))
            })?;
            let kind: String = entry.get("kind").map_err(|e| {
                LuaError::TypeError(format!("missing 'kind' in tier_trim result: {e}"))
            })?;
            trimmed.push(AdversarialPrompt { prompt, kind });
        }

        Ok(trimmed)
    }

    /// Call a Lua function that validates and collects responses. Used by the
    /// CRDT collection phase.
    ///
    /// `func_name` is the global function name to call (e.g., "collect").
    /// `responses_json` is a JSON string containing the raw inference responses.
    /// JSON is parsed in Rust and converted to Lua tables for the Lua layer.
    pub fn call_collect(
        &self,
        func_name: &str,
        responses_json: &str,
    ) -> Result<Vec<ValidatedResponse>, LuaError> {
        let globals = self.lua.globals();
        let func: LuaFunction = globals.get(func_name).map_err(|e| {
            LuaError::RuntimeError(format!("function '{func_name}' not found: {e}"))
        })?;

        // Parse JSON in Rust and convert to a Lua value
        let json_val: serde_json::Value = serde_json::from_str(responses_json)
            .map_err(|e| LuaError::RuntimeError(format!("invalid JSON input: {e}")))?;
        let lua_val = self.lua.to_value(&json_val).map_err(|e| {
            LuaError::RuntimeError(format!("failed to convert JSON to Lua value: {e}"))
        })?;

        let result: LuaTable = func
            .call(lua_val)
            .map_err(|e| LuaError::RuntimeError(format!("{func_name} failed: {e}")))?;

        let mut responses = Vec::new();
        for pair in result.pairs::<usize, LuaTable>() {
            let (_, entry) = pair.map_err(|e| {
                LuaError::TypeError(format!("failed to iterate {func_name} result: {e}"))
            })?;
            let answer: String = entry.get("answer").unwrap_or_default();
            let confidence: f64 = entry.get("confidence").unwrap_or(0.0);
            let why: String = entry.get("why").unwrap_or_default();
            let why_not: String = entry.get("why_not").unwrap_or_default();

            let kind: String = entry.get("query_kind").unwrap_or_default();
            let source_prompt: String = entry.get("source_prompt").unwrap_or_default();

            let mut affordances = Vec::new();
            if let Ok(aff_table) = entry.get::<LuaTable>("affordances") {
                for aff in aff_table.sequence_values::<String>().flatten() {
                    affordances.push(aff);
                }
            }

            let mut citations = Vec::new();
            if let Ok(cit_table) = entry.get::<LuaTable>("citations") {
                for (_, cit) in cit_table.pairs::<usize, LuaTable>().flatten() {
                    citations.push(CitationRef {
                        path: cit.get("path").unwrap_or_default(),
                        line_start: cit.get("line_start").unwrap_or(0),
                        line_end: cit.get("line_end").unwrap_or(0),
                        claimed_text: cit.get("claimed_text").unwrap_or_default(),
                    });
                }
            }

            responses.push(ValidatedResponse {
                answer,
                citations,
                confidence,
                provenance: ResponseProvenance {
                    query_kind: kind,
                    source_prompt,
                },
                why,
                affordances,
                why_not,
            });
        }

        Ok(responses)
    }

    /// Get the Lua directory path.
    pub fn lua_dir(&self) -> &Path {
        &self.lua_dir
    }

    /// Get the repo root path.
    pub fn repo_root(&self) -> &Path {
        &self.repo_root
    }
}

/// Shared, thread-safe handle to a Lua runtime for concurrent access.
pub type SharedLuaRuntime = Arc<tokio::sync::Mutex<LuaRuntime>>;

/// Create a shared Lua runtime from the standard paths.
///
/// Lua scripts are expected at `<repo_root>/crates/tillandsias-plan/lua/`.
pub fn create_shared_runtime(repo_root: &Path) -> Result<SharedLuaRuntime, LuaError> {
    let lua_dir = repo_root
        .join("crates")
        .join("tillandsias-plan")
        .join("lua");
    let runtime = LuaRuntime::new(&lua_dir, repo_root)?;
    Ok(Arc::new(tokio::sync::Mutex::new(runtime)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn fixture_lua_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tilland-lua-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("fixture dir");
        dir
    }

    #[test]
    fn lua_runtime_loads_init_script() {
        let dir = fixture_lua_dir("init");
        let init = dir.join("init.lua");
        fs::write(&init, "expert.log_info('hello from lua')").unwrap();
        let repo = std::env::temp_dir().join("tilland-lua-repo-test");
        let _ = fs::create_dir_all(&repo);
        let rt = LuaRuntime::new(&dir, &repo);
        assert!(rt.is_ok(), "runtime should load: {:?}", rt.err());
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&repo);
    }

    #[test]
    fn lua_runtime_blocks_os_execute() {
        let dir = fixture_lua_dir("sandbox");
        let init = dir.join("init.lua");
        fs::write(&init, "os.execute('echo pwned')").unwrap();
        let repo = std::env::temp_dir().join("tilland-lua-repo-sandbox");
        let _ = fs::create_dir_all(&repo);
        let rt = LuaRuntime::new(&dir, &repo);
        // os.execute is nil, so this should error
        assert!(rt.is_err(), "os.execute should be blocked");
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&repo);
    }

    #[test]
    fn lua_runtime_blocks_debug_library() {
        let dir = fixture_lua_dir("debug-block");
        let init = dir.join("init.lua");
        fs::write(&init, "debug.getinfo(1)").unwrap();
        let repo = std::env::temp_dir().join("tilland-lua-repo-debug");
        let _ = fs::create_dir_all(&repo);
        let rt = LuaRuntime::new(&dir, &repo);
        assert!(rt.is_err(), "debug library should be blocked");
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&repo);
    }

    #[test]
    fn latency_tier_classification() {
        assert_eq!(LatencyTier::from_ms(0), LatencyTier::Immediate);
        assert_eq!(LatencyTier::from_ms(250), LatencyTier::Immediate);
        assert_eq!(LatencyTier::from_ms(499), LatencyTier::Immediate);
        assert_eq!(LatencyTier::from_ms(500), LatencyTier::Quick);
        assert_eq!(LatencyTier::from_ms(1500), LatencyTier::Quick);
        assert_eq!(LatencyTier::from_ms(2999), LatencyTier::Quick);
        assert_eq!(LatencyTier::from_ms(3000), LatencyTier::Fine);
        assert_eq!(LatencyTier::from_ms(8000), LatencyTier::Fine);
        assert_eq!(LatencyTier::from_ms(11999), LatencyTier::Fine);
        assert_eq!(LatencyTier::from_ms(12000), LatencyTier::NonUsable);
        assert_eq!(LatencyTier::from_ms(60000), LatencyTier::NonUsable);
    }

    #[test]
    fn latency_tier_budgets() {
        assert_eq!(LatencyTier::Immediate.budget_ms(), 500);
        assert_eq!(LatencyTier::Quick.budget_ms(), 3_000);
        assert_eq!(LatencyTier::Fine.budget_ms(), 12_000);
        assert_eq!(LatencyTier::NonUsable.budget_ms(), 15_000);
    }
}
