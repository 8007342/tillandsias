-- @trace order:1489-8qd6, order:2300-6m9m, spec:gh-auth-script
--
-- test-github-token-rotation-entry-points.lua — every resident Tillandsias process runs the
-- GitHub token due-check (1461-8tyy), and removing any one entry point fails here. Ported
-- from the .sh of the same name (2300-6m9m). test-github-token-auto-rotation.sh pins the
-- due-check LOGIC; this pins its CALLERS (a host that lost its call died at the 8-hour
-- expiry: lenovinha 2026-09-28).
--
--   TRAY   tray/mod.rs, the fn that makes the call in the Linux tray's start-up
--   LANE   main.rs ensure_enclave_for_project, which every lane launch runs
--   GUEST  main.rs maybe_spawn_vsock_listener, the macOS/Windows guest
--
-- A call counts only in the NAMED FUNCTION's body (by brace depth) and not in a comment.
--
--   1-3 each entry point calls the scheduler
--   4-6 MUTATION with that one call commented out, the check fails
--   7   the two audit events cite gh-auth-script, not the tombstoned secret-rotation
--   8   MUTATION moving the LANE call into another function is not counted
--
-- Usage: tillandsias-plan script run scripts/lua/test-github-token-rotation-entry-points.lua
-- Verdict: ok:github-token-rotation-entry-points:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("github-token-rotation-entry-points")
local CALL = "spawn_github_token_rotation_scheduler"
local H = "crates/tillandsias-headless/src/"
local function src(f)
    if not fs.exists(H .. f) then T:refuse("missing", H .. f) end
    return text.lines(fs.read(H .. f))
end
local MAIN, TRAY, VB = src("main.rs"), src("tray/mod.rs"), src("vault_bootstrap.rs")
local function comment(l) return l:match("^%s*//") ~= nil end

-- the first fn named so: first and last line number, by brace depth outside strings and comments
local function span(ls, name)
    local from, depth, seen = nil, 0, false
    for i, l in ipairs(ls) do
        if not from and (l:find("fn " .. name .. "%f[^%w_]%s*[(<]")) then from = i end
        if from then
            local s = l:gsub('\\\\', ""):gsub('\\"', ""):gsub('"[^"]*"', ""):gsub("//.*", "")
            local _, o = s:gsub("{", ""); local _, c = s:gsub("}", "")
            if o > 0 then seen = true end
            depth = depth + o - c
            if seen and depth <= 0 then return from, i end
        end
    end
    return nil
end
local function calls(ls, name)
    local a, b = span(ls, name)
    local n = 0
    for i = a or 1, a and b or 0 do if not comment(ls[i]) and ls[i]:find(CALL, 1, true) then n = n + 1 end end
    return n
end
-- the tray's fn is whichever makes the call
local tray_fn, cur
for _, l in ipairs(TRAY) do
    cur = l:match("^%s*fn ([%l_]+)") or l:match("^%s*pub fn ([%l_]+)") or l:match("^%s*async fn ([%l_]+)")
        or l:match("^%s*pub async fn ([%l_]+)") or l:match("^%s*pub%([%l]+%) fn ([%l_]+)") or l:match("^%s*pub%([%l]+%) async fn ([%l_]+)") or cur
    if not tray_fn and not comment(l) and l:find(CALL, 1, true) then tray_fn = cur end
end
local E = { { "TRAY", TRAY, tray_fn or "no_tray_function_calls_it" }, { "LANE", MAIN, "ensure_enclave_for_project" }, { "GUEST", MAIN, "maybe_spawn_vsock_listener" } }
for i, e in ipairs(E) do
    T:arm(i .. " " .. e[1] .. " " .. e[3] .. " calls the scheduler", calls(e[2], e[3]) >= 1, "this process would never rotate the token")
end
local function copy(ls) local t = {}; for i, l in ipairs(ls) do t[i] = l end; return t end
for i, e in ipairs(E) do
    local m, a, b = copy(e[2]), span(e[2], e[3])
    local cut = 0
    for k = a or 1, a and b or 0 do
        if not comment(m[k]) and m[k]:find(CALL, 1, true) then m[k] = "// " .. m[k]; cut = cut + 1 end
    end
    T:arm((i + 3) .. " MUTATION " .. e[1] .. " commenting the call out is caught", cut >= 1 and calls(m, e[3]) == 0, "cut=" .. cut)
end
for _, f in ipairs{ { "audit_github_token_auto_rotation", VB }, { "audit_github_token_refresh", MAIN } } do
    local a, b = span(f[2], f[1])
    local body = a and table.concat(f[2], "\n", a, b) or ""
    T:arm("7 " .. f[1] .. " records under gh-auth-script", text.contains(body, 'spec = "gh-auth-script"') and not text.contains(body, 'spec = "secret-rotation"'), "secret-rotation is tombstoned (1397-eppt)")
end
do
    local m, a, b = copy(MAIN), span(MAIN, "ensure_enclave_for_project")
    local line
    for k = a or 1, a and b or 0 do if not comment(m[k]) and m[k]:find(CALL, 1, true) then line = m[k]; m[k] = "" end end
    table.insert(m, a or 1, "fn somewhere_else() {\n" .. (line or "") .. "\n}")
    local flat = text.lines(table.concat(m, "\n"))
    T:arm("8 MUTATION a call moved into another function is not counted", line ~= nil and calls(flat, "ensure_enclave_for_project") == 0 and calls(flat, "somewhere_else") == 1, tostring(line))
end
T:finish()
