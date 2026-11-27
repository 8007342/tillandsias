-- @trace order:2417-jzhh, order:2416-pscn
--
-- test-listed-read-blocks-batch1.lua: eight checkers (2417-jzhh batch 1) block,
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
-- Usage: tillandsias-plan script run scripts/lua/test-listed-read-blocks-batch1.lua

local fixture = require "common.fixture"
local T = fixture.new("listed-read-blocks-batch1")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local W = T:scratch("b1")

local n = 0
-- tree: { [relpath] = body }; locked: relpath inside the tree to chmod 000
local function plant(tree, locked)
    n = n + 1
    local rel, abs = W.rel .. "/t" .. n, W.abs .. "/t" .. n
    -- require resolves lib/lua from TILLANDSIAS_REPO_ROOT, so a re-rooted tree carries the module
    fs.mkdir(rel .. "/lib/lua/common"); fs.write(rel .. "/lib/lua/common/listed_read.lua", fs.read("lib/lua/common/listed_read.lua"))
    for p, body in pairs(tree) do
        fs.mkdir((rel .. "/" .. p):match("^(.*)/[^/]*$"))
        fs.write(rel .. "/" .. p, body)
    end
    T:must{ "chmod", "000", abs .. "/" .. locked }
    if pcall(fs.read, rel .. "/" .. locked) then
        T:run{ "chmod", "644", abs .. "/" .. locked }
        T:skip("could-not-plant: chmod 000 left the file readable (running as root?)")
    end
    return rel, abs
end

local function run(checker, env_)
    local r = T:run{ PLAN, "script", "run", ROOT .. "/scripts/lua/" .. checker .. ".lua", cwd = ROOT,
        env = env_, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o
end

-- one checker: red arm (blocks, names the file) and control (readable again: no block)
local function arm(checker, name, tree, locked, env_of)
    local rel, abs = plant(tree, locked)
    local rc, o = run(checker, env_of(rel, abs))
    T:arm(checker .. " blocks on an unreadable listed file", rc == 2
        and text.contains(o, "blocked:" .. name .. ":unreadable:1") and text.contains(o, locked),
        "rc=" .. tostring(rc) .. " " .. o:sub(-400):gsub("\n", " | "))
    T:run{ "chmod", "644", abs .. "/" .. locked }
    local rc2, o2 = run(checker, env_of(rel, abs))
    T:arm(checker .. " CONTROL readable again: not blocked on it", not text.contains(o2, ":unreadable:"),
        "rc=" .. tostring(rc2) .. " " .. o2:sub(-400):gsub("\n", " | "))
end

local rooted = function(_, abs) return { TILLANDSIAS_REPO_ROOT = abs } end

arm("census-litmus-pipes", "litmus-pipe-census",
    { ["openspec/litmus-tests/a.yaml"] = 'steps:\n  - command: "echo a | wc -l"\n',
      ["openspec/litmus-tests/locked.yaml"] = 'steps:\n  - command: "echo b"\n' },
    "openspec/litmus-tests/locked.yaml", rooted)

arm("check-all-fragments-intact", "all-fragments-intact",
    { ["plan/index.d/a.yaml"] = "events: []\n", ["plan/index.d/locked.yaml"] = "events: []\n" },
    "plan/index.d/locked.yaml", function(_, abs) return { TILLANDSIAS_FRAGMENT_SCAN_ROOT = abs } end)

arm("check-backgrounded-jobs-redirect-stderr", "backgrounded-stderr",
    { ["ep/entrypoint-forge-a.sh"] = "true >>/tmp/x 2>&1 &\n", ["ep/entrypoint-forge-locked.sh"] = "true\n" },
    "ep/entrypoint-forge-locked.sh", function(rel) return { TILLANDSIAS_ENTRYPOINT_GLOB = rel .. "/ep/entrypoint-forge-*.sh" } end)

arm("check-ca-path-literals", "ca-path-literals",
    { ["scripts/a.sh"] = "echo hi\n", ["scripts/locked.sh"] = "echo /tmp/tillandsias" .. "-ca\n" },
    "scripts/locked.sh", rooted)

local SHEETS = { ["cheatsheets/a.md"] = "---\ntags: [x]\n---\n# A\n", ["cheatsheets/locked.md"] = "---\ntags: [y]\n---\n# B\n" }
arm("check-cheatsheet-frontmatter", "cheatsheet-frontmatter", SHEETS, "cheatsheets/locked.md", rooted)
arm("check-cheatsheet-refs", "cheatsheet-refs", SHEETS, "cheatsheets/locked.md", rooted)
arm("check-cheatsheet-source-anchors", "cheatsheet-source-anchors", SHEETS, "cheatsheets/locked.md", rooted)

arm("check-enclave-ca-not-host-trusted", "enclave-ca-not-host-trusted",
    { ["trust/a.sh"] = "echo hi\n", ["trust/locked.sh"] = "update" .. "-ca-trust\n" },
    "trust/locked.sh", function(rel) return { TILLANDSIAS_HOST_TRUST_SCAN = rel .. "/trust" } end)

T:finish()
