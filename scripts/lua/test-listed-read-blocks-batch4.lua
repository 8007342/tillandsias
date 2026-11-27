-- @trace order:2417-jzhh, order:2416-pscn
--
-- test-listed-read-blocks-batch4.lua: nine checkers (2417-jzhh batch 4) block,
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
-- Usage: tillandsias-plan script run scripts/lua/test-listed-read-blocks-batch4.lua

local fixture = require "common.fixture"
local T = fixture.new("listed-read-blocks-batch4")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local W = T:scratch("b4")

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
local RS = { ["src/a.rs"] = "fn x() {}\n", ["src/locked.rs"] = "fn y() {}\n" }

arm("check-no-host-browser-launch", "no-host-browser-launch", RS, "src/locked.rs", seam("TILLANDSIAS_HOST_BROWSER_SCAN_ROOTS", "/src"))

arm("check-no-spawn-in-if-not", "no-spawn-in-if-not", { ["s/a.sh"] = "echo a\n", ["s/locked.sh"] = "echo b\n" },
    "s/locked.sh", none, { args_of = function(rel) return { rel .. "/s/a.sh", rel .. "/s/locked.sh" } end })

arm("check-plan-ledger-readers", "plan-ledger-readers", { ["scripts/a.sh"] = "echo a\n", ["scripts/locked.sh"] = "echo b\n" },
    "scripts/locked.sh", rooted)

arm("local-delegate-ladder", "local-delegate-ladder", { ["l/a.yaml"] = "events: []\n", ["l/locked.yaml"] = "events: []\n" },
    "l/locked.yaml", none, { args_of = function(rel) return { "aggregate", "--ledger", rel .. "/l/a.yaml", "--ledger", rel .. "/l/locked.yaml" } end })

arm("check-portability-idioms", "portability-idioms", { ["scripts/a.sh"] = "echo a\n", ["scripts/locked.sh"] = "echo b\n" },
    "scripts/locked.sh", seam("TILLANDSIAS_PORTABILITY_ROOT"))

arm("check-proxy-permissive-port-routing", "proxy-permissive-port-routing",
    { ["squid.conf"] = "http_port 3128\n", ["src/a.rs"] = "fn x() {}\n", ["src/locked.rs"] = "fn y() {}\n" },
    "src/locked.rs", function(_, abs) return { TILLANDSIAS_PROXY_CONF = abs .. "/squid.conf", TILLANDSIAS_PROXY_CONSUMER_ROOT = abs .. "/src" } end)

arm("check-requirement-ids", "requirement-ids",
    { ["openspec/specs/a/spec.md"] = "# a\n", ["openspec/specs/locked/spec.md"] = "# b\n" },
    "openspec/specs/locked/spec.md", seam("TILLANDSIAS_SPEC_ROOT"))

arm("check-secure-wire-single-reader", "secure-wire-single-reader",
    { ["crates/a.rs"] = "fn x() {}\n", ["crates/locked.rs"] = "fn y() {}\n" }, "crates/locked.rs", rooted)

arm("check-smoke-agent-prompt-is-minimal", "smoke-agent-prompt",
    { ["skills/a-smoke/SKILL.md"] = "# a\n", ["skills/locked-smoke/SKILL.md"] = "# b\n" },
    "skills/locked-smoke/SKILL.md", seam("TILLANDSIAS_SKILLS_ROOT", "/skills"))

T:finish()
