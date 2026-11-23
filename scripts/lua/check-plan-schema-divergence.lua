-- @env PWD TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:744-agyy (order 440, order 720-24u6), order:1247-sv4d, order:746-htj9
--
-- check-plan-schema-divergence.lua — plan/index.yaml default_status_values and
-- plan/schema.yaml statuses must be identical. (Ported from
-- scripts/check-plan-schema-divergence.sh, the shell-to-lua item carried by
-- order 2165-ryfg; its long history — ruby, then yq, then neither — is in
-- `git log -- scripts/check-plan-schema-divergence.sh`.)
--
-- Verdicts, exactly as the .sh (one stdout line; why/remedy on stderr):
--   ok:status-vocab-in-sync                                         exit 0
--   blocked:status-vocab-diverges: <details>                        exit 1
--   blocked:index-load-failed: <file>: <parser message>             exit 1
--   blocked:status-vocab-absent: <file>: <dotted.path>  (1247-sv4d) exit 1
--
-- WHY THE LOAD VERDICT IS SEPARATE (720-24u6): a fold once carried bare-scalar
-- timestamps into the base, the old reader raised before either vocabulary was
-- read, and the gate named a divergence that did not exist. Load failure and
-- divergence are different facts.
--
-- THE ONE READER (746-htj9): `tillandsias-plan yaml-get`, the only YAML reader
-- present in the forge, on the host and in the builder toolbox. It is the plan
-- binary this script already runs under, named by `-- --plan <path>`,
-- TILLANDSIAS_PLAN_BIN, or TILLANDSIAS_SCRIPT_RUNNER_BIN (set by build.sh's
-- _run_lua_decider). It is a child, not fs.read, because the files may lie
-- outside the repository (test-yaml-reader-availability.sh passes a temp file).
--
-- Usage: tillandsias-plan script run scripts/lua/check-plan-schema-divergence.lua [-- [--plan <bin>] [index.yaml [schema.yaml]]]

local SELF = "scripts/lua/check-plan-schema-divergence.lua"
local CWD = env.get("PWD")
local function run(argv)
    return proc.run({ argv = argv, timeout_ms = 60000, cwd = (CWD ~= nil and CWD ~= "") and CWD or nil })
end
-- why/remedy ride as the verdict's DETAIL, so they print AFTER the verdict
-- line, as in the .sh (callers read `2>&1 | head -n 1`).
local function afford(why, remedy)
    return "  why: " .. why .. "\n  remedy: " .. remedy
end

local PLAN, pos = nil, {}
local i = 1
while i <= #arg do
    if arg[i] == "--plan" then PLAN = arg[i + 1]; i = i + 2
    else pos[#pos + 1] = arg[i]; i = i + 1 end
end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end

local INDEX = pos[1] or "plan/index.yaml"
local SCHEMA = pos[2] or "plan/schema.yaml"

local function is_file(p)
    local r = run({ "test", "-f", p })
    return r.status == "exited" and r.code == 0
end

if not is_file(INDEX) or not is_file(SCHEMA) then
    local missing = ""
    if not is_file(INDEX) then missing = INDEX end
    if not is_file(SCHEMA) then missing = (missing ~= "" and (missing .. " and ") or "") .. SCHEMA end
    verdict.emit("blocked:status-vocab-diverges: could not read " .. INDEX .. " or " .. SCHEMA, 1,
        afford(missing .. " is not a file from " .. (CWD or "the current directory") ..
        ", so there is nothing to compare; the default paths are relative to the repository root",
        "run it from the repository root, or name both files: " .. SELF .. " -- <index.yaml> <schema.yaml>"))
end

local function load_seq(file, path)
    if not PLAN or PLAN == "" then
        verdict.emit("blocked:index-load-failed: " .. file .. ": no sanctioned YAML reader named (no plan binary)", 1,
            afford("no tillandsias-plan binary was named (--plan, TILLANDSIAS_PLAN_BIN, TILLANDSIAS_SCRIPT_RUNNER_BIN), and it is the only YAML reader this gate trusts; the ledger itself was not read, so nothing says it is corrupt",
            "cargo build --release -p tillandsias-plan, or set TILLANDSIAS_PLAN_BIN to a built tillandsias-plan"))
    end
    local r = run({ PLAN, "yaml-get", file, path })
    local out = text.trim((r.stdout or "") .. ((r.status == "exited" and r.code == 0) and "" or ("\n" .. (r.stderr or ""))))
    if r.status ~= "exited" or r.code ~= 0 then
        local first = out:match("^[^\n]*") or ""
        if r.status ~= "exited" then
            -- The .sh's reader-absent wording: a missing reader reads like a
            -- corrupt ledger unless it is named (the 2026-08-15 yq outage).
            verdict.emit("blocked:index-load-failed: " .. file .. ": no sanctioned YAML reader runs (" .. PLAN .. ")", 1,
                afford("the named plan binary " .. PLAN .. " could not be run, and it is the only YAML reader this gate trusts; the ledger itself was not read, so nothing says it is corrupt",
                    "cargo build --release -p tillandsias-plan, or set TILLANDSIAS_PLAN_BIN to a built tillandsias-plan"))
        end
        verdict.emit("blocked:index-load-failed: " .. file .. ": " .. first, 1,
            afford(file .. " does not parse as YAML, so its vocabulary was never read; this is a syntax error, not a vocabulary divergence",
                "fix the YAML at the position above, then confirm with: " .. PLAN .. " validate-yaml " .. file))
    end
    if out == "" then
        verdict.emit("blocked:status-vocab-absent: " .. file .. ": " .. path, 1,
            afford(file .. " loads but has no " .. path .. ", so there is no vocabulary to compare; two absent vocabularies are not in sync",
                "add " .. path .. " to " .. file .. ", listing the same statuses as the other file, in the same order"))
    end
    return out
end

local function only_in(a, b)
    local set, o = {}, {}
    for w in b:gmatch("%S+") do set[w] = true end
    for w in a:gmatch("%S+") do if not set[w] then o[#o + 1] = w end end
    return table.concat(o, " ")
end

local idx = load_seq(INDEX, "plan_index.default_status_values")
local sch = load_seq(SCHEMA, "statuses")

if idx ~= sch then
    local a, b = only_in(idx, sch), only_in(sch, idx)
    local diff
    if a == "" and b == "" then
        diff = "both list the same statuses, in a different order"
    else
        diff = "only in " .. INDEX .. ": (" .. (a ~= "" and a or "none") .. "); only in " .. SCHEMA .. ": (" .. (b ~= "" and b or "none") .. ")"
    end
    verdict.emit("blocked:status-vocab-diverges: " .. INDEX .. "=(" .. idx .. ") vs " .. SCHEMA .. "=(" .. sch .. ")", 1,
        afford("the plan tools validate a row's status against one vocabulary and the ledger defaults against the other, so a status valid in one is refused by the other; " .. diff,
        "make " .. INDEX .. " plan_index.default_status_values and " .. SCHEMA .. " statuses list the same statuses in the same order, in one commit"))
end

verdict.emit("ok:status-vocab-in-sync", 0)
