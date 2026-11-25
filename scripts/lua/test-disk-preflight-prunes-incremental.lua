-- @env PATH HOME
-- @trace order:2329-9etw, order:1878-2cwt
--
-- test-disk-preflight-prunes-incremental.lua — the disk-preflight VERB on a scratch cargo
-- target and a scratch repo. The pruning rule itself (oldest first, stop at the floor, locks,
-- symlinks) is in the crate's unit tests, where free space can be simulated; here the floor is
-- set out of reach, or at zero, so the real filesystem decides nothing.
--
--   1 below the floor every session goes, the line names the bytes, deps/ and build/ stay
--   2 the verdict is still refused:disk-low when pruning cannot reach the floor
--   3 CONTROL above the floor nothing is pruned and the verdict is ok
--   4 --dry-run removes nothing and says would-prune
--   5 --no-worktrees evicts no worktree, however low
--   6 the default cargo target is the caller's CARGO_TARGET_DIR
--
-- Usage: tillandsias-plan script run scripts/lua/test-disk-preflight-prunes-incremental.lua
-- Verdict: ok:disk-preflight-prunes-incremental:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("disk-preflight-prunes-incremental")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
-- Free space is not read off unix: the verb then fails closed before any of this.
if fixture.posix_shell() ~= "bash" then T:skip("free-space-unread-on-this-host") end
local UNREACHABLE = "100000000"

local function world()
    local repo, t = T:git_repo(), T:scratch("target")
    -- The binary loads the ledger in its cwd before any verb.
    fs.mkdir(repo.rel .. "/plan"); fs.write(repo.rel .. "/plan/index.yaml", "packets: []\n")
    for _, p in ipairs{ "debug/deps", "debug/build", "debug/incremental/a-1/s-x", "debug/incremental/b-2/s-x" } do fs.mkdir(t.rel .. "/" .. p) end
    fs.write(t.rel .. "/debug/deps/lib.rlib", ("d"):rep(5000)); fs.write(t.rel .. "/debug/build/out", ("b"):rep(5000))
    for _, s in ipairs{ "a-1", "b-2" } do fs.write(t.rel .. "/debug/incremental/" .. s .. "/s-x/q.bin", ("i"):rep(1500)) end
    local function kept() return fs.read(t.rel .. "/debug/deps/lib.rlib") == ("d"):rep(5000) and fs.read(t.rel .. "/debug/build/out") == ("b"):rep(5000) end
    local function sessions()
        local n = 0
        for _, s in ipairs{ "a-1", "b-2" } do if fs.exists(t.rel .. "/debug/incremental/" .. s) then n = n + 1 end end
        return n
    end
    return { repo = repo, t = t, kept = kept, sessions = sessions }
end
local function run(w, ctd, ...)
    local r = proc.run{ argv = { PLAN, "disk-preflight", "--repo", w.repo.abs, ... }, cwd = w.repo.abs, timeout_ms = 60000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), CARGO_TARGET_DIR = ctd }, env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" } }
    local o = r.stdout or ""
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o .. (r.stderr or "")
end
local function pruned(w, o) return text.contains("\n" .. o, "\npruned:incremental:" .. w.t.abs .. "/debug/incremental:dirs=2:freed=3000\n") end
local function last(o) return text.trim(o):match("([^\n]*)$") end

local w = world()
local rc, o, why = run(w, nil, "--cargo-target", w.t.abs, "--floor-gib", UNREACHABLE, "--no-worktrees")
T:arm("1 below the floor every session goes, the bytes are named, and deps/ and build/ stay", pruned(w, o) and w.sessions() == 0 and w.kept(), why)
T:arm("2 pruning that cannot reach the floor is still refused:disk-low", rc == 1 and last(o):sub(1, 17) == "refused:disk-low:", why)
w = world()
rc, o, why = run(w, nil, "--cargo-target", w.t.abs, "--floor-gib", "0", "--no-worktrees")
T:arm("3 CONTROL above the floor nothing is pruned", rc == 0 and w.sessions() == 2 and not text.contains(o, "pruned:") and not text.contains(o, "kept:") and last(o):sub(1, 18) == "ok:disk-preflight:", why)
rc, o, why = run(w, nil, "--cargo-target", w.t.abs, "--floor-gib", UNREACHABLE, "--no-worktrees", "--dry-run")
T:arm("4 --dry-run removes nothing and says would-prune", w.sessions() == 2 and text.contains(o, "would-prune:incremental:") and text.contains(o, "dirs=2:bytes=3000"), why)
local bare, wt = T:scratch("origin"), w.t.abs .. "/wt"
T:must{ "git", "init", "-q", "--bare", bare.abs }
T:must{ "git", "-C", w.repo.abs, "remote", "add", "origin", bare.abs }
T:must{ "git", "-C", w.repo.abs, "push", "-q", "origin", "main" }
T:must{ "git", "-C", w.repo.abs, "worktree", "add", "-q", "--detach", wt, "origin/main" }
run(w, nil, "--cargo-target", w.t.abs, "--floor-gib", UNREACHABLE, "--no-worktrees")
local stayed = fs.exists(w.t.rel .. "/wt/README")
rc, o, why = run(w, nil, "--cargo-target", w.t.abs, "--floor-gib", UNREACHABLE)
T:arm("5 --no-worktrees evicts none, and without it the clean pushed one goes", stayed and not fs.exists(w.t.rel .. "/wt/README"), tostring(stayed) .. " " .. why)
w = world()
rc, o, why = run(w, w.t.abs, "--floor-gib", UNREACHABLE, "--no-worktrees")
T:arm("6 the default cargo target is CARGO_TARGET_DIR", pruned(w, o) and w.sessions() == 0 and w.kept(), why)
T:finish()
