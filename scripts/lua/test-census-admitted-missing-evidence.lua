-- @env PATH HOME
-- @trace spec:ci-release, order:1349-tdpg, order:2320-b5vv
--
-- test-census-admitted-missing-evidence.lua — the positive control of the evidence-debt
-- census. Ported from the .sh of the same name (2320-b5vv); same eight arms. A count is the
-- least self-announcing result there is, so this plants one dated admission beside a decoy
-- that uses the same words and must not be counted, then shows the count move. Scratch repos
-- with dated commits: the ages come from git blame.
--
-- Usage: tillandsias-plan script run scripts/lua/test-census-admitted-missing-evidence.lua
-- Verdict: ok:census-admitted-missing-evidence:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("census-admitted-missing-evidence")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local ADMISSION = [==[
/// The page size for the menu.
///
/// Nobody has yet measured a real repo count against a real screen, so it
/// stays at 10 until someone does.
pub const MAX_ITEMS: usize = 10;
]==]
local DECOY = [==[
/// We measured this against three screens before choosing it, and someone
/// verified the result independently. Nothing here is assumed.
pub const ROWS: usize = 24;
]==]
local SECOND = [==[
// TODO: this threshold is assumed, not measured; nobody has checked it
// against a real workload yet.
pub const LIMIT: usize = 64;
]==]
local function commit(d, files, days)
    fs.mkdir(d.rel .. "/src")
    for f, body in pairs(files) do fs.write(d.rel .. "/src/" .. f, body) end
    T:must{ "git", "-C", d.abs, "add", "-A" }
    local at = math.floor(time.now_ms() / 1000) - days * 86400 - 3600
    T:must{ "git", "-C", d.abs, "commit", "-q", "--date=@" .. string.format("%d", at), "-m", "fixture" }
end
local function census(d)
    local r = T:run{ SH, ROOT .. "/scripts/census-admitted-missing-evidence.sh", "--root", d.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = (r.stdout or ""):gsub("\r", "")
    local ages = {}
    for a in ("\n" .. o):gmatch("\n(%d+)d%s") do ages[#ages + 1] = a end
    local n, old = o:match("ok:admitted%-missing%-evidence:(%d+) hits, oldest (%d+)d")
    return { n = n, old = old, out = o, rc = r.code, ages = table.concat(ages, ","), why = "rc=" .. tostring(r.code) .. " " .. o .. (r.stderr or "") }
end

local a = T:git_repo()
commit(a, { ["capped.rs"] = ADMISSION, ["plain.rs"] = DECOY }, 100)
local c = census(a)
T:arm("1a exactly the admission is counted", c.n == "1", c.why)
T:arm("1b it names the file holding it", text.contains(c.out, "src/capped.rs"), c.why)
T:arm("1c the decoy is not counted", c.n ~= nil and not text.contains(c.out, "src/plain.rs"), c.why)
T:arm("2 the age is the commit's, from blame", c.old == "100", c.why)
local b = T:git_repo()
commit(b, { ["plain.rs"] = DECOY }, 100)
local z = census(b)
T:arm("3 CONTROL a tree with no admission counts zero and still answers", z.n == "0", z.why)
T:arm("4 it is a report, never a gate: exit 0 with hits", c.rc == 0 and c.n == "1", c.why)
commit(a, { ["second.rs"] = SECOND }, 30)
c = census(a)
T:arm("5 a second admission moves the count to 2", c.n == "2", c.why)
T:arm("6 the listing is oldest first", c.ages == "100,30" and c.old == "100", c.ages .. " " .. c.why)
T:finish()
