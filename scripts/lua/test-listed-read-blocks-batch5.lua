-- @trace order:2417-jzhh, order:2416-pscn
--
-- test-listed-read-blocks-batch5.lua: nine checkers (2417-jzhh batch 5) block,
-- exit 2 naming the file, when a file in their listing cannot be read. Before
-- the fix each wrapped the read in pcall(fs.read) and dropped a failure, so a
-- listed file it never read counted as clean.
--
-- Each arm builds a small tree in scratch holding one readable file and one
-- chmod 000 file, points the checker at it (TILLANDSIAS_REPO_ROOT, or the
-- checker's own scan seam), and expects blocked:<name>:unreadable:1 with the
-- file named. Its CONTROL makes the same file readable again and expects the
-- checker NOT to block on it.
--
-- chmod 000 does not stop root from reading a file. Where the planted file
-- still reads, the run skips (could not plant) rather than passing.
--
-- Usage: tillandsias-plan script run scripts/lua/test-listed-read-blocks-batch5.lua

local fixture = require "common.fixture"
local T = fixture.new("listed-read-blocks-batch5")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local W = T:scratch("b5")

local n = 0
-- tree: { [relpath] = body }; locked: relpath inside the tree to chmod 000
local function plant(tree, locked, prep)
    n = n + 1
    local rel, abs = W.rel .. "/t" .. n, W.abs .. "/t" .. n
    -- require resolves lib/lua from TILLANDSIAS_REPO_ROOT, so a re-rooted tree carries the module
    fs.mkdir(rel .. "/lib/lua/common"); fs.write(rel .. "/lib/lua/common/listed_read.lua", fs.read("lib/lua/common/listed_read.lua"))
    for p, body in pairs(tree) do
        fs.mkdir((rel .. "/" .. p):match("^(.*)/[^/]*$"))
        fs.write(rel .. "/" .. p, body)
    end
    if prep then prep(abs) end
    T:must{ "chmod", "000", abs .. "/" .. locked }
    if pcall(fs.read, rel .. "/" .. locked) then
        T:run{ "chmod", "644", abs .. "/" .. locked }
        T:skip("could-not-plant: chmod 000 left the file readable (running as root?)")
    end
    return rel, abs
end

local function run(checker, env_, args)
    local argv = { PLAN, "script", "run", ROOT .. "/scripts/lua/" .. checker .. ".lua" }
    if args then argv[#argv + 1] = "--"; for _, a in ipairs(args) do argv[#argv + 1] = a end end
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = ROOT, env_, { "TILLANDSIAS_*" }, 120000
    local r = T:run(argv)
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o
end

-- one checker: red arm (blocks, names the file) and control (readable again: no block)
-- opts: args_of(rel, abs) -> checker arguments; prep(abs) runs before the chmod
local function arm(checker, name, tree, locked, env_of, opts)
    opts = opts or {}
    local rel, abs = plant(tree, locked, opts.prep)
    local args = opts.args_of and opts.args_of(rel, abs)
    local rc, o = run(checker, env_of(rel, abs), args)
    T:arm(checker .. " blocks on an unreadable listed file", rc == 2
        and text.contains(o, "blocked:" .. name .. ":unreadable:1") and text.contains(o, locked),
        "rc=" .. tostring(rc) .. " " .. o:sub(-400):gsub("\n", " | "))
    T:run{ "chmod", "644", abs .. "/" .. locked }
    local rc2, o2 = run(checker, env_of(rel, abs), args)
    T:arm(checker .. " CONTROL readable again: not blocked on it", not text.contains(o2, ":unreadable:"),
        "rc=" .. tostring(rc2) .. " " .. o2:sub(-400):gsub("\n", " | "))
end

local none = function() return {} end
local function seam(var, sub) return function(_, abs) return { [var] = abs .. (sub or "") } end end
local rooted = seam("TILLANDSIAS_REPO_ROOT")

arm("check-source-slice-bounds", "source-slice-bounds",
    { ["c/k/Cargo.toml"] = "[package]\n", ["c/k/src/a.rs"] = "fn x() {}\n", ["c/k/src/locked.rs"] = "fn y() {}\n" },
    "c/k/src/locked.rs", seam("TILLANDSIAS_SLICE_BOUND_ROOT", "/c"))

arm("check-spec-registry-status", "spec-registry-status",
    { ["openspec/litmus-bindings.yaml"] = "- spec_id: a\n  status: active\n- spec_id: locked\n  status: active\n",
      ["openspec/specs/a/spec.md"] = "## Status\n\nstatus: active\n", ["openspec/specs/locked/spec.md"] = "## Status\n\nstatus: active\n" },
    "openspec/specs/locked/spec.md",
    function(_, abs) return { TILLANDSIAS_SPEC_ROOT = abs, TILLANDSIAS_SPEC_UNDECIDED = "" } end)

arm("check-state-root-literals", "state-root-literals",
    { ["crates/a.rs"] = "fn x() {}\n", ["crates/locked.rs"] = "fn y() {}\n" }, "crates/locked.rs", rooted)

arm("check-terminology", "terminology",
    { ["loc/terminology.toml"] = '[[term]]\ncanonical = "forge"\nwrong = ["frog"]\n', ["loc/a.toml"] = 'k = "v"\n', ["loc/locked.toml"] = 'k = "w"\n' },
    "loc/locked.toml", function(_, abs) return { TILLANDSIAS_LOCALE_DIR = abs .. "/loc", TILLANDSIAS_TERMINOLOGY_DICT = abs .. "/loc/terminology.toml" } end)

arm("check-unique-bin-names", "unique-bin-names",
    { ["crates/a/Cargo.toml"] = "[package]\n", ["crates/locked/Cargo.toml"] = "[package]\n" }, "crates/locked/Cargo.toml", rooted)

-- MINGW stands in for uname so the scan runs here; no readable source says
-- cfg(windows), so the control stops at crate-untouched and never runs cargo.
arm("check-windows-tray-clippy", "windows-tray-clippy",
    { ["cr/w/Cargo.toml"] = "[package]\n", ["cr/w/src/a.rs"] = "fn x() {}\n", ["cr/w/src/locked.rs"] = "fn y() {}\n" },
    "cr/w/src/locked.rs",
    function(_, abs) return { TILLANDSIAS_WINDOWS_CLIPPY_UNAME = "MINGW64_NT", TILLANDSIAS_WINDOWS_CLIPPY_CRATES_DIR = abs .. "/cr" } end)

arm("check-wsl-exe-single-constructor", "wsl-single-constructor",
    { ["crates/tillandsias-core/src/wsl.rs"] = "fn x() {}\n", ["crates/locked.rs"] = "fn y() {}\n" }, "crates/locked.rs", rooted)

arm("check-wt-reparse-workarounds-deleted", "wt-reparse-workarounds-deleted",
    { ["c/a.rs"] = "fn x() {}\n", ["c/locked.rs"] = "fn y() {}\n" }, "c/locked.rs",
    function(_, abs) return { TILLANDSIAS_WT_REPARSE_SCAN_ROOT = abs } end, { args_of = function(_, abs) return { abs .. "/c" } end })

local function decide_args(rel) return { "file-grep", "--name", "lr-decide", "--path", rel .. "/d", "--pattern", "zzz-nowhere", "--mode", "absent" } end
arm("litmus-decide", "lr-decide", { ["d/a.txt"] = "a\n", ["d/locked.txt"] = "b\n" }, "d/locked.txt", none, { args_of = decide_args })
-- the same file named directly by --path, not found by a walk
arm("litmus-decide", "lr-decide", { ["d/a.txt"] = "a\n", ["d/locked.txt"] = "b\n" }, "d/locked.txt", none,
    { args_of = function(rel) return { "file-grep", "--name", "lr-decide", "--path", rel .. "/d/a.txt", "--path", rel .. "/d/locked.txt", "--pattern", "zzz-nowhere", "--mode", "absent" } end })

T:finish()
