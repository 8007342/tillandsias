-- @trace order:680-zphp, order:865-x2mf, spec:forge-environment-discoverability, order:2066-obsv
-- @env TILLANDSIAS_GROUNDTRUTH_LEDGER_ROOT TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- check-groundtruth-mutable-status-pins.lua — refuse an expert-groundtruth case
-- that pins `status:` on a packet whose LIVE status is not terminal. (Ported
-- from scripts/check-groundtruth-mutable-status-pins.sh: the shell-to-lua item
-- order 2066-obsv carried for its PR 5. Its history is in
-- `git log -- scripts/check-groundtruth-mutable-status-pins.sh`.)
--
-- WHY (680-zphp). A groundtruth case that cites a packet and pins its status
-- reds the harness on the next legitimate ledger update: a live packet's status
-- moves by design. Terminal statuses (completed, verified, done, obsoleted) are
-- stable and admitted; an unknown packet (a fixture-* id or a typo) is not a
-- live pin and is skipped.
--
-- Inputs:
--   arg[1]                               the case directory, inside the
--                                        repository (default
--                                        openspec/litmus-tests/groundtruth)
--   TILLANDSIAS_GROUNDTRUTH_LEDGER_ROOT  the ledger the statuses are read from
--                                        (default: the repository). A control
--                                        supplies a frozen two-packet ledger it
--                                        owns, so nothing in plan/ can move it
--                                        (865-x2mf).
--
-- WHAT THE PORT CHANGES. The .sh resolved its own plan binary and, with none,
-- printed ok with 0 live-checked: a pass that checked nothing. Here the binary
-- is NAMED by the caller (TILLANDSIAS_PLAN_BIN, then
-- TILLANDSIAS_SCRIPT_RUNNER_BIN, which build.sh's _run_lua_decider sets), and a
-- run with none is could-not-run, never ok (the 1642-cc54 precedent). Every
-- call is argv through proc.run.
--
-- Grammar (one line on stdout; each violation on stderr):
--   ok:groundtruth-status-pins:<n> live-checked                    exit 0
--   violation:mutable-status-pin:<n>                               exit 1
--   could-not-run:groundtruth-status-pins                          exit 3
--
-- Pinned by litmus:groundtruth-no-mutable-status-pin-shape.

local function nonempty(v) return v ~= nil and v ~= "" end

local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if not nonempty(BIN) then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not nonempty(BIN) then
    verdict.could_not_run("groundtruth-status-pins", "no-plan-binary — run through build.sh's _run_lua_decider, or set TILLANDSIAS_PLAN_BIN")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
if top.status ~= "exited" or top.code ~= 0 then
    verdict.could_not_run("groundtruth-status-pins", "not inside a git work tree")
end
local ROOT = text.trim(top.stdout or "")

local GT_DIR = arg and arg[1]
if not nonempty(GT_DIR) then GT_DIR = ROOT .. "/openspec/litmus-tests/groundtruth" end

local LEDGER_ROOT = env.get("TILLANDSIAS_GROUNDTRUTH_LEDGER_ROOT")
if not nonempty(LEDGER_ROOT) then LEDGER_ROOT = ROOT end

local TERMINAL = { completed = true, verified = true, done = true, obsoleted = true }

-- (packet_id, pinned status) pairs: a `status:` line whose nearest preceding
-- `packet_id:` names the packet the pin applies to.
local function pins(body)
    local out, pid = {}, nil
    for _, line in ipairs(text.lines(body)) do
        local p = line:match("^%s*%- packet_id:%s+(.-)%s*$") or line:match("^%s*packet_id:%s+(.-)%s*$")
        if p then pid = p end
        local st = line:match("^%s*status:%s*([a-z].-)%s*$")
        if st and pid and pid ~= "" then out[#out + 1] = { pid, st } end
    end
    return out
end

-- The runtime reads files inside the repository only, so a case directory is
-- under the repository (a control builds its own under target/). The ledger
-- root is only a cwd for the plan binary and may be anywhere.
local listed_ok, listed = pcall(fs.list, GT_DIR)
if not listed_ok then
    verdict.could_not_run("groundtruth-status-pins", "case directory " .. GT_DIR .. " is not readable inside the repository: " .. tostring(listed))
end
local files = {}
for _, f in ipairs(listed or {}) do
    local name = f:match("([^/]+)$") or f
    if name:match("%.yaml$") then files[#files + 1] = name end
end
table.sort(files)

local checked, violations = 0, 0
for _, name in ipairs(files) do
    local body = fs.read(GT_DIR .. "/" .. name) or ""
    for _, pair in ipairs(pins(body)) do
        local pid, pinned = pair[1], pair[2]
        local r = proc.run({ argv = { BIN, "status", pid }, cwd = LEDGER_ROOT, timeout_ms = 30000 })
        local live = nil
        if r.status == "exited" and r.code == 0 then
            live = (r.stdout or ""):match("^%S+%s+(%S+)")
        end
        if live then
            checked = checked + 1
            if not TERMINAL[live] then
                violations = violations + 1
                log.raw("  violation: " .. name .. " pins status on '" .. pid .. "' whose LIVE status is '" .. live
                    .. "' (non-terminal — will churn); pinned '" .. pinned .. "'. De-pin it (identity/deliverable text is stable) or the harness reds on the next legitimate update.")
            end
        end
    end
end

if violations > 0 then
    verdict.emit("violation:mutable-status-pin:" .. violations, 1)
end
verdict.ok("groundtruth-status-pins", checked .. " live-checked")
