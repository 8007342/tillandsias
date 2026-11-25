-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:2300-j4cv, order:2296-pn45, order:2252-ck7h, spec:ci-release
--
-- smoke-record.lua — write the smoke-record event the promote gate asks for
-- (check-promote-gate.lua), DERIVED from this run's attestation and never typed:
--
--   refs/attest/smoke/<darwin|msys|linux>/<tag commit>   (attest-smoke.lua --push)
--     -> plan/index.d/<ts>-smoke-<tag>-<platform>-<attestation>.yaml
--        event smoke-record, summary: smoke <platform> <tag> <verdict> regime=<platform>:<regime>
--
-- The verdict, host, tag, time and regime are the attestation's. It refuses a ref that names
-- another platform, sha or tag, and one origin does not hold byte for byte: an attestation
-- nobody else can read is no evidence.
-- The first record for a tag declares the row smoke-<tag>; the declaration is identical on
-- every host, so two hosts declaring it at once agree. It writes ONE fragment and pushes
-- nothing: scripts/push-plan-fragments-to-trunk.sh takes the printed path.
--
--   ok:smoke-record:<fragment path>        rc 0 (already written: same path, unchanged)
--   refused:smoke-record:<why>             rc 2, nothing written
--
-- Usage: tillandsias-plan script run scripts/lua/smoke-record.lua -- \
--   --tag <tag> [--platform darwin|msys|linux]

local function refuse(why) verdict.emit("refused:smoke-record:" .. why, 2) end
local O = {}
local i = 1
while i <= #arg do
    local a = arg[i]
    if (a == "--tag" or a == "--platform") and arg[i + 1] then O[a:sub(3)] = arg[i + 1]; i = i + 1
    else refuse("usage") end
    i = i + 1
end
if not O.tag or not O.tag:match("^v%d+%.%d+%.%d+%.%d+$") then refuse("bad-tag") end
local function run(argv)
    local r = proc.run({ argv = argv, timeout_ms = 120000 })
    return (r.status == "exited") and r.code or -1, text.trim(r.stdout or "")
end
local PLAT = O.platform
if not PLAT then
    local _, u = run({ "uname", "-s" })
    PLAT = (u == "Darwin") and "darwin" or ((u:match("^MINGW") or u:match("^MSYS")) and "msys" or "linux")
end
local NAME = ({ darwin = "darwin", linux = "linux", msys = "windows" })[PLAT]
if not NAME then refuse("bad-platform:" .. PLAT) end

-- the attestation, as origin holds it
local c, SHA = run({ "git", "rev-parse", "--verify", "--quiet", "refs/tags/" .. O.tag .. "^{commit}" })
if c ~= 0 or SHA == "" then refuse("unknown-tag:" .. O.tag) end
local REF = "refs/attest/smoke/" .. PLAT .. "/" .. SHA
local lc, LOCAL = run({ "git", "rev-parse", "--verify", "--quiet", REF })
if lc ~= 0 or LOCAL == "" then refuse("no-attestation:" .. REF) end
local oc, remote = run({ "git", "ls-remote", "origin", REF })
if oc ~= 0 then refuse("origin-unreadable") end
if (remote:match("^(%x+)") or "") ~= LOCAL then refuse("attestation-not-on-origin:" .. REF) end
local _, msg = run({ "git", "log", "-1", "--format=%B", LOCAL })
local host, v, n = nil, nil, 0
for _, l in ipairs(text.lines(msg)) do
    if l:match("^Smoke: ") then
        n = n + 1
        local h, p, s, t, vv = l:match("^Smoke: (%S+) (%S+) (%x+) (%S+) %x+ (%S+)$")
        if h and p == PLAT and s == SHA and t == O.tag then host, v = h, vv end
    end
end
if n ~= 1 or not v then refuse("attestation-is-not-this-run:" .. REF) end
if not (v == "pass" or v == "partial:credential-unmeasured" or v:match("^fail:[%w._-]+$")) then refuse("bad-verdict:" .. v) end
if not host:match("^[%w._-]+$") then refuse("bad-host") end
-- digests only (2299-atdg): a tree of any other shape is no source, and the regime is its own
local _, names = run({ "git", "ls-tree", "--name-only", LOCAL })
if names ~= "SHA256SUMS\nregime.txt\nverdict.txt" then refuse("attestation-is-not-digest-only:" .. REF) end
local _, tv = run({ "git", "show", LOCAL .. ":verdict.txt" })
if tv ~= v then refuse("attestation-disagrees-with-itself:" .. REF) end
local _, REGIME = run({ "git", "show", LOCAL .. ":regime.txt" })
if not REGIME:match("^[%w._-]+$") then refuse("bad-regime") end
local tr = proc.run({ argv = { "git", "log", "-1", "--date=format-local:%Y-%m-%dT%H:%M:%SZ", "--format=%cd", LOCAL },
    env = { TZ = "UTC" }, timeout_ms = 30000 })
local TS = text.trim(tr.stdout or "")
if not TS:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then refuse("bad-time") end

local LINE = "smoke " .. NAME .. " " .. O.tag .. " " .. v .. " regime=" .. NAME .. ":" .. REGIME
if #LINE > 100 then refuse("too-long:" .. #LINE .. ">100 (plan-events cuts it; shorten the regime or the fail slug)") end

-- the row
local PLAN = env.get("TILLANDSIAS_PLAN_BIN") or ""
if PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or "" end
if PLAN == "" then local _, top = run({ "git", "rev-parse", "--show-toplevel" }); PLAN = top .. "/target/release/tillandsias-plan" end
-- an absent binary must not read as an absent row
if run({ PLAN, "capabilities" }) ~= 0 then refuse("no-plan-binary") end
local ROW = "smoke-" .. O.tag:gsub("%.", "-")
local have = run({ PLAN, "plan-events", ROW })
local out_ = { "# Ledger fragment — append-only, IMMUTABLE once written.\n",
    "# Written by: smoke-record.lua, from " .. REF .. " " .. LOCAL .. "\n" }
if have ~= 0 then
    -- the order is derived from the tag, so every host declares the same one
    local hr = proc.run({ argv = { "git", "hash-object", "--stdin" }, stdin = ROW .. "\n", timeout_ms = 30000 })
    local hex = text.trim(hr.stdout or "")
    local ORDER
    for k = 1, 33, 4 do
        local o = "2252-" .. hex:sub(k, k + 3)
        if run({ PLAN, "plan-events", o }) ~= 0 then ORDER = o; break end
    end
    if not ORDER then refuse("no-free-order") end
    out_[#out_ + 1] = "packets:\n  - packet_id: " .. ROW .. "\n    order: \"" .. ORDER .. "\"\n    status: pending\n    kind: research\n"
        .. "    priority: p2\n    desired_release: v0.5\n    pickup_role: any\n    capability_tags: [release, smoke]\n    estimated_hours: 1\n"
        .. "    title: \"Smoke records of " .. O.tag .. ", one per platform (the promote gate reads this row)\"\n"
        .. "    context: \"The hosts that smoke " .. O.tag .. " append smoke-record events here. Not work to claim.\"\n"
        .. "    exit_criteria:\n      - \"linux, darwin and windows each have a smoke-record for " .. O.tag .. ".\"\n"
        .. "    unscoreable: \"a record row: check-promote-gate.lua is what reads it\"\n"
end
out_[#out_ + 1] = "events:\n  - packet_id: " .. ROW .. "\n    event:\n      type: smoke-record\n      ts: \"" .. TS .. "\"\n      host: " .. host
    .. "\n      summary: \"" .. LINE .. "\"\n"
    .. "  - packet_id: " .. ROW .. "\n    event:\n      type: note\n      ts: \"" .. TS .. "\"\n      host: " .. host
    .. "\n      summary: \"evidence for " .. NAME .. " " .. O.tag .. " is " .. REF .. " at " .. LOCAL .. "\"\n"
local path = "plan/index.d/" .. TS:gsub("[-:]", ""):lower() .. "-" .. ROW .. "-" .. NAME .. "-" .. LOCAL:sub(1, 8) .. ".yaml"
local body = table.concat(out_)
if fs.exists(path) then
    -- the same attestation again: the record is already written (immutable)
    if not text.contains(fs.read(path), LINE) then refuse("fragment-exists-with-another-record:" .. path) end
else fs.write(path, body) end
out.line("  " .. LINE)
verdict.ok("smoke-record", path)
