-- @trace order:2417-jzhh, order:2416-pscn
--
-- test-listed-read-blocks-batch2.lua: nine checkers (2417-jzhh batch 2) block,
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
-- Usage: tillandsias-plan script run scripts/lua/test-listed-read-blocks-batch2.lua

local fixture = require "common.fixture"
local T = fixture.new("listed-read-blocks-batch2")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local W = T:scratch("b2")

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
local function seam(var, sub) return function(_, abs) return { [var] = abs .. (sub or "") } end end

arm("check-enclave-expect-none-is-fixture-only", "expect-none-fixture-only",
    { ["scripts/a.sh"] = "echo hi\n", ["scripts/locked.sh"] = "run --expect" .. " none\n" },
    "scripts/locked.sh", seam("TILLANDSIAS_EXPECT_NONE_SCAN_ROOT"))

arm("check-enclave-membership-documented", "enclave-membership",
    { ["spec.md"] = "# spec\n", ["src/a.rs"] = "fn x() {}\n", ["src/locked.rs"] = "fn build_y() {}\n" },
    "src/locked.rs", function(_, abs) return { TILLANDSIAS_ENCLAVE_SPEC = abs .. "/spec.md", TILLANDSIAS_ENCLAVE_SRC_ROOT = abs .. "/src" } end)

arm("check-exec-argv-vector-workarounds", "exec-argv",
    { ["src/a.rs"] = "fn x() {}\n", ["src/locked.rs"] = "fn y() {}\n" },
    "src/locked.rs", seam("TILLANDSIAS_EXEC_ARGV_SCAN_ROOT", "/src"))

local IMG = { ["img/Containerfile.base"] = "FROM x\n", ["img/Containerfile"] = "FROM y\n",
    ["src/a.rs"] = "fn x() {}\n", ["src/locked.rs"] = "fn y() {}\n" }
arm("check-forge-image-no-secrets", "forge-image-no-secrets", IMG, "src/locked.rs",
    function(_, abs) return { TILLANDSIAS_FORGE_IMAGE_DIR = abs .. "/img", TILLANDSIAS_LAUNCHER_SRC_DIR = abs .. "/src" } end)

local BROWSER = { ["cf/a"] = "FROM x\n", ["cf/locked"] = "FROM y\n", ["docs/a.md"] = "# a\n", ["docs/locked.md"] = "# b\n" }
local function browser_env(_, abs)
    return { TILLANDSIAS_BROWSER_CLAIM_DOCS = abs .. "/docs", TILLANDSIAS_BROWSER_CLAIM_CONTAINERFILES = abs .. "/cf/a " .. abs .. "/cf/locked" }
end
arm("check-forge-skill-browser-claims-match-image", "forge-browser-claims", BROWSER, "cf/locked", browser_env)
arm("check-forge-skill-browser-claims-match-image", "forge-browser-claims", BROWSER, "docs/locked.md", browser_env)

local FRAGS = { ["plan/index.d/a.yaml"] = "events: []\n", ["plan/index.d/locked.yaml"] = "events: []\n" }
arm("check-fragment-keys-are-read", "fragment-keys-are-read", FRAGS, "plan/index.d/locked.yaml", seam("TILLANDSIAS_FRAGMENT_DIR", "/plan/index.d"))
arm("check-fragment-status-loss", "fragment-status-loss", FRAGS, "plan/index.d/locked.yaml",
    function(_, abs) return { TILLANDSIAS_REPO_ROOT = abs, TILLANDSIAS_PLAN_BIN = PLAN } end)

arm("check-framing-raw-decodes", "framing-ratchet",
    { ["scripts/framing-raw-decode-baseline.tsv"] = "# none\n", ["crates/a.rs"] = "fn x() {}\n", ["crates/locked.rs"] = "fn y() {}\n" },
    "crates/locked.rs", rooted)

arm("check-grep-patterns-compile", "grep-patterns-compile",
    { ["scripts/a.sh"] = "grep -q 'a' x\n", ["scripts/locked.sh"] = "grep -q 'b' y\n" },
    "scripts/locked.sh", seam("TILLANDSIAS_GREP_SCAN_ROOT"))

T:finish()
