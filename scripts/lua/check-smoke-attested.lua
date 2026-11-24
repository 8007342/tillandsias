-- @trace order:2252-ck7h
--
-- check-smoke-attested.lua — may this release candidate be promoted? Only if
-- EVERY named platform has a smoke attestation ref for its commit whose
-- verdict is exactly `pass` (standing rule: a PASS per platform before main).
-- A partial (partial:credential-unmeasured) or a fail does NOT count: it
-- blocks until a re-run on the same sha upgrades the ref.
--
--   refs/attest/smoke/<platform>/<rc-commit-sha>    (written by attest-smoke.lua)
--
--   ok:smoke-attested:<sha>:<p1>,<p2>...                     rc 0
--   refused:smoke-attested:<sha>:<p>=missing|<verdict>[ ...] rc 1
--   refused:smoke-attested:usage|unknown-rc:<x>              rc 2
--
-- A ref counts only if its message's Smoke: line names the same platform and
-- the same sha (a ref copied under another name is not that run).
--
-- Usage: tillandsias-plan script run scripts/lua/check-smoke-attested.lua -- \
--   (--sha <rc-commit> | --version <tag>) [--platforms darwin,msys,linux]

local function usage(why) verdict.emit("refused:smoke-attested:" .. why, 2) end
local O = { platforms = "darwin,msys,linux" }
local i = 1
while i <= #arg do
    local a = arg[i]
    if (a == "--sha" or a == "--version" or a == "--platforms") and arg[i + 1] then
        O[a:sub(3)] = arg[i + 1]; i = i + 1
    else usage("usage") end
    i = i + 1
end
local want = O.sha or O.version
if not want or (O.sha and O.version) then usage("usage") end
if not want:match("^[%w._/-]+$") or want:sub(1, 1) == "-" then usage("usage") end

local function run(argv)
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    return (r.status == "exited") and r.code or -1, text.trim(r.stdout or "")
end
local _, ROOT = run({ "git", "rev-parse", "--show-toplevel" })
local c, SHA = run({ "git", "-C", ROOT, "rev-parse", "--verify", "--quiet", want .. "^{commit}" })
if c ~= 0 or SHA == "" then usage("unknown-rc:" .. want) end

local ok, bad = {}, {}
for p in O.platforms:gmatch("[^,]+") do
    local REF = "refs/attest/smoke/" .. p .. "/" .. SHA
    local rc, msg = run({ "git", "-C", ROOT, "log", "-1", "--format=%B", REF, "--" })
    local v = nil
    if rc == 0 then
        for _, l in ipairs(text.lines(msg)) do
            local hp, hs, hv = l:match("^Smoke: %S+ (%S+) (%x+) %S+ %x+ (%S+)$")
            if hp == p and hs == SHA then v = hv end
        end
    end
    if v == "pass" then ok[#ok + 1] = p
    else bad[#bad + 1] = p .. "=" .. (v or "missing") end
end
if #bad > 0 then
    out.line("  why: promotion needs a PASS per platform; a partial or a missing run blocks it")
    verdict.emit("refused:smoke-attested:" .. SHA .. ":" .. table.concat(bad, " "), 1)
end
verdict.ok("smoke-attested", SHA .. ":" .. table.concat(ok, ","))
