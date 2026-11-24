-- @trace order:2252-ck7h
-- @env TILLANDSIAS_SMOKE_HOST
--
-- attest-smoke.lua — record one platform's smoke run of a release candidate
-- as a ref the daily-RC promotion asks for (coordinator rulings 2026-11-22):
--
--   refs/attest/smoke/<platform>/<rc-commit-sha>
--
-- keyed by the RC's COMMIT (immutable beats readable), pointing at a commit
-- whose TREE is the smoke evidence directory and whose message carries
--
--   Smoke: <host> <platform> <rc-sha> <tag> <asset-sha256> <verdict>
--
-- A re-run on the same sha adds a commit on top (the previous one is its
-- parent), so an upgrade from partial to pass keeps its history.
--
-- VERDICTS a run may claim:
--   pass                          every step measured, including the credential step
--   partial:credential-unmeasured the operator has not signed in yet (never fake it)
--   fail:<what>                   a step failed
-- `pass` is refused unless the evidence holds credential-step.txt whose first
-- line starts `measured` — the operator's sign-in, observed, not assumed.
-- Every evidence file must be newer than 00-run-start.txt (a previous run's
-- file under the same name is not this run's result; 1189-7yvu).
--
--   ok:attest-smoke:<platform>:<sha>:<verdict>   ref written (and pushed)
--   refused:attest-smoke:<why>                   rc 2, nothing written
--
-- Usage: tillandsias-plan script run scripts/lua/attest-smoke.lua -- \
--   --sha <rc-commit> --tag <tag> --asset-sha256 <hex> --verdict <v> \
--   [--dir target/smoke-e2e] [--platform darwin] [--push]

local function refuse(why) verdict.emit("refused:attest-smoke:" .. why, 2) end

local O = { dir = "target/smoke-e2e" }
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--push" then O.push = true
    elseif a == "--sha" or a == "--tag" or a == "--asset-sha256" or a == "--verdict" or a == "--dir" or a == "--platform" then
        if arg[i + 1] == nil then refuse("usage:" .. a .. "-needs-a-value") end
        O[a:sub(3):gsub("-", "_")] = arg[i + 1]; i = i + 1
    else refuse("unknown-arg:" .. a) end
    i = i + 1
end
for _, k in ipairs({ "sha", "tag", "asset_sha256", "verdict" }) do
    if not O[k] or O[k] == "" then refuse("usage:missing-" .. k:gsub("_", "-")) end
end
if not O.sha:match("^%x+$") or #O.sha < 7 then refuse("bad-sha:" .. O.sha) end
if not O.asset_sha256:match("^%x+$") or #O.asset_sha256 ~= 64 then refuse("bad-asset-sha256") end
if not O.tag:match("^[%w._-]+$") then refuse("bad-tag:" .. O.tag) end
local V = O.verdict
if not (V == "pass" or V == "partial:credential-unmeasured" or V:match("^fail:[%w._-]+$")) then
    refuse("bad-verdict:" .. V)
end

local function run(argv, opts)
    opts = opts or {}; opts.argv = argv; opts.timeout_ms = opts.timeout_ms or 120000
    local r = proc.run(opts)
    return (r.status == "exited") and r.code or -1, text.trim(r.stdout or ""), r.stderr or ""
end

local _, ROOT = run({ "git", "rev-parse", "--show-toplevel" })
if ROOT == "" then refuse("no-repo") end
local c, SHA = run({ "git", "-C", ROOT, "rev-parse", "--verify", "--quiet", O.sha .. "^{commit}" })
if c ~= 0 or SHA == "" then refuse("unknown-sha:" .. O.sha) end

local PLATFORM = O.platform
if not PLATFORM then
    local _, u = run({ "uname", "-s" })
    PLATFORM = (u == "Darwin") and "darwin" or ((u:match("^MINGW") or u:match("^MSYS")) and "msys" or "linux")
end
if not PLATFORM:match("^[a-z]+$") then refuse("bad-platform:" .. PLATFORM) end

-- Absolute on POSIX ("/...") or Windows ("C:/...", "C:\\..."; msys, yolanda 2026-11-22).
local function absolute(p) return p:sub(1, 1) == "/" or p:match("^%a:[/\\]") ~= nil end
local DIR = absolute(O.dir) and O.dir or (ROOT .. "/" .. O.dir)
if run({ "test", "-f", DIR .. "/00-run-start.txt" }) ~= 0 then refuse("no-run-start:" .. O.dir) end
-- Evidence older than this run's start is a previous run's.
local _, stale = run({ "find", DIR, "-type", "f", "!", "-newer", DIR .. "/00-run-start.txt", "!", "-name", "00-run-start.txt" })
if stale ~= "" then refuse("stale-evidence:" .. (text.lines(stale)[1] or "?")) end
if V == "pass" then
    local cr = run({ "grep", "-q", "^measured", DIR .. "/credential-step.txt" })
    if cr ~= 0 then refuse("pass-needs-measured-credential-step") end
end

local host = env.get("TILLANDSIAS_SMOKE_HOST") or ""
if host == "" then local _, h = run({ "hostname", "-s" }); host = h:lower() end
if host == "" or host:find("%s") then refuse("no-host") end

-- The evidence dir's tree, through a throwaway index (the checkout's index is
-- never touched).
local _, GITDIR = run({ "git", "-C", ROOT, "rev-parse", "--absolute-git-dir" })
local IDX = GITDIR .. "/attest-smoke.index"
run({ "rm", "-f", IDX })
local GENV = { GIT_INDEX_FILE = IDX, GIT_WORK_TREE = DIR, GIT_DIR = GITDIR }
local ac, _, ae = run({ "git", "add", "-A", "-f", "." }, { env = GENV, cwd = DIR })
if ac ~= 0 then refuse("index-failed:" .. text.trim(ae):gsub("%s+", " ")) end
local wc, TREE = run({ "git", "write-tree" }, { env = GENV, cwd = DIR })
run({ "rm", "-f", IDX })
if wc ~= 0 or TREE == "" then refuse("write-tree-failed") end

local REF = "refs/attest/smoke/" .. PLATFORM .. "/" .. SHA
local _, prev = run({ "git", "-C", ROOT, "rev-parse", "--verify", "--quiet", REF })
local line = "Smoke: " .. host .. " " .. PLATFORM .. " " .. SHA .. " " .. O.tag .. " " .. O.asset_sha256 .. " " .. V
local argv = { "git", "-C", ROOT, "-c", "commit.gpgsign=false", "commit-tree", TREE,
               "-m", "smoke: " .. PLATFORM .. " " .. O.tag .. " " .. V .. " (" .. host .. ")", "-m", line }
if prev ~= "" then argv[#argv + 1] = "-p"; argv[#argv + 1] = prev end
-- The attestation names its own author: never the ambient identity (a gate
-- host may have no user.name/email at all; macuahuitl 2026-11-23).
local ID = "tillandsias-smoke (" .. host .. ")"
local MAIL = "smoke@" .. host .. ".invalid"
local cc, COMMIT, ce = run(argv, { env = { GIT_AUTHOR_NAME = ID, GIT_AUTHOR_EMAIL = MAIL,
    GIT_COMMITTER_NAME = ID, GIT_COMMITTER_EMAIL = MAIL } })
if cc ~= 0 or COMMIT == "" then refuse("commit-tree-failed:" .. text.trim(ce):gsub("%s+", " ")) end
if run({ "git", "-C", ROOT, "update-ref", REF, COMMIT }) ~= 0 then refuse("update-ref-failed") end
if O.push then
    if run({ "git", "-C", ROOT, "push", "-q", "origin", REF .. ":" .. REF }, { timeout_ms = 300000 }) ~= 0 then
        refuse("push-failed:" .. REF)
    end
end
verdict.ok("attest-smoke", PLATFORM .. ":" .. SHA .. ":" .. V)
