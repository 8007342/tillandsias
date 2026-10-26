-- @trace spec:research-records
-- @trace order:1809-dwqf
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-research-records.lua — the validator (scripts/lua/check-research-records.lua)
-- on CONSTRUCTED roots. The arm that matters is 2: a record with every other
-- field but no sources: is refused, named, with missing-provenance in the
-- verdict. Before 1809-dwqf nothing read research records at all, so a record
-- with no provenance was accepted by default — that is the pre-fix failure.
--
--   1 VALID     a complete record passes: ok:research-records:records=1
--   2 NO-SRC    the same record without sources: is refused, exit 1, and the
--               verdict names the file and `sources:missing-provenance`
--   3 NO-ARCH   a source with url + retrieved but no archived: is refused
--               with `.archived:missing-archived-link`
--   4 NO-CLAIM  a record with provenance but no claim is refused
--   5 BAD-ID    a record whose id does not equal its path is refused
--   6 EMPTY     a research dir with no <domain>/<slug>.md: could-not-run, exit 3
--   7 INDEX     --write-index writes INDEX.md carrying the record's line
--
-- Usage: tillandsias-plan script run scripts/lua/test-research-records.lua

local SUBJECT_REL = "scripts/lua/check-research-records.lua"
if not fs.exists(SUBJECT_REL) then
    verdict.emit("violation:research-records-fixture:no-subject", 1, SUBJECT_REL .. " does not exist (1809-dwqf)")
end
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("research-records-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("research-records-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/research-records-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local SOURCES = table.concat({
    "sources:",
    "  - url: https://doi.org/10.1037/h0055392",
    "    kind: peer-reviewed",
    "    archived: https://web.archive.org/web/20261004140812/https://psycnet.apa.org/doi/10.1037/h0055392",
    "    retrieved: 2026-10-26",
    "" }, "\n")
local SOURCES_NO_ARCHIVE = table.concat({
    "sources:",
    "  - url: https://doi.org/10.1037/h0055392",
    "    kind: peer-reviewed",
    "    retrieved: 2026-10-26",
    "" }, "\n")
local function record(opts)
    local id = opts.id or "interaction/fitts-law-1954"
    local parts = { "---", "id: " .. id }
    if not opts.no_claim then parts[#parts + 1] = "claim: bigger and closer targets are acquired faster" end
    parts[#parts + 1] = "applies_to: [button-sizing]"
    parts[#parts + 1] = "tags: [fitts]"
    if opts.sources ~= false then parts[#parts + 1] = (opts.sources or SOURCES):gsub("\n$", "") end
    parts[#parts + 1] = "authority: primary"
    parts[#parts + 1] = "strength: established"
    parts[#parts + 1] = "since: 2026-10-26"
    parts[#parts + 1] = "last_verified: 2026-10-26"
    parts[#parts + 1] = "status: current"
    parts[#parts + 1] = "origin: project"
    parts[#parts + 1] = "---"
    parts[#parts + 1] = "# Fitts"
    parts[#parts + 1] = ""
    parts[#parts + 1] = "## Claim"
    parts[#parts + 1] = ""
    parts[#parts + 1] = "## Provenance"
    parts[#parts + 1] = ""
    parts[#parts + 1] = "- <https://doi.org/10.1037/h0055392>"
    parts[#parts + 1] = ""
    return table.concat(parts, "\n")
end
local function root_with(name, body)
    local d = REL .. "/" .. name .. "/research"
    fs.mkdir(d .. "/interaction")
    if body then fs.write(d .. "/interaction/fitts-law-1954.md", body) end
    fs.write(d .. "/README.md", "# not a record\n")
    return d
end
local function run(d, extra)
    local argv = { PLAN, "script", "run", SUBJECT_REL }
    if extra then argv[#argv + 1] = "--"; argv[#argv + 1] = extra end
    local r = proc.run({ argv = argv, cwd = ROOT, timeout_ms = 60000,
        env = { TILLANDSIAS_RESEARCH_DIR = d } })
    return r.code or -1, text.trim(r.stdout or "")
end

local code, outp = run(root_with("valid", record({})))
arm("1 VALID a complete record passes", code == 0 and text.contains(outp, "ok:research-records:records=1"), outp)

code, outp = run(root_with("nosrc", record({ sources = false })))
arm("2 NO-SRC a record without sources is refused and named",
    code == 1 and text.contains(outp, "violation:research-records:interaction/fitts-law-1954.md:sources:missing-provenance"), outp)

code, outp = run(root_with("noarch", record({ sources = SOURCES_NO_ARCHIVE })))
arm("3 NO-ARCH a source without an archived link is refused",
    code == 1 and text.contains(outp, "sources[1].archived:missing-archived-link"), outp)

code, outp = run(root_with("noclaim", record({ no_claim = true })))
arm("4 NO-CLAIM a record without a claim is refused", code == 1 and text.contains(outp, ":claim:missing"), outp)

code, outp = run(root_with("badid", record({ id = "interaction/something-else" })))
arm("5 BAD-ID an id that is not the path is refused", code == 1 and text.contains(outp, ":id:must equal interaction/fitts-law-1954"), outp)

code, outp = run(root_with("empty", nil))
arm("6 EMPTY no records: could-not-run, exit 3", code == 3 and text.contains(outp, "could-not-run:research-records:empty-population"), outp)

local d = root_with("index", record({}))
code, outp = run(d, "--write-index")
local idx = ""
pcall(function() idx = fs.read(d .. "/INDEX.md") end)
arm("7 INDEX --write-index writes INDEX.md with the record line",
    code == 0 and text.contains(idx, "- interaction/fitts-law-1954.md — bigger and closer targets") and text.contains(idx, "AUTO-GENERATED"), outp)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:research-records-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("research-records-fixture", "7 arms")
