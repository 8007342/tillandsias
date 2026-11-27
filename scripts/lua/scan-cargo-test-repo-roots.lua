-- @trace order:2175-ctin
--
-- scan-cargo-test-repo-roots.lua — the repo paths the cargo test steps can READ,
-- derived from the Rust sources, so the skip declaration for those steps
-- (_CARGO_TEST_INPUTS in build.sh) cannot silently rot.
--
-- WHY (coordinator + operator, 2026-11-22): the workspace and feature-gated
-- cargo test steps may be skipped against a daily full proof (2174-dail) when
-- none of their inputs changed. "rust only" is wrong: headless embeds ~650
-- files (images/, skills/, research/, cheatsheets/) through tillandsias-embed,
-- ~100 include_str! reach images/ and scripts/, and tests read plan/, assets/,
-- locales/, openspec/ at runtime through CARGO_MANIFEST_DIR joins. A skipped
-- step whose real input changed is the one failure this must never produce.
--
-- WHAT IT SCANS (every crates/**/*.rs, build.rs included): string literals that
--   1. start with ../ : resolved against the file's dir (include_str!) AND the
--      crate dir (CARGO_MANIFEST_DIR joins); every resolution that lands in a
--      top-level repo directory counts;
--   2. name a top-level repo directory as their first component, in a file
--      that mentions CARGO_MANIFEST_DIR or repo_root (joins, read_dir roots,
--      build.rs rerun-if-changed): `"images"`, `"scripts/manage-cache.sh"`.
-- A path under crates/ is the `rust` class. A literal FILE under scripts/ is
-- named exactly (so a Lua-only PR can still skip); anything else widens to
-- <top>/**. Every uncertainty WIDENS the set: a false positive costs a run,
-- a false negative ships an unrun test.
--
-- KNOWN LIMIT: a path assembled from variables at runtime, with no literal
-- naming its top directory, is invisible to any static scan. The daily full
-- run (2174-dail) is the backstop for that class.
--
-- Usage:
--   tillandsias-plan script run scripts/lua/scan-cargo-test-repo-roots.lua            list
--   tillandsias-plan script run scripts/lua/scan-cargo-test-repo-roots.lua -- --check  refuse a gap
-- Verdict (--check): ok:cargo-test-inputs:<roots> | violation:cargo-test-inputs:missing:<n>

-- Default (no args, as the gate step runs it): --check _CARGO_FEATURE_TEST_INPUTS
-- against the tillandsias-headless closure. --list prints the scanned roots.
local check, only, declvar = true, "tillandsias-headless", "_CARGO_FEATURE_TEST_INPUTS"
local compileonly = false
local showwhy = false
local buildsh = "build.sh"  -- --build-sh FILE: judge a scratch copy (2239-5gb5 fixture)
do
    local i = 1
    while arg and arg[i] do
        if arg[i] == "--check" then check = true; i = i + 1
        elseif arg[i] == "--list" then check = false; i = i + 1
        elseif arg[i] == "--why" then check = false; showwhy = true; i = i + 1
        elseif arg[i] == "--workspace" then only = nil; i = i + 1
        elseif arg[i] == "--crate" then only = arg[i + 1]; i = i + 2
        elseif arg[i] == "--var" then declvar = arg[i + 1]; i = i + 2
        elseif arg[i] == "--build-sh" then buildsh = arg[i + 1]; i = i + 2
        -- --compile-only (2440-8893): what COMPILES in, for clippy: in a source file only the
        -- include*!(...) invocations; a build.rs whole (it reads at build time). Nothing a test
        -- reads or executes at run time, because clippy runs nothing.
        elseif arg[i] == "--compile-only" then compileonly = true; i = i + 1
        else i = i + 1 end
    end
end
-- --crate NAME: scan only that crate and its workspace path-dependency closure
-- (what its test binary compiles), for a step that tests one crate.
local scope = nil
if only then
    scope = {}
    local queue = { only }
    while #queue > 0 do
        local c = table.remove(queue)
        if not scope[c] then
            scope[c] = true
            local toml = fs.read("crates/" .. c .. "/Cargo.toml") or ""
            for dep in toml:gmatch('path%s*=%s*"%.%./([%w_-]+)"') do queue[#queue + 1] = dep end
        end
    end
end

-- top-level repo directories, from git (never guessed)
local tops = {}
local r = proc.run({ argv = { "git", "ls-tree", "--name-only", "-d", "HEAD" }, timeout_ms = 30000 })
for d in (r.stdout or ""):gmatch("[^\n]+") do
    if d ~= "crates" and d ~= "target" then tops[d] = true end
end

local function isdir(p) local ok, t = pcall(fs.list, p); return ok and type(t) == "table" end
local function norm(parts)
    local out = {}
    for _, p in ipairs(parts) do
        if p == ".." then
            if #out == 0 then return nil end
            table.remove(out)
        elseif p ~= "." and p ~= "" then
            out[#out + 1] = p
        end
    end
    return out
end
local function split(s) local t = {}; for p in s:gmatch("[^/]+") do t[#t + 1] = p end; return t end
local function join(a, b) local t = {}; for _, x in ipairs(a) do t[#t + 1] = x end; for _, x in ipairs(b) do t[#t + 1] = x end; return t end

local need, why, cur = {}, {}, ""  -- why[root] = first "file: literal" that produced it (--why)
local function add(parts)
    if not parts or #parts == 0 then return end
    local top = parts[1]
    if top == "crates" or top == "target" or not tops[top] then return end
    local p = table.concat(parts, "/")
    -- A literal naming an existing FILE is that file; a directory (or anything
    -- that does not exist as a file: a scratch name, a prefix) widens to the
    -- deepest existing directory on its path, never narrower.
    if #parts > 1 and fs.exists(p) and not isdir(p) then
        need["path:" .. p] = true; why["path:" .. p] = why["path:" .. p] or cur
        return
    end
    local d = parts[1]
    for i = 2, #parts do
        local nd = d .. "/" .. parts[i]
        if isdir(nd) then d = nd else break end
    end
    -- both forms: `case p in X/**)` never matches X itself, and X may be a file
    -- the probe could not classify (a dot path), so name it exactly too.
    need["path:" .. d .. "/**"] = true; why["path:" .. d .. "/**"] = why["path:" .. d .. "/**"] or cur
    need["path:" .. d] = true
end

local files = 0
for _, f in ipairs(fs.walk("crates", { suffix = ".rs" })) do
    local crate = f:match("^crates/([^/]+)/")
    if not f:find("/target/", 1, true) and (not scope or (crate and scope[crate])) then
        files = files + 1
        local body = fs.read(f) or ""
        if compileonly and not f:match("/build%.rs$") then
            local inc = {}
            for m in body:gmatch("include[%w_]*!%s*%b()") do inc[#inc + 1] = m end
            body = table.concat(inc, "\n")
        end
        local fdir = split(f); table.remove(fdir)
        local cdir = split(f:match("^(crates/[^/]+)/") or "crates")
        local rooted = body:find("CARGO_MANIFEST_DIR", 1, true) or body:find("repo_root", 1, true)
        for lit in body:gmatch('"([^"\n]+)"') do
            if lit:match("^%.%./") then
                local rel = split(lit)
                cur = f .. ": " .. lit
                add(norm(join(fdir, rel)))
                add(norm(join(cdir, rel)))
            elseif rooted then
                local parts = split(lit)
                cur = f .. ": " .. lit
                if #parts > 0 and tops[parts[1]] and not lit:find("%s") then add(parts) end
            end
            -- ORDER 2239-5gb5: A SCRIPT A TEST EXECUTES. `Command::new("bash")
            -- .arg("scripts/x.sh")`, "bash scripts/x.sh", "$ROOT/scripts/x.sh",
            -- an env-var default: any literal holding a scripts/ path counts, in
            -- EVERY scanned file, rooted or not and wherever the path sits in
            -- the string. Since scripts/** stopped being declared wholesale, a
            -- missed exec would be a silent coverage hole, so this is the
            -- wider net. Paths assembled with no literal at all stay the daily
            -- full run's to catch (KNOWN LIMIT above).
            for sp in lit:gmatch("scripts/[%w_.@/-]+") do
                if not lit:match("^%.%./") then
                    cur = f .. ": " .. lit
                    add(split((sp:gsub("[./]+$", ""))))
                end
            end
        end
    end
end

-- collapse: an entry under a broader `dir/**` entry adds nothing
local function under(k, d) local p = k:gsub("^path:", ""):gsub("/%*%*$", ""); return p ~= d and p:sub(1, #d + 1) == d .. "/" end
local list = {}
for k in pairs(need) do
    local dominated = false
    for o in pairs(need) do
        local d = o:match("^path:(.+)/%*%*$")
        if d and o ~= k and under(k, d) then dominated = true; break end
    end
    if not dominated then list[#list + 1] = k end
end
table.sort(list)

if not check then
    for _, k in ipairs(list) do out.line(showwhy and (k .. "  <- " .. (why[k] or "?")) or k) end
    verdict.emit("ok:cargo-test-inputs:" .. #list .. ":files=" .. files, 0)
end

-- --check: every scanned root must be covered by build.sh's declaration.
local build = fs.read(buildsh) or ""
local decl = build:match('\n' .. declvar .. '="([^"]*)"')
if not decl then
    verdict.emit("violation:cargo-test-inputs:no-declaration", 1,
        "  build.sh has no _CARGO_TEST_INPUTS=\"...\" line; the cargo test steps cannot declare what they read")
end
local have = {}
for t in decl:gmatch("%S+") do have[t] = true end
-- covered when declared exactly, or by any declared `path:<dir>/**` above it
local function covered(k)
    if have[k] then return true end
    local p = k:gsub("^path:", ""):gsub("/%*%*$", "")
    for t in pairs(have) do
        local d = t:match("^path:(.+)/%*%*$")
        if d and (p == d or p:sub(1, #d + 1) == d .. "/") then return true end
    end
    return false
end
local missing = {}
for _, k in ipairs(list) do
    if not covered(k) then missing[#missing + 1] = k end
end
if #missing > 0 then
    for _, m in ipairs(missing) do log.raw("  missing from " .. declvar .. ": " .. m) end
    log.raw("  why: a cargo test step can read these paths (scanned from crates/**/*.rs), so a change to one must run it")
    log.raw("  remedy: add each line above to " .. declvar .. " in build.sh (2175-ctin)")
    verdict.emit("violation:cargo-test-inputs:missing:" .. #missing, 1)
end
verdict.emit("ok:cargo-test-inputs:" .. #list .. ":files=" .. files, 0)
