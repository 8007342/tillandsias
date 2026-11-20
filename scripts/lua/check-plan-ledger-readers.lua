-- @trace order:2118-9awa
--
-- check-plan-ledger-readers.lua — PORTED from check-plan-ledger-readers.sh
-- (2118-9awa, check-[n-z] batch 1). A direct CONTENT read of plan/index.yaml
-- (yq, awk, a YAML/File read) sees the base ledger without its fragments; every
-- reader must go through the fragment-aware `tillandsias-plan` CLI, or be on
-- the allowlist below with its reason. Rules and allowlist are the .sh's,
-- unchanged.
--
-- Grammar (stdout), unchanged:
--   violation: content read of plan/index.yaml in <file>:
--     <n>:<line>
--   blocked: <n> unprotected direct reader(s) of plan/index.yaml — ...   exit 1
--   ok: every reader of plan/index.yaml is overlay-aware or base-only-with-reason
--
-- Usage: tillandsias-plan script run scripts/lua/check-plan-ledger-readers.lua [-- --strict]

local STRICT = arg and arg[1] == "--strict"

local ALLOWLIST = {
    ["images/default/config-overlay/mcp/forge-plan.sh"] = "overlay: wraps tillandsias-plan",
    ["images/default/config-overlay/mcp/project-info.sh"] = "overlay: plan_query routes through query --json",
    ["scripts/drain-queue.sh"] = "overlay: extract_ready_packets routes through query --status ready",
    ["scripts/check-plan-schema-divergence.sh"] = "base-only-reason: reads ONLY default_status_values vocabulary (schema-level, fragments are packet additions and can never carry it)",
    ["crates/tillandsias-plan/src/main.rs"] = "overlay: the CLI itself (Ledger::load_with_fragments)",
    ["crates/tillandsias-plan/src/lib.rs"] = "overlay: the CLI itself (Ledger::load_with_fragments)",
    ["crates/tillandsias-plan/src/fragments.rs"] = "overlay: the fragment engine",
    ["crates/tillandsias-plan/src/loop_status.rs"] = "overlay: loop_status fold engine (separate doc, same discipline)",
    ["crates/tillandsias-plan/src/answer.rs"] = "overlay: answers come from the folded ledger",
    ["crates/tillandsias-plan/src/groundtruth.rs"] = "overlay: grades the experts against the folded ledger",
    ["crates/tillandsias-plan/tests/lua_std.rs"] = "base-only-reason: reads a scratch FIXTURE ledger the test wrote into a temp dir (w.join(\"plan/index.yaml\")); never the real plan/index.yaml (1405-3mrp)",
    ["crates/tillandsias-policy/src/main.rs"] = "base-only-reason: plan-orders is superseded by `tillandsias-plan check` (fragment-aware duplicate-order gate); kept for legacy script wrappers only",
    -- 2118-9awa: this port names the path in its own rules, as the .sh did
    -- through its grep; it reads no ledger.
    ["scripts/lua/check-plan-ledger-readers.lua"] = "base-only-reason: the scanner itself; it names plan/index.yaml only as the token it looks for",
}

local SIGNALS = { "yq", "awk", "YAML.load", "File.read", "File.readlines", "read_to_string", "ruby -ryaml" }
local TOKEN = "plan/index." .. "yaml"

local function has(l, s) return l:find(s, 1, true) ~= nil end
local function is_content_read(line)
    if has(line, "--index") then return false end
    local f = line:find("-f", 1, true)
    if f and line:find(TOKEN, f + 2, true) then return false end
    if has(line, "[ -f") then return false end
    if has(line, "test -f") then return false end
    if line:match("^%s*#") then return false end
    if has(line, "@trace") then return false end
    for _, sig in ipairs(SIGNALS) do
        if has(line, sig) then return true end
    end
    return false
end

local files = {}
for _, dir in ipairs({ "scripts", "images", "crates", "skills", "methodology" }) do
    for _, f in ipairs(fs.walk(dir, {}) or {}) do
        local ok, body = pcall(fs.read, f)
        if ok and body and body:find(TOKEN, 1, true) then files[#files + 1] = { f, body } end
    end
end

local violations = 0
for _, fb in ipairs(files) do
    local file, body = fb[1], fb[2]
    if not ALLOWLIST[file] or STRICT then
        -- Plain byte splitting, like grep: text.lines refuses invalid UTF-8,
        -- and a binary file that contains the token is still scanned.
        local n = 0
        for line in (body .. "\n"):gmatch("([^\n]*)\n") do
            n = n + 1
            if line:find(TOKEN, 1, true) and is_content_read(line) then
                out.line("violation: content read of plan/index.yaml in " .. file .. ":")
                out.line("  " .. n .. ":" .. line)
                violations = violations + 1
            end
        end
    end
end

if violations > 0 then
    out.line("blocked: " .. violations .. " unprotected direct reader(s) of plan/index.yaml — route them through 'tillandsias-plan query' (or document them as base-only-with-reason)")
    verdict.emit("blocked:plan-ledger-readers:" .. violations, 1)
end
out.line("ok: every reader of plan/index.yaml is overlay-aware or base-only-with-reason")
verdict.emit("ok:plan-ledger-readers", 0)
