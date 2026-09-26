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
    Ok(())
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
            let j: serde_json::Value = lua
                .from_value(v)
                .map_err(|e| rt(format!("json.encode: {e}")))?;
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
    // json.query(v, filter [, args]) is the 1375-rn9b engine
    // (json_query::parse + json_query::eval, surface agreed with lenovinha
    // 2026-09-26): a Lua sequence of results, erroring with the engine's
    // "parse:/unsupported:/runtime:" text. Until that engine is on trunk the
    // name exists and REFUSES by name rather than being nil, so a caller
    // reads why instead of "attempt to call a nil value".
    t.set(
        "query",
        lua.create_function(|_, (_v, _f): (LuaValue, String)| -> LuaResult<LuaValue> {
            Err(rt(
                "json.query: unsupported:engine-not-landed — json_query::eval arrives with 1375-rn9b",
            ))
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
