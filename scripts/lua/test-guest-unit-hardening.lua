-- @trace order:2262-bke7, order:309
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-guest-unit-hardening.lua — scripts/lua/check-guest-unit-hardening.lua (order
-- 309, criterion 3), on COPIES of the two files it inspects. Ported from the .sh.
--   1 LIVE     today's tree passes: the units are unconfined
--   2 REGRESS  order 308's exact directives are refused in EACH shipped unit.
--              PRE-FIX: only vz.rs's was read (740-3k4s hoisted wsl.rs's).
--   3 DRIFT    a unit it cannot find fails CLOSED and is named, for EACH file,
--              the others still present.  PRE-FIX: one found file excused the rest.
--   4 COMMENT  naming a directive in a comment is not confinement
--
-- Verdict: ok:guest-unit-hardening-fixture:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("guest-unit-hardening-fixture")
local ROOT = fixture.repo_root()
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not PLAN or PLAN == "" then PLAN = fixture.plan_binary() end
if PLAN == "" then verdict.could_not_run("guest-unit-hardening-fixture", "no plan binary") end
local FILES = {
    "crates/tillandsias-vm-layer/src/vz.rs", "crates/tillandsias-vm-layer/src/wsl.rs",
    "crates/tillandsias-windows-tray/src/wsl_lifecycle.rs", "images/vm/bootstrap/20-tillandsias.sh",
}
local LIVE = {}
for _, f in ipairs(FILES) do LIVE[f] = fs.read(f) end
local EXEC = "ExecStart=/usr/local/bin/tillandsias-headless"
local W = T:scratch()
local n = 0
-- check(file, body): the checker over a copy of all four, one replaced.
local function check(file, body)
    local root = ROOT
    if file then
        n = n + 1
        local rel = W.rel .. "/t" .. n
        for _, f in ipairs(FILES) do
            fs.mkdir(rel .. "/" .. f:match("^(.*)/[^/]+$"))
            fs.write(rel .. "/" .. f, f == file and body or LIVE[f])
        end
        root = W.abs .. "/t" .. n
    end
    local r = proc.run{ argv = { PLAN, "script", "run", "scripts/lua/check-guest-unit-hardening.lua" }, cwd = ROOT,
        env = { TILLANDSIAS_GUEST_UNIT_ROOT = root }, timeout_ms = 60000 }
    return text.trim(r.stdout or ""), r.code
end
-- Insert lines above the first ExecStart, in that line's own form.
local function inject(src, ...)
    local out, done = {}, false
    for _, l in ipairs(text.lines(src)) do
        local at = not done and l:find(EXEC, 1, true)
        if at then
            done = true
            local pre = l:match("^(%s*)") or ""
            local post = l:match("\\n\\$") or ""
            for _, d in ipairs({ ... }) do out[#out + 1] = pre .. d .. post end
        end
        out[#out + 1] = l
    end
    return table.concat(out, "\n") .. "\n", done
end
local function starts(s, p) return s:sub(1, #p) == p end

local o, rc = check()
T:arm("1 LIVE the live tree passes", starts(o, "ok:guest-unit-unconfined") and rc == 0, o .. " rc=" .. tostring(rc))
for _, f in ipairs(FILES) do
    local body, done = inject(LIVE[f], "NoNewPrivileges=yes", "CapabilityBoundingSet=CAP_NET_BIND_SERVICE")
    o, rc = check(f, body)
    T:arm("2 REGRESS order 308's directives are refused in " .. f, done and starts(o, "blocked:guest-unit-hardened:") and rc == 1,
        "injected=" .. tostring(done) .. " " .. o .. " rc=" .. tostring(rc))
    o, rc = check(f, (LIVE[f]:gsub("ExecStart=/usr/local/bin/tillandsias%-headless", "ExecStart=/usr/local/bin/renamed")))
    T:arm("3 DRIFT a unit it cannot find fails closed and is named: " .. f, o == "blocked:guest-unit-not-found:" .. f and rc == 1, o .. " rc=" .. tostring(rc))
end
local sh = "images/vm/bootstrap/20-tillandsias.sh"
o, rc = check(sh, (inject(LIVE[sh], "# NoNewPrivileges would wedge podman")))
T:arm("4 COMMENT a directive named in a comment is not confinement", starts(o, "ok:guest-unit-unconfined") and rc == 0, o)
T:finish()
