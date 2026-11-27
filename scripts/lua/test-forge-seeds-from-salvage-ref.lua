-- @trace order:1350-8hmy, order:2342-9f4k
--
-- test-forge-seeds-from-salvage-ref.lua — a forge seeded from a salvage/* ref
-- CONTAINS that ref's content. checkout_forge_seed_branch() is fail-soft by contract
-- (B6): a seed that is missing or that `git switch` refuses leaves the clone on its
-- own HEAD, WARNS and returns 0, so no failure shows in $?. The assertion is a file
-- on the salvage ref read back out of the seeded tree. The real function is cut from
-- images/default/lib-common.sh; a bare repository stands in for the mirror. Ported
-- from the .sh (2342-9f4k).
--
--   1 PREMISE a fresh clone is on trunk WITHOUT the sentinel (else 2 is free)
--   2 the seeded tree holds the sentinel, content compared
--   3 HEAD is the slashed ref itself, by name
--   4 a never-pushed seed stays on trunk, warns, returns 0 (B6)
--   5 an empty seed is a silent no-op
--
-- Verdict: ok:forge-seeds-from-salvage-ref:5/5 | blocked:forge-seeds-from-salvage-ref:<n>-failed-of-5

local fixture = require "common.fixture"
local T = fixture.new("forge-seeds-from-salvage-ref")
local SH = fixture.posix_shell()
local W = T:scratch()
local TOKEN = "salvage-sentinel-1350-8hmy-" .. tostring(time.now_ms())
local SALVAGE, TRUNK = "salvage/1350-8hmy-rescue", "linux-next"

local fn = ("\n" .. fs.read("images/default/lib-common.sh")):match("\n(checkout_forge_seed_branch%(%) {.-\n}\n)")
if not fn then T:refuse("no-subject", "checkout_forge_seed_branch is not in images/default/lib-common.sh") end
fs.write(W.rel .. "/seed.sh", "trace_lifecycle() { :; }\n" .. fn .. "checkout_forge_seed_branch\n")

local function git(dir, ...) return (text.trim(T:must{ "git", "-C", dir, ... }.stdout or "")) end
local function ident(dir)
    git(dir, "config", "user.email", "f@example.invalid"); git(dir, "config", "user.name", "f"); git(dir, "config", "commit.gpgsign", "false")
end
local src = W.abs .. "/seedsrc"
T:must{ "git", "init", "-q", "-b", TRUNK, src }
ident(src)
fs.write(W.rel .. "/seedsrc/trunk.txt", "trunk\n")
git(src, "add", "-A"); git(src, "commit", "-qm", "trunk")
git(src, "checkout", "-q", "-b", SALVAGE)
fs.write(W.rel .. "/seedsrc/SENTINEL.txt", TOKEN .. "\n")
git(src, "add", "-A"); git(src, "commit", "-qm", "salvage: the rescued work")
git(src, "checkout", "-q", TRUNK)
T:must{ "git", "clone", "-q", "--bare", src, W.abs .. "/mirror.git" }
git(W.abs .. "/mirror.git", "symbolic-ref", "HEAD", "refs/heads/" .. TRUNK)

local function clone(name)
    T:must{ "git", "clone", "-q", W.abs .. "/mirror.git", W.abs .. "/" .. name }
    ident(W.abs .. "/" .. name)
    return { abs = W.abs .. "/" .. name, rel = W.rel .. "/" .. name }
end
local function head(d)
    local r = T:run{ "git", "-C", d.abs, "symbolic-ref", "--short", "-q", "HEAD" }
    return r.code == 0 and text.trim(r.stdout or "") or "<detached>"
end
local function seed(d, ref)
    local r = T:run{ SH, W.abs .. "/seed.sh", cwd = d.abs, env = { TILLANDSIAS_FORGE_SEED_BRANCH = ref }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end

local a = clone("c1")
T:arm("1 PREMISE a fresh clone is on trunk without the sentinel", head(a) == TRUNK and not fs.exists(a.rel .. "/SENTINEL.txt"), "head=" .. head(a))
local c, o = seed(a, SALVAGE)
local got = fs.exists(a.rel .. "/SENTINEL.txt") and text.trim(fs.read(a.rel .. "/SENTINEL.txt")) or "<absent>"
T:arm("2 a forge seeded from a salvage/* ref contains that ref's content", got == TOKEN, "SENTINEL=" .. got .. " rc=" .. tostring(c) .. " " .. o)
T:arm("3 HEAD is the slashed ref itself", head(a) == SALVAGE, head(a))
local b = clone("c4")
c, o = seed(b, "salvage/never-pushed-9999-zzzz")
T:arm("4 a never-pushed seed stays on trunk, warns, returns 0", c == 0 and head(b) == TRUNK and o:find("WARNING", 1, true) ~= nil,
    "rc=" .. tostring(c) .. " head=" .. head(b) .. " out=" .. o)
local e = clone("c5")
c, o = seed(e, "")
T:arm("5 an empty seed is a silent no-op", c == 0 and head(e) == TRUNK and o == "", "rc=" .. tostring(c) .. " head=" .. head(e) .. " out=" .. o)
local n = T.passed + #T.failed
T:finish({ ok = function(k) return "ok:forge-seeds-from-salvage-ref:" .. k .. "/" .. n end,
    fail = function(f) return "blocked:forge-seeds-from-salvage-ref:" .. f .. "-failed-of-" .. n end })
