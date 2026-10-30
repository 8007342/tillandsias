-- @trace order:1921-h4gv
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-model-licence-register.lua — the register check refuses what a shipped
-- product may not fetch, each with its own reason, and passes what it may.
-- A scratch register holds one row per model named in the 1921-h4gv exit
-- criteria (licence ids as read on their cards, 2026-10-28):
--   REFUSED  FLUX.1-dev, SD3.5-large, RMBG-2.0, AudioLDM2,
--            stable-audio-open-1.0, gemma-3-4b-it, Qwen2.5-VL-3B, an unknown
--            licence, a gated apache-2.0 repo, an unpinned revision
--   PASSED   Qwen3-VL-4B, BiRefNet, SDXS, music-medium-800k
-- and the live register is checked as it stands.
--
-- Usage: tillandsias-plan script run scripts/lua/test-model-licence-register.lua [-- --plan <bin>]

local CHECK_REL = "scripts/lua/check-model-licence-register.lua"
local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then PLAN = "tillandsias-plan" end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 60000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("model-licence-register-fixture", "not inside a git checkout") end
local REL = "target/plan-scratch/model-licence-register-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local REV = string.rep("a", 40)
local SHA = string.rep("b", 64)
local rows = {
    -- name, spdx, gated, revision, expected reason (nil = passes)
    { "FLUX.1-dev", "flux-1-dev-non-commercial-license", "auto", REV, "non-commercial:flux-1-dev-non-commercial-license" },
    { "SD3.5-large", "stabilityai-ai-community", "auto", REV, "revenue-capped:stabilityai-ai-community" },
    { "RMBG-2.0", "bria-rmbg-2.0", "auto", REV, "non-commercial:bria-rmbg-2.0" },
    { "AudioLDM2", "cc-by-nc-sa-4.0", "false", REV, "non-commercial:cc-by-nc-sa-4.0" },
    { "stable-audio-open-1.0", "stable-audio-community", "auto", REV, "revenue-capped:stable-audio-community" },
    { "gemma-3-4b-it", "gemma", "manual", REV, "custom-terms:gemma" },
    { "Qwen2.5-VL-3B", "qwen-research", "false", REV, "non-commercial:qwen-research" },
    { "mystery-model", "", "false", REV, "unknown-licence:-" },
    { "gated-apache", "apache-2.0", "auto", REV, "gated:gated=auto" },
    { "unpinned-mit", "mit", "false", "main", "unpinned:revision=main" },
    { "Qwen3-VL-4B", "apache-2.0", "false", REV, nil },
    { "BiRefNet", "mit", "false", REV, nil },
    { "SDXS-512-0.9", "openrail++", "false", REV, nil },
    { "music-medium-800k", "apache-2.0", "false", REV, nil },
}
local lines = { "#name\trepo\trevision\tfile\tsha256\tspdx\tgated\tcard" }
for _, r in ipairs(rows) do
    lines[#lines + 1] = table.concat({ r[1], "fixture/" .. r[1], r[4], "model.bin", SHA, r[2], r[3], "https://example.invalid/" .. r[1] }, "\t")
end
fs.write(REL .. "/register.tsv", table.concat(lines, "\n") .. "\n")

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

local r = run({ PLAN, "script", "run", ROOT .. "/" .. CHECK_REL },
    { cwd = ROOT, env = { TILLANDSIAS_MODEL_LICENCE_REGISTER = ROOT .. "/" .. REL .. "/register.tsv" } })
local outp = r.stdout or ""
local rc = r.status == "exited" and r.code or -1
local seen, reasons = {}, {}
for _, l in ipairs(text.lines(outp)) do
    local name, rest = l:match("^refused%-row:([^:]+):(.*)$")
    if name then seen[name] = rest; reasons[rest] = (reasons[rest] or 0) + 1 end
end
for _, row in ipairs(rows) do
    if row[5] then
        check("refuses " .. row[1], seen[row[1]] == row[5], "want " .. row[5] .. ", got " .. tostring(seen[row[1]]))
    else
        check("passes " .. row[1], seen[row[1]] == nil, "refused as " .. tostring(seen[row[1]]))
    end
end
local distinct = true
for _, n in pairs(reasons) do if n > 1 then distinct = false end end
check("every refusal has its own reason", distinct, "two rows share a reason line")
check("the scratch register is refused (exit 1)", rc == 1 and outp:find("refused:model-licence-register:refused=10:rows=14", 1, true) ~= nil,
    "rc=" .. rc .. " out=" .. outp)

local live = run({ PLAN, "script", "run", ROOT .. "/" .. CHECK_REL }, { cwd = ROOT })
check("the live register passes", live.status == "exited" and live.code == 0,
    "rc=" .. tostring(live.code) .. " " .. (live.stdout or ""))

run({ "rm", "-rf", ROOT .. "/" .. REL })
if failed > 0 then
    verdict.emit("fail:model-licence-register-fixture:" .. passed .. "/" .. (passed + failed), 1)
end
verdict.emit("ok:model-licence-register-fixture:" .. passed .. " arms", 0)
