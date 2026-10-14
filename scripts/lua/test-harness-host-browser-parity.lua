-- @trace order:1667-jna9, spec:host-browser-mcp
-- @env PATH
--
-- test-harness-host-browser-parity.lua — every forge agent harness exposes the
-- host-browser MCP server (publish_local, service_status, browser.open), and
-- one that drops it fails here.
--
-- A Codex lane on work/1661-vckd had none of the host-browser tools while
-- Claude lanes did. Registration was not missing: codex/register-experts.sh
-- listed host-browser. Codex starts a stdio MCP server with only
-- HOME LANG PATH PWD SHLVL USER (measured, codex-cli 0.162.1, 2026-10-14), so
-- host-browser.sh never saw TILLANDSIAS_CONTROL_SOCKET and exited at startup.
-- A harness therefore "exposes" host-browser only if it both declares the
-- server AND hands it the socket variable the server reads.
--
-- The one source is config-overlay/mcp/host-browser.sh itself: the command path
-- every harness must name, and the variable it refuses without. Each harness
-- declaration is read from the file the image ships:
--   claude     config-overlay/claude/mcp.json      (full environment passed)
--   opencode   config-overlay/opencode/config.json (full environment passed)
--   codex      config-overlay/codex/register-experts.sh SERVERS heredoc, and
--              its host-browser line must forward the socket variable
--   antigravity has no MCP registration yet — a NAMED GAP (order 1678-62p7),
--              printed every run; when a registration appears the gap line
--              says to make it a checked harness
--   1 DECLARED   claude, opencode and codex each declare host-browser at the
--                shipped command path
--   2 SOCKET     host-browser.sh still reads TILLANDSIAS_CONTROL_SOCKET and codex
--                forwards exactly that name (the launch builders that set it are
--                pinned by their own tests in main.rs)
--   3 DROPPED    each harness with host-browser removed (constructed in memory)
--                is caught, one violation per harness: the fixture can fail
--   4 UNFORWARDED codex's line without the forwarded variable (today's trunk
--                shape) is caught
--
-- Usage: tillandsias-plan script run scripts/lua/test-harness-host-browser-parity.lua

local OVL = "images/default/config-overlay/"
local CMD = "/home/forge/.config-overlay/mcp/host-browser.sh"
local VAR = "TILLANDSIAS_CONTROL_SOCKET"

local failed = {}
local function arm(name, cond, got)
    got = tostring(got):gsub("\n", " | ")
    if cond then out.line("ok:   " .. name .. " — " .. got) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

local function read(path)
    local ok, body = pcall(fs.read, path)
    if not ok or body == nil or body == "" then
        verdict.could_not_run("harness-host-browser-parity", "cannot read " .. path)
    end
    return body
end

-- The JSON object value of key "host-browser", braces balanced. Whole-file
-- pattern matching would let a later server's "command" stand in for it.
local function json_entry(body, key)
    local s = body:find('"' .. key:gsub("%-", "%%-") .. '"%s*:%s*{')
    if not s then return nil end
    local open = body:find("{", s, true)
    local depth = 0
    for i = open, #body do
        local c = body:sub(i, i)
        if c == "{" then depth = depth + 1 elseif c == "}" then
            depth = depth - 1
            if depth == 0 then return body:sub(open, i) end
        end
    end
    return nil
end

-- The codex helper's SERVERS heredoc lines, comments excluded by construction:
-- only the lines between `<<'SERVERS'` and the closing `SERVERS`.
local function codex_servers(body)
    local list, on = {}, false
    for l in (body .. "\n"):gmatch("(.-)\n") do
        if on and l == "SERVERS" then break end
        if on then
            local name, rest = l:match("^(%S+)%s*(.*)$")
            if name then list[name] = rest end
        end
        if l:find("<<'SERVERS'", 1, true) then on = true end
    end
    return list
end

local function check_claude(body)
    local e = json_entry(body, "host-browser")
    return e ~= nil and e:find('"command"%s*:%s*"' .. CMD:gsub("%p", "%%%0") .. '"') ~= nil
end
local function check_opencode(body)
    local e = json_entry(body, "host-browser")
    return e ~= nil and e:find('"command"%s*:%s*%[%s*"' .. CMD:gsub("%p", "%%%0") .. '"') ~= nil
end
local function check_codex(body)
    local s = codex_servers(body)
    return s["host-browser"] ~= nil
end
local function codex_forwards(body)
    local rest = codex_servers(body)["host-browser"] or ""
    for w in rest:gmatch("%S+") do if w == VAR then return true end end
    return false
end

local claude = read(OVL .. "claude/mcp.json")
local opencode = read(OVL .. "opencode/config.json")
local codex = read(OVL .. "codex/register-experts.sh")
local server = read(OVL .. "mcp/host-browser.sh")
local agy = read("images/default/entrypoint-forge-antigravity.sh")

-- ── 1 declared ─────────────────────────────────────────────────────────────
local c1, o1, x1 = check_claude(claude), check_opencode(opencode), check_codex(codex)
arm("1 DECLARED claude, opencode and codex declare host-browser at " .. CMD,
    c1 and o1 and x1, "claude=" .. tostring(c1) .. " opencode=" .. tostring(o1) .. " codex=" .. tostring(x1))

-- ── 2 the socket variable reaches the server ───────────────────────────────
local reads = 0
for l in (server .. "\n"):gmatch("(.-)\n") do
    if not l:match("^%s*#") and l:find("${" .. VAR, 1, true) then reads = reads + 1 end
end
local fwd = codex_forwards(codex)
arm("2 SOCKET host-browser.sh reads " .. VAR .. " and codex forwards it",
    reads >= 1 and fwd,
    "server-reads=" .. reads .. " codex-forwards=" .. tostring(fwd))

-- ── 3 a harness that drops it is caught ────────────────────────────────────
local function drop_json(body) return (body:gsub('"host%-browser"', '"host-browser-removed"')) end
local function drop_codex(body) return (body:gsub("\nhost%-browser[^\n]*", "")) end
local caught = {
    claude = not check_claude(drop_json(claude)),
    opencode = not check_opencode(drop_json(opencode)),
    codex = not check_codex(drop_codex(codex)),
}
local mutated = drop_json(claude) ~= claude and drop_json(opencode) ~= opencode and drop_codex(codex) ~= codex
arm("3 DROPPED each harness with host-browser removed is caught",
    mutated and caught.claude and caught.opencode and caught.codex,
    "mutations-landed=" .. tostring(mutated) .. " claude=" .. tostring(caught.claude) ..
    " opencode=" .. tostring(caught.opencode) .. " codex=" .. tostring(caught.codex))

-- ── 4 codex registering it without the variable is caught ──────────────────
local unforwarded = codex:gsub("\nhost%-browser[^\n]*", "\nhost-browser")
arm("4 UNFORWARDED codex's host-browser line without " .. VAR .. " (the trunk shape) is caught",
    unforwarded ~= codex and check_codex(unforwarded) and not codex_forwards(unforwarded),
    "mutation-landed=" .. tostring(unforwarded ~= codex) .. " still-declared=" .. tostring(check_codex(unforwarded)) ..
    " forwards=" .. tostring(codex_forwards(unforwarded)))

-- ── the named gap ──────────────────────────────────────────────────────────
if agy:find("host-browser", 1, true) or agy:find("mcp_config", 1, true) then
    out.line("note: antigravity's entrypoint now names host-browser or mcp_config — make it a checked harness here and close the gap (1678-62p7)")
else
    out.line("gap:antigravity:no-mcp-registration — order 1678-62p7")
end

if #failed > 0 then
    verdict.emit("violation:harness-host-browser-parity:" .. #failed .. "-failed", 1)
end
verdict.ok("harness-host-browser-parity", "4 arms")
