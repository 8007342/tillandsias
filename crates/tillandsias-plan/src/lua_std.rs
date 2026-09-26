// @trace order:1375-btuf, order:1367-q9yc, order:1367-upz6
//
// lua_std.rs — ONE registrar for the standard tables every Lua environment the
// plan binary hosts gets: the expert-serve runtime (lua_runtime.rs), the
// predicate bridge (lua_predicate.rs) and the `tillandsias-plan lua` CLI.
//
// Before this module the three environments shared no code, so a portability
// shim (json instead of jq, a hash instead of sha256sum/shasum) would have had
// to be written three times and would have drifted three ways. Here it is
// written once and registered by CLASS:
//
//   both classes   json.parse / json.encode / json.query, yaml.parse,
//                  hash.sha256, path.join / basename / dirname / normalize
//   Observing only time.now_ms, time.iso_utc
//
// EVERY PURE TABLE IS A FUNCTION OF ITS ARGUMENTS ALONE — no clock, no env, no
// disk. That is what lets them sit in the Cacheable class: a cached verdict is
// sound only if the predicate is pure (1367-upz6), and the one route to file
// bytes a Cacheable predicate has is `fs.read`, whose reads key the memo
// (1367-q9yc). `path.*` is LEXICAL for the same reason: it never touches the
// filesystem, so `path.normalize` cannot observe a symlink.
//
// Adding a table here ADDS to the Cacheable allow-list
// (lua_predicate::CACHEABLE_STDLIB_GLOBALS); it never widens the class by
// removing a deny. A new impure table goes in the Observing arm, or nowhere.

use crate::lua_predicate::PredicateClass;
use mlua::prelude::*;

/// The global tables `register` adds for `class`, sorted. Pinned by a test so
/// widening what a class can reach is a visible diff.
pub fn tables(class: PredicateClass) -> &'static [&'static str] {
    match class {
        PredicateClass::Cacheable => &["hash", "json", "path", "yaml"],
        PredicateClass::Observing => &["hash", "json", "path", "time", "yaml"],
    }
}

/// Register the standard tables for `class` into `lua`'s globals.
pub fn register(lua: &Lua, class: PredicateClass) -> LuaResult<()> {
    let g = lua.globals();
    g.set("json", json_table(lua)?)?;
    g.set("yaml", yaml_table(lua)?)?;
    g.set("hash", hash_table(lua)?)?;
    g.set("path", path_table(lua)?)?;
    if matches!(class, PredicateClass::Observing) {
        g.set("time", time_table(lua)?)?;
    }
    determinism(lua)?;
    Ok(())
}

/// 1384-bp6t: ONE SCRIPT, ONE BYTE STREAM.
///
/// Lua 5.4 seeds string hashing per process (`luai_makeseed`: ASLR + the
/// clock), and `pairs`/`next` walk the hash, so the same script printed a
/// different key order in every process: measured on yoga, three runs of one
/// 12-key table gave three checksums. `pairs` is replaced by a walk in a
/// DEFINED order — numbers ascending, then strings in byte order, then any
/// other key type by `tostring` — `table.keys` returns that order, and the
/// raw `next` is withheld so nothing can reach the hash order.
///
/// `os.setlocale` is withheld too (1254-fdsu's class): one `os.setlocale("")`
/// under fr_FR flipped `%.2f` from `3.50` to `3,50` and made `tonumber("3,5")`
/// parse. The Rust binary never calls setlocale, so Lua stays in "C" as long
/// as no script can change it.
fn determinism(lua: &Lua) -> LuaResult<()> {
    lua.load(
        r#"
        local rawnext, type, tostring, tsort = next, type, tostring, table.sort
        local rank = { number = 1, string = 2 }
        local function before(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return (rank[ta] or 3) < (rank[tb] or 3) or
                ((rank[ta] or 3) == (rank[tb] or 3) and ta < tb) end
            if ta == "number" or ta == "string" then return a < b end
            return tostring(a) < tostring(b)
        end
        local function keys(t)
            local ks = {}
            for k in rawnext, t, nil do ks[#ks + 1] = k end
            tsort(ks, before)
            return ks
        end
        pairs = function(t)
            local ks, i = keys(t), 0
            return function()
                i = i + 1
                local k = ks[i]
                if k ~= nil then return k, t[k] end
            end, t, nil
        end
        table.keys = keys
        -- 1395-xjty: the emptiness test authors reach for is next(t) == nil;
        -- give them the replacement, and make reaching for next SAY so.
        table.is_empty = function(t) return rawnext(t) == nil end
        next = nil
        setmetatable(_G, { __index = function(_, k)
            if k == "next" then
                error("next is withheld in lua_std (1384-bp6t: its walk order varies per " ..
                      "process); test emptiness with table.is_empty(t), iterate with pairs(t)", 2)
            end
            return nil
        end })
        if type(os) == "table" then os.setlocale = nil end
        "#,
    )
    .set_name("=lua_std.determinism")
    .exec()
}

/// Rebuild every object with its keys in byte order, recursively. The
/// workspace enables serde_json `preserve_order`, so a map built from a Lua
/// table keeps the HASH order it was walked in; sorting here is what makes
/// `json.encode` of the same table the same bytes in every process.
fn canonical(v: serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(m) => {
            let mut pairs: Vec<(String, serde_json::Value)> = m.into_iter().collect();
            pairs.sort_by(|a, b| a.0.cmp(&b.0));
            serde_json::Value::Object(pairs.into_iter().map(|(k, v)| (k, canonical(v))).collect())
        }
        serde_json::Value::Array(a) => {
            serde_json::Value::Array(a.into_iter().map(canonical).collect())
        }
        other => other,
    }
}

fn rt(msg: impl Into<String>) -> LuaError {
    LuaError::RuntimeError(msg.into())
}

fn json_table(lua: &Lua) -> LuaResult<LuaTable> {
    let t = lua.create_table()?;
    t.set(
        "parse",
        lua.create_function(|lua, s: String| {
            let v: serde_json::Value =
                serde_json::from_str(&s).map_err(|e| rt(format!("json.parse: {e}")))?;
            lua.to_value(&v)
        })?,
    )?;
    t.set(
        "encode",
        lua.create_function(|lua, (v, opts): (LuaValue, Option<LuaTable>)| {
            let j: serde_json::Value = canonical(
                lua.from_value(v)
                    .map_err(|e| rt(format!("json.encode: {e}")))?,
            );
            let pretty = opts
                .and_then(|o| o.get::<Option<bool>>("pretty").ok().flatten())
                .unwrap_or(false);
            let out = if pretty {
                serde_json::to_string_pretty(&j)
            } else {
                serde_json::to_string(&j)
            };
            out.map_err(|e| rt(format!("json.encode: {e}")))
        })?,
    )?;
    // 1398-3qiz. THE EMPTY-TABLE RULE. Lua cannot tell an empty array from
    // an empty object, so json.encode renders an UNMARKED empty table as {}.
    // json.array(t?) marks a table (a new empty one when called with no
    // argument) with mlua's array metatable, so it encodes as [] even when
    // empty; json.parse already returns its arrays marked, so [] round-trips.
    // A non-empty sequence encodes as an array either way. Pure: in both
    // classes. Measured pre-fix: json.encode({a={}, b={1}}) -> {"a":{},"b":[1]},
    // which left the CentiColon extractor's empty "missing" list ambiguous.
    t.set(
        "array",
        lua.create_function(|lua, t: Option<LuaTable>| {
            let t = match t {
                Some(t) => t,
                None => lua.create_table()?,
            };
            t.set_metatable(Some(lua.array_metatable()));
            Ok(t)
        })?,
    )?;
    // json.query(v, filter [, args]) — the 1375-rn9b engine
    // (json_query::parse + json_query::eval; surface agreed with lenovinha
    // 2026-09-26). Returns a Lua SEQUENCE of every result; `args` binds `$name`.
    // Errors carry the engine's own prefix — parse:<at>: / unsupported:<construct>
    // / runtime: — so a caller or the ratchet can match on the kind. Pure: a
    // function of its arguments, so it sits in the Cacheable class (and over
    // fs.read it stays pure because that memo is content-addressed, 1367-q9yc).
    t.set(
        "query",
        lua.create_function(|lua, (v, f, args): (LuaValue, String, Option<LuaTable>)| {
            let input: serde_json::Value = lua
                .from_value(v)
                .map_err(|e| rt(format!("json.query: input: {e}")))?;
            let filter =
                crate::json_query::parse(&f).map_err(|e| rt(format!("json.query: {e}")))?;
            let mut opts = crate::json_query::Opts::default();
            if let Some(a) = args {
                for pair in a.pairs::<String, LuaValue>() {
                    let (k, lv) = pair?;
                    let jv: serde_json::Value = lua
                        .from_value(lv)
                        .map_err(|e| rt(format!("json.query: arg {k}: {e}")))?;
                    opts.args.insert(k, jv);
                }
            }
            let results = crate::json_query::eval(&input, &filter, &opts)
                .map_err(|e| rt(format!("json.query: {e}")))?;
            let out = lua.create_table()?;
            for (i, r) in results.iter().enumerate() {
                out.set(i + 1, lua.to_value(r)?)?;
            }
            Ok(out)
        })?,
    )?;
    Ok(t)
}

fn yaml_table(lua: &Lua) -> LuaResult<LuaTable> {
    let t = lua.create_table()?;
    t.set(
        "parse",
        lua.create_function(|lua, s: String| {
            let v: serde_json::Value =
                serde_yaml::from_str(&s).map_err(|e| rt(format!("yaml.parse: {e}")))?;
            lua.to_value(&v)
        })?,
    )?;
    Ok(t)
}

fn hash_table(lua: &Lua) -> LuaResult<LuaTable> {
    let t = lua.create_table()?;
    t.set(
        "sha256",
        lua.create_function(|_, s: LuaString| {
            use sha2::{Digest, Sha256};
            let d = Sha256::digest(&*s.as_bytes());
            Ok(d.iter().map(|b| format!("{b:02x}")).collect::<String>())
        })?,
    )?;
    Ok(t)
}

/// Lexical normalisation on `/`-separated strings: drops `.` and empty
/// segments, resolves `..` against a preceding segment, keeps leading `..` in
/// a relative path and drops it at an absolute root. Never touches the disk.
pub fn normalize(p: &str) -> String {
    let absolute = p.starts_with('/');
    let mut out: Vec<&str> = Vec::new();
    for seg in p.split('/') {
        match seg {
            "" | "." => {}
            ".." => match out.last() {
                Some(&last) if last != ".." => {
                    out.pop();
                }
                _ if absolute => {}
                _ => out.push(".."),
            },
            s => out.push(s),
        }
    }
    let body = out.join("/");
    match (absolute, body.is_empty()) {
        (true, _) => format!("/{body}"),
        (false, true) => ".".to_string(),
        (false, false) => body,
    }
}

fn path_table(lua: &Lua) -> LuaResult<LuaTable> {
    let t = lua.create_table()?;
    t.set(
        "join",
        lua.create_function(|_, parts: LuaVariadic<String>| {
            let mut acc = String::new();
            for p in parts.iter() {
                if p.starts_with('/') || acc.is_empty() {
                    acc = p.clone();
                } else {
                    acc = format!("{acc}/{p}");
                }
            }
            Ok(normalize(&acc))
        })?,
    )?;
    t.set(
        "normalize",
        lua.create_function(|_, p: String| Ok(normalize(&p)))?,
    )?;
    t.set(
        "basename",
        lua.create_function(|_, p: String| {
            let n = normalize(&p);
            Ok(n.rsplit('/').next().unwrap_or("").to_string())
        })?,
    )?;
    t.set(
        "dirname",
        lua.create_function(|_, p: String| {
            let n = normalize(&p);
            Ok(match n.rfind('/') {
                Some(0) => "/".to_string(),
                Some(i) => n[..i].to_string(),
                None => ".".to_string(),
            })
        })?,
    )?;
    Ok(t)
}

fn time_table(lua: &Lua) -> LuaResult<LuaTable> {
    let t = lua.create_table()?;
    t.set(
        "now_ms",
        lua.create_function(|_, ()| {
            Ok(std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as u64)
        })?,
    )?;
    // The fragment-filename clock: 20260926t004655z.
    t.set(
        "iso_utc",
        lua.create_function(|_, ()| Ok(chrono::Utc::now().format("%Y%m%dt%H%M%Sz").to_string()))?,
    )?;
    Ok(t)
}

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn normalize_is_lexical() {
        assert_eq!(normalize("a/../b"), "b");
        assert_eq!(normalize("./a//b/"), "a/b");
        assert_eq!(normalize("../a"), "../a");
        assert_eq!(normalize("/../a"), "/a");
        assert_eq!(normalize("a/.."), ".");
        assert_eq!(normalize("/"), "/");
    }
}
