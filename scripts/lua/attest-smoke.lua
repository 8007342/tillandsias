-- @trace order:2252-ck7h
-- @env TILLANDSIAS_SMOKE_HOST TILLANDSIAS_SCRIPT_RUNNER_BIN TILLANDSIAS_PLAN_BIN
--
-- attest-smoke.lua — record one platform's smoke run of a release candidate
-- as a ref the daily-RC promotion asks for (coordinator rulings 2026-11-22):
--
--   refs/attest/smoke/<platform>/<rc-commit-sha>
--
-- keyed by the RC's COMMIT (immutable beats readable), pointing at a commit
-- whose message carries
--
--   Smoke: <host> <platform> <rc-sha> <tag> <asset-sha256> <verdict>
--
-- and whose TREE IS DIGESTS ONLY (2299-atdg, coordinator ruling 2026-11-24):
--   SHA256SUMS   "<sha256>  <relative path>" per evidence file
--   verdict.txt  the verdict, one line
--   regime.txt   the regime slug, one line ([%w._-]+; --regime, else the platform)
-- The raw evidence NEVER enters the object store: lane and init logs can
-- carry a sign-in URL or a token, and a pushed secret is not undone by
-- deleting the ref. The logs stay on the host, provable by their digests.
-- It used to commit the evidence directory itself as the tree.
--
-- A re-run on the same sha adds a commit on top (the previous one is its
-- parent), so an upgrade from partial to pass keeps its history. A parent
-- chain holding ANY other tree shape is refused (raw-tree-in-history): an
-- old raw-tree attest would otherwise ride along as an ancestor on --push.
-- The skill archives previous rounds INSIDE the evidence dir
-- (_archived-<ts>/); those are neither judged stale nor digested.
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
--   [--dir target/smoke-e2e] [--platform darwin] [--regime <slug>] [--push]

local function refuse(why) verdict.emit("refused:attest-smoke:" .. why, 2) end

local O = { dir = "target/smoke-e2e" }
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--push" then O.push = true
    elseif a == "--sha" or a == "--tag" or a == "--asset-sha256" or a == "--verdict" or a == "--dir" or a == "--platform"
        or a == "--regime" then
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
local REGIME = O.regime or PLATFORM
if not REGIME:match("^[%w._-]+$") then refuse("bad-regime") end

-- Absolute on POSIX ("/...") or Windows ("C:/...", "C:\\..."; msys, yolanda 2026-11-22).
local function absolute(p) return p:sub(1, 1) == "/" or p:match("^%a:[/\\]") ~= nil end
local DIR = absolute(O.dir) and O.dir or (ROOT .. "/" .. O.dir)
if run({ "test", "-f", DIR .. "/00-run-start.txt" }) ~= 0 then refuse("no-run-start:" .. O.dir) end
-- THIS ROUND's evidence: every file under DIR except the rounds the skill has
-- archived inside it (_archived-<ts>/, at the top). Those are older by design;
-- judging them stale refused every host's second round.
local fc, flist = run({ "find", DIR, "-path", DIR .. "/_archived-*", "-prune", "-o", "-type", "f", "-print" })
if fc ~= 0 then refuse("cannot-list-evidence") end
local FILES = {}
for _, p in ipairs(text.lines(flist)) do
    if p ~= "" then
        local rel = p:sub(#DIR + 2)
        -- A file NAME can leak too. Refuse rather than echo it.
        if not rel:match("^[%w._/-]+$") then refuse("unsafe-evidence-name:rename-it-to-[A-Za-z0-9._/-]") end
        FILES[#FILES + 1] = rel
    end
end
table.sort(FILES)
-- Evidence older than this run's start is a previous run's.
local _, stale = run({ "find", DIR, "-path", DIR .. "/_archived-*", "-prune", "-o",
    "-type", "f", "!", "-newer", DIR .. "/00-run-start.txt", "!", "-name", "00-run-start.txt", "-print" })
if stale ~= "" then
    local first = (text.lines(stale)[1] or "?"):sub(#DIR + 2)
    refuse("stale-evidence:" .. (first:match("^[%w._/-]+$") and first or "unsafe-name"))
end
if V == "pass" then
    local cr = run({ "grep", "-q", "^measured", DIR .. "/credential-step.txt" })
    if cr ~= 0 then refuse("pass-needs-measured-credential-step") end
end

local host = env.get("TILLANDSIAS_SMOKE_HOST") or ""
if host == "" then local _, h = run({ "hostname", "-s" }); host = h:lower() end
if host == "" or host:find("%s") then refuse("no-host") end

-- DIGESTS ONLY (2299-atdg). sha256 through the plan binary, so no host tool is
-- assumed (msys has no shasum). The runner names itself in neither variable
-- when called by hand, so the checkout's own build is the fallback.
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or env.get("TILLANDSIAS_PLAN_BIN") or ""
if PLAN == "" then PLAN = ROOT .. "/target/release/tillandsias-plan" end
if run({ "test", "-x", PLAN }) ~= 0 and run({ "test", "-x", PLAN .. ".exe" }) ~= 0 then
    refuse("no-plan-binary-for-sha256:cargo-build--release--p-tillandsias-plan")
end
local sums = {}
for _, rel in ipairs(FILES) do
    local hc, h = run({ PLAN, "hash", "sha256", DIR .. "/" .. rel })
    h = (h or ""):match("^(%x+)")
    if hc ~= 0 or not h or #h ~= 64 then refuse("sha256-failed:" .. rel) end
    sums[#sums + 1] = h .. "  " .. rel
end
-- Each blob is written from a string this script composed; nothing from the
-- evidence dir's CONTENTS is stored. verdict.txt is the validated verdict,
-- never credential-step.txt's free text.
local function blob(content)
    local bc, id = run({ "git", "-C", ROOT, "hash-object", "-w", "--stdin" }, { stdin = content })
    if bc ~= 0 or not id:match("^%x+$") then refuse("hash-object-failed") end
    return id
end
local entries = {
    "100644 blob " .. blob(table.concat(sums, "\n") .. "\n") .. "\tSHA256SUMS",
    "100644 blob " .. blob(REGIME .. "\n") .. "\tregime.txt",
    "100644 blob " .. blob(V .. "\n") .. "\tverdict.txt",
}
local mc, TREE = run({ "git", "-C", ROOT, "mktree" }, { stdin = table.concat(entries, "\n") .. "\n" })
if mc ~= 0 or not TREE:match("^%x+$") then refuse("mktree-failed") end

local REF = "refs/attest/smoke/" .. PLATFORM .. "/" .. SHA
local _, prev = run({ "git", "-C", ROOT, "rev-parse", "--verify", "--quiet", REF })
-- An old raw-tree attest in the chain would be pushed as an ancestor. Refuse,
-- naming the commit; the remedy is to delete that LOCAL ref, never to push it.
if prev ~= "" then
    local _, chain = run({ "git", "-C", ROOT, "rev-list", prev })
    for _, cm in ipairs(text.lines(chain)) do
        if cm ~= "" then
            local _, names = run({ "git", "-C", ROOT, "ls-tree", "--name-only", cm })
            if names ~= "SHA256SUMS\nregime.txt\nverdict.txt" then
                refuse("raw-tree-in-history:" .. cm:sub(1, 12) .. ":delete-the-local-ref:git-update-ref--d-" .. REF)
            end
        end
    end
end
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
