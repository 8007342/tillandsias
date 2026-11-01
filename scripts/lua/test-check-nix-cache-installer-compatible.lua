-- @trace order:1933-ysbq
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-check-nix-cache-installer-compatible.lua — the cache-nix-action installer
-- check on constructed workflow dirs, then on this repository's workflows:
--   1 BAD      nix-installer-action beside cache-nix-action is refused
--   2 GOOD     cachix/install-nix-action beside cache-nix-action passes
--   3 NOCACHE  a workflow without cache-nix-action is not judged
--   4 EMPTY    a dir with no workflows is could-not-run (exit 3)
--   5 REPO     .github/workflows passes
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-nix-cache-installer-compatible.lua

local SUBJECT = "scripts/lua/check-nix-cache-installer-compatible.lua"
if not fs.exists(SUBJECT) then
    verdict.emit("violation:nix-cache-installer-fixture:no-subject", 1, SUBJECT .. " does not exist (1933-ysbq)")
end
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("nix-cache-installer-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("nix-cache-installer-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/nix-cache-installer-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
local function dir_with(name, body)
    local d = REL .. "/" .. name
    fs.mkdir(d)
    if body then fs.write(d .. "/wf.yml", body) end
    return d
end
local function run(d)
    local env_ = {}
    if d then env_.TILLANDSIAS_NIX_CACHE_WORKFLOW_DIR = d end
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT }, cwd = ROOT, timeout_ms = 60000, env = env_ })
    return r.code or -1, text.trim((r.stdout or "") .. " " .. (r.stderr or ""))
end

local rc, o = run(dir_with("bad", "      - uses: DeterminateSystems/nix-installer-action@abc # v22\n      - uses: nix-community/cache-nix-action@v7\n"))
arm("1 BAD nix-installer-action beside cache-nix-action is refused", rc == 1 and o:find("violation:nix-cache-installer:1", 1, true) ~= nil, rc .. " " .. o)
rc, o = run(dir_with("good", "      - uses: cachix/install-nix-action@abc # v31\n      - uses: nix-community/cache-nix-action@v7\n"))
arm("2 GOOD cachix/install-nix-action passes", rc == 0 and o:find("judged=1", 1, true) ~= nil, rc .. " " .. o)
rc, o = run(dir_with("nocache", "      - uses: DeterminateSystems/nix-installer-action@abc\n"))
arm("3 NOCACHE a workflow without cache-nix-action is not judged", rc == 0 and o:find("judged=0", 1, true) ~= nil, rc .. " " .. o)
rc, o = run(dir_with("empty", nil))
arm("4 EMPTY no workflows is could-not-run", rc == 3, rc .. " " .. o)
rc, o = run(nil)
arm("5 REPO this repository's workflows pass", rc == 0, rc .. " " .. o)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:nix-cache-installer-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("nix-cache-installer-fixture", "5 arms")
