-- @trace order:1528-ekri, order:797-8dzt
-- @env TILLANDSIAS_SLICE_BOUND_ROOT
-- @read-env TILLANDSIAS_SLICE_BOUND_ROOT
--
-- check-source-slice-bounds.lua — PORTED from check-source-slice-bounds.sh,
-- byte for byte. A source-reading test that slices its own file between two
-- SYMBOL NAMES must not be bounded by a symbol that no longer exists. See the
-- .sh's header (preserved in git history) for the 2026-08-17 defect this
-- guards against — not restated here for the same reason
-- check-state-root-literals.lua gives: a single-sourced fact belongs in one
-- place.
--
-- WHAT IT CHECKS: every `.split("<needle>")` in a Rust source under
-- crates/ (or TILLANDSIAS_SLICE_BOUND_ROOT) whose needle looks like an item
-- declaration (`fn`, `pub fn`, `async fn`, `pub async fn`, `impl`, `struct`,
-- `enum`, `trait`). The needle must appear as a DECLARATION somewhere in that
-- needle's CRATE (nearest ancestor directory holding a Cargo.toml; a file
-- outside any crate is checked against the whole root, same as the .sh).
--
-- WHAT THE PORT MAKES SLIGHTLY DIFFERENT: the .sh iterates `find | sort`
-- then re-reads the whole crate with a fresh `grep -rqE` per needle; this
-- port reads each crate's sources once and caches them (an existence
-- question answered from memory instead of from disk each time), and
-- matches the declaration test with `(?m)` multi-line mode instead of
-- per-line grep — observably identical over the same bytes. The needle
-- extraction uses one capturing regex (`text.captures_all`) instead of
-- grep -oE piped to sed; it is the same text, filtered to the same shape.
--
-- Verdict grammar (unchanged, legacy):
--   ok:source-slice-bounds:<n> checked          exit 0
--   violation:source-slice-bounds:<n>           exit 1

local root_env = env.get("TILLANDSIAS_SLICE_BOUND_ROOT")
local CRATES_DIR = (root_env and root_env ~= "") and root_env or "crates"

local ok_walk, rs_files = pcall(fs.walk, CRATES_DIR, { suffix = ".rs" })
rs_files = (ok_walk and rs_files) or {}

-- Every `.split("<text>")` literal, text captured. Filtered below to the
-- declaration shape, replicating the .sh's single combined grep -oE.
local SPLIT_LITERAL = [==[\.split\("([^"]*)"\)]==]
local KIND_SHAPE = [==[^(?:pub )?(?:async )?fn [A-Za-z0-9_:<>]+$|^impl [A-Za-z0-9_:<>]+$|^struct [A-Za-z0-9_:<>]+$|^enum [A-Za-z0-9_:<>]+$|^trait [A-Za-z0-9_:<>]+$]==]

-- Cache: crate_src -> concatenated content of every .rs file under it, so a
-- crate shared by many needles is read from disk once.
local crate_content_cache = {}
local function crate_content(crate_src)
    local cached = crate_content_cache[crate_src]
    if cached ~= nil then return cached end
    local ok_w, files = pcall(fs.walk, crate_src, { suffix = ".rs" })
    local parts = {}
    if ok_w then
        for _, f in ipairs(files) do
            local ok_r, c = pcall(fs.read, f)
            if ok_r then parts[#parts + 1] = c end
        end
    end
    local joined = table.concat(parts, "\n")
    crate_content_cache[crate_src] = joined
    return joined
end

local function declared(crate_src, needle)
    local pat = [==[(?m)^\s*(?:[A-Za-z_]+ )*]==] .. text.escape(needle) .. [==[[\s(<{]]==]
    return text.is_match(crate_content(crate_src), pat)
end

local checked = 0
local violations = {}

for _, rs in ipairs(rs_files) do
    -- Nearest ancestor directory (lexical, from the path fs.walk gave us)
    -- holding a Cargo.toml; fall back to CRATES_DIR, same as the .sh.
    -- fs.exists is rooted to the REPO only (never widened by @read-env), so
    -- existence is tested with fs.read instead — overridden for both the
    -- repo and any declared read-env root, exactly like fs.walk above.
    local crate_src = nil
    local d = path.dirname(rs)
    while d ~= "." and d ~= "/" do
        if pcall(fs.read, d .. "/Cargo.toml") then
            crate_src = d
            break
        end
        d = path.dirname(d)
    end
    crate_src = crate_src or CRATES_DIR

    local ok_r, content = pcall(fs.read, rs)
    if ok_r then
        for _, needle in ipairs(text.captures_all(content, SPLIT_LITERAL)) do
            if text.is_match(needle, KIND_SHAPE) then
                checked = checked + 1
                if not declared(crate_src, needle) then
                    violations[#violations + 1] =
                        "  " .. rs .. ": slice bound \"" .. needle ..
                        "\" matches nothing in " .. crate_src ..
                        " — split() returns the WHOLE remainder, so this assertion has silently widened"
                end
            end
        end
    end
end

if #violations > 0 then
    for _, v in ipairs(violations) do log.raw(v) end
    log.raw("  CAUSE: str::split on an absent needle yields ONE piece — the entire remainder — so the window runs past its intended end and the assertion is satisfied by unrelated code.")
    log.raw("  REMEDY: bound the slice by structure (the item's own closing brace) rather than by a neighbour's NAME, or update the bound and re-run the mutation control that proves the assertion can still fail.")
    verdict.emit("violation:source-slice-bounds:" .. #violations, 1)
end

verdict.emit("ok:source-slice-bounds:" .. checked .. " checked", 0)
