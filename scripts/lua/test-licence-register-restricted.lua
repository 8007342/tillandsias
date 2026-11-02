-- @trace order:1956-ecpb, order:1954-dvz9
--
-- test-licence-register-restricted.lua — the restricted licence register
-- (images/models/licence-register-restricted.tsv, studio-asset-pipeline D6)
-- refuses a row with no obligation classes, an unknown class, or no licence
-- text hash, and the live register passes. Offline: it reads the register and
-- nothing else. The permissive check (check-model-licence-register.lua) never
-- reads this file, so it keeps refusing non-commercial rows in the permissive
-- register; that arm is checked here too.
--
-- Verdicts:
--   ok:licence-register-restricted:<n> arms                exit 0
--   fail:licence-register-restricted:<passed>/<total>      exit 1
--   could-not-run:licence-register-restricted:<why>        exit 3
--
-- Usage: tillandsias-plan script run scripts/lua/test-licence-register-restricted.lua

local REG = "images/models/licence-register-restricted.tsv"
local PERMISSIVE_CHECK = "scripts/lua/check-model-licence-register.lua"

local CLASSES = {
    ["attribution"] = true, ["notice"] = true, ["share-alike"] = true,
    ["non-commercial"] = true, ["use-restriction-passdown"] = true,
    ["field-of-use"] = true, ["seat-or-revenue-threshold"] = true,
    ["no-redistribution"] = true, ["source-availability"] = true, ["review"] = true,
}

-- The reason a restricted row is refused, or nil when it is well formed.
local function refusal(c)
    if #c ~= 10 then return "columns", tostring(#c) end
    if (c[7] or "") ~= "false" then return "gated", "gated=" .. (c[7] or "") end
    if (c[3] or "") == "" then return "unpinned", "revision=" end
    if not (c[5] or ""):match("^%x+$") or #c[5] ~= 64 then return "unpinned", "sha256=" .. (c[5] or "") end
    local obligations = c[9] or ""
    if obligations:gsub("%s", "") == "" then return "no-obligations", "-" end
    for cls in (obligations .. ";"):gmatch("(.-);") do
        local id = cls:match("^([^{]+)")
        if not id or not CLASSES[id] then return "unknown-obligation", cls end
    end
    local lh = c[10] or ""
    if lh == "" then return "no-licence-hash", "-" end
    if not ((lh:match("^%x+$") and #lh == 64) or lh:match("^pending:")) then return "bad-licence-hash", lh end
    return nil
end

local function parse(body)
    local rows = {}
    for line in (body .. "\n"):gmatch("(.-)\n") do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local c = {}
            for f in (line .. "\t"):gmatch("(.-)\t") do c[#c + 1] = f end
            rows[#rows + 1] = c
        end
    end
    return rows
end

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

local REV, SHA, LH = string.rep("a", 40), string.rep("b", 64), string.rep("c", 64)
local function row(name, obligations, licence_hash)
    return { name, "fixture/" .. name, REV, "model.safetensors", SHA, "cc-by-nc-sa-4.0", "false",
        "https://example.invalid/" .. name, obligations, licence_hash }
end
local arms = {
    { row("no-obligations", "", LH), "no-obligations" },
    { row("blank-obligations", "   ", LH), "no-obligations" },
    { row("typo-class", "attribution;share-alike;non-comercial", LH), "unknown-obligation" },
    { row("no-licence-hash", "attribution{fixture};non-commercial", ""), "no-licence-hash" },
    { row("short-licence-hash", "non-commercial", "abc123"), "bad-licence-hash" },
    { row("well-formed", "attribution{fixture};share-alike;non-commercial", LH), nil },
    { row("pending-hash", "non-commercial;review{unread}", "pending:https://example.invalid/LICENSE"), nil },
}
for _, a in ipairs(arms) do
    local reason = refusal(a[1])
    if a[2] then
        check("refuses " .. a[1][1] .. " as " .. a[2], reason == a[2], "got " .. tostring(reason))
    else
        check("passes " .. a[1][1], reason == nil, "refused as " .. tostring(reason))
    end
end

local ok_read, body = pcall(fs.read, REG)
if not ok_read then
    verdict.emit("could-not-run:licence-register-restricted:no-register", 3)
end
local live = parse(body)
check("the live register has rows", #live >= 1, "none")
for _, c in ipairs(live) do
    local reason, detail = refusal(c)
    check("live row " .. (c[1] or "?") .. " (" .. (c[4] or "?") .. ") is well formed", reason == nil,
        tostring(reason) .. ":" .. tostring(detail))
end
check("the live register names a CorridorKey row", body:find("nikopueringer/CorridorKey2.0", 1, true) ~= nil, "missing")

-- The permissive check never reads this file: a non-commercial id stays a refusal there.
local ok_check, check_body = pcall(fs.read, PERMISSIVE_CHECK)
check("the permissive check does not read the restricted register",
    ok_check and check_body:find("licence-register-restricted", 1, true) == nil,
    "check-model-licence-register.lua mentions the restricted register")
check("the permissive check still denies cc-by-nc-sa-4.0",
    ok_check and check_body:find('["cc-by-nc-sa-4.0"] = "non-commercial"', 1, true) ~= nil,
    "DENIED lost cc-by-nc-sa-4.0")

if failed > 0 then
    verdict.emit("fail:licence-register-restricted:" .. passed .. "/" .. (passed + failed), 1)
end
verdict.emit("ok:licence-register-restricted:" .. passed .. " arms", 0)
