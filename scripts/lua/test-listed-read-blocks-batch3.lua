-- @trace order:2417-jzhh, order:2416-pscn
--
-- test-listed-read-blocks-batch3.lua: eight checkers (2417-jzhh batch 3) block,
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
-- Usage: tillandsias-plan script run scripts/lua/test-listed-read-blocks-batch3.lua

local fixture = require "common.fixture"
local T = fixture.new("listed-read-blocks-batch3")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local W = T:scratch("b3")

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
local function git_commit(paths)
    return function(abs)
        T:must{ "git", "-C", abs, "init", "-q" }
        local add = { "git", "-C", abs, "add", "--" }
        for _, p in ipairs(paths) do add[#add + 1] = p end
        T:must(add)
        T:must{ "git", "-C", abs, "-c", "user.name=fixture", "-c", "user.email=fixture@invalid", "commit", "-qm", "fixture" }
    end
end

arm("check-image-pins", "image-pins",
    { ["images/image-pins.yaml"] = "pins: []\n", ["images/a/Containerfile"] = "FROM scratch\n", ["images/b/Containerfile"] = "FROM scratch\n" },
    "images/b/Containerfile", seam("TILLANDSIAS_IMAGE_PINS_SCAN_ROOT"))

arm("check-jq-multiline-capture-strips-cr", "jq-multiline-capture-strips-cr",
    { ["s/a.sh"] = "echo a\n", ["s/locked.sh"] = "echo b\n" },
    "s/locked.sh", none, { args_of = function(rel) return { rel .. "/s" } end })

arm("check-launch-artifacts-untracked", "launch-artifacts-untracked",
    { ["images/default/entrypoint-forge-a.sh"] = "echo a\n", ["images/default/entrypoint-forge-locked.sh"] = "echo b\n",
      ["images/default/lib-common.sh"] = "echo c\n" },
    "images/default/entrypoint-forge-locked.sh", none, { args_of = function(rel) return { rel } end })

arm("check-litmus-expression-pinning-added", "litmus-expression-pinning-added",
    { ["README"] = "x\n", ["openspec/litmus-tests/locked.yaml"] = 'steps:\n  - command: "true"\n' },
    "openspec/litmus-tests/locked.yaml",
    function(_, abs) return { TILLANDSIAS_REPO_ROOT = abs, TILLANDSIAS_PIN_ENFORCE_BASE = "HEAD" } end,
    { prep = git_commit{ "README" } })

arm("check-litmus-grep-escapes", "litmus-grep-escapes",
    { ["l/a.yaml"] = "steps: []\n", ["l/locked.yaml"] = "steps: []\n" },
    "l/locked.yaml", none, { args_of = function(rel) return { rel .. "/l" } end })

arm("check-litmus-steps-can-fail", "litmus-steps-can-fail",
    { ["l/a.yaml"] = "steps: []\n", ["l/locked.yaml"] = "steps: []\n" },
    "l/locked.yaml", seam("TILLANDSIAS_LITMUS_DIR", "/l"))

arm("check-nix-cache-installer-compatible", "nix-cache-installer",
    { ["wf/a.yml"] = "on: push\n", ["wf/locked.yml"] = "on: push\n" },
    "wf/locked.yml", seam("TILLANDSIAS_NIX_CACHE_WORKFLOW_DIR", "/wf"))

local B64 = "base64" .. " -d"
arm("check-no-base64-script-injection", "no-base64-script-injection",
    { ["a.sh"] = B64 .. " x\n", ["locked.sh"] = B64 .. " y; chmod +x z\n" },
    "locked.sh", function(_, abs) return { TILLANDSIAS_REPO_ROOT = abs } end,
    { prep = git_commit{ "a.sh", "locked.sh" } })

T:finish()
