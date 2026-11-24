-- @trace order:2248-zcqh, order:1916-tsel
-- @env TILLANDSIAS_CRATE_GRAPH_METADATA TILLANDSIAS_CRATE_GRAPH_DERIVED
--
-- check-gate-changed-crate-graph.lua — the crate graph gate-changed.sh DERIVES
-- (awk over each member's Cargo.toml `path = "../x"` lines) must equal the one
-- cargo itself resolves. The intake gate (2248-zcqh) runs only a changed
-- crate's reverse-dependency closure, so a dependency the awk misses (a
-- `path` written another way, a workspace-inherited dep, a renamed table) is a
-- crate intake would never run although the change breaks it — and the
-- bundle gate would be the first to say so. This compares the two edge sets
-- and names every edge either side has alone.
--
-- Derived:  scripts/gate-changed.sh --crate-graph  (<crate dir> TAB <dep dir>)
-- Cargo:    cargo metadata --format-version 1 --no-deps; for each workspace
--           package, each dependency carrying a `path` (any kind: normal,
--           dev, build), as repo-relative directories.
-- Seams (the fixture's planted mismatches; never set by a gate):
--   TILLANDSIAS_CRATE_GRAPH_METADATA  read cargo's JSON from this file
--   TILLANDSIAS_CRATE_GRAPH_DERIVED   read the derived edges from this file
--
-- Verdict:
--   ok:gate-changed-crate-graph:<n> edges                       exit 0
--   violation:gate-changed-crate-graph:missing=<a>:extra=<b>    exit 1
--   could-not-run:gate-changed-crate-graph                      exit 3

local fixture = require "common.fixture"
local ROOT = fixture.repo_root()
local NAME = "gate-changed-crate-graph"
-- Git's bash on native Windows, else bash. common.fixture.posix_shell() does
-- this (2246-fkea, #1389); it is not on trunk yet, so the idiom is inline
-- here until it lands.
local SH = "bash"
do
    local ep = text.trim(proc.run{ argv = { "git", "--exec-path" }, timeout_ms = 10000 }.stdout or "")
    if ep:find("^%a:/.*/libexec/git%-core$") then SH = (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe")) end
end

local function read_or_run(seam, argv)
    local f = env.get(seam)
    if f and f ~= "" then return fs.read(f) end
    local r = proc.run{ argv = argv, cwd = ROOT, timeout_ms = 300000 }
    if r.status ~= "exited" or r.code ~= 0 then
        verdict.could_not_run(NAME, table.concat(argv, " ") .. " failed: " .. tostring(r.status) .. " " .. text.trim(r.stderr or ""))
    end
    return r.stdout or ""
end

local derived_txt = read_or_run("TILLANDSIAS_CRATE_GRAPH_DERIVED",
    { SH, ROOT .. "/scripts/gate-changed.sh", "--crate-graph" })
local meta_txt = read_or_run("TILLANDSIAS_CRATE_GRAPH_METADATA",
    { "cargo", "metadata", "--format-version", "1", "--no-deps", "--manifest-path", ROOT .. "/Cargo.toml" })

local ok, meta = pcall(json.parse, meta_txt)
if not ok or type(meta) ~= "table" or type(meta.packages) ~= "table" then
    verdict.could_not_run(NAME, "cargo metadata did not parse as JSON with a packages list")
end

-- An absolute path as a repo-relative directory, whatever its separators.
local root_n = (fixture.plain_path(ROOT):gsub("\\", "/")):gsub("/+$", "")
local function rel(p)
    p = (fixture.plain_path(p or ""):gsub("\\", "/")):gsub("/+$", "")
    if p:sub(1, #root_n + 1) == root_n .. "/" then return p:sub(#root_n + 2) end
    -- A seam file written on another host: keep everything from crates/ on.
    return p:match("(crates/.*)$") or p
end

local cargo = {}
for _, pkg in ipairs(meta.packages) do
    local dir = rel(pkg.manifest_path):gsub("/Cargo%.toml$", "")
    for _, d in ipairs(pkg.dependencies or {}) do
        if d.path and d.path ~= "" then cargo[dir .. "\t" .. rel(d.path)] = true end
    end
end

local derived = {}
for _, l in ipairs(text.lines(derived_txt)) do
    l = text.trim(l)
    if l ~= "" then derived[l] = true end
end

local missing, extra, n = {}, {}, 0
for e in pairs(cargo) do n = n + 1; if not derived[e] then missing[#missing + 1] = e end end
for e in pairs(derived) do if not cargo[e] then extra[#extra + 1] = e end end
table.sort(missing); table.sort(extra)

for _, e in ipairs(missing) do
    log.raw("MISSING: cargo resolves " .. e:gsub("\t", " -> ") .. ", the derived graph does not: intake would not run the dependent when the dependency changes")
end
for _, e in ipairs(extra) do
    log.raw("EXTRA:   the derived graph has " .. e:gsub("\t", " -> ") .. ", cargo does not: intake runs a crate the change cannot reach (cost, not risk)")
end
if #missing + #extra > 0 then
    log.raw("  why: gate-changed.sh reads path deps with awk over Cargo.toml; cargo metadata is the authority (2248-zcqh)")
    log.raw("  remedy: make section 3 of scripts/gate-changed.sh read the dependency form it missed, or fix the manifest")
    verdict.emit("violation:" .. NAME .. ":missing=" .. #missing .. ":extra=" .. #extra, 1)
end
verdict.ok(NAME .. ":" .. n .. " edges")
