-- @trace order:1247-ert9, order:1247-amcu, spec:ci-release
-- @env TILLANDSIAS_INSTALLER_SRC
-- @read-env TILLANDSIAS_INSTALLER_SRC
--
-- test-installer-fatal-messages-carry-a-next-step.lua — every fatal Die message
-- of scripts/install-windows.ps1 says what happened AND what the user can do
-- next, in one plain sentence a non-developer can act on (coordinator, 2026-10-24:
-- "Restart Windows and run the installer again", "Free up at least N GB and try
-- again"; no wsl or podman commands, flags or env vars; the log path may stay as
-- a secondary part).
--
-- A Die message is the double-quoted literal of a `Die "..."` call, comments
-- stripped, `# power-user-only` lines skipped (usage errors, as in
-- check-installer-end-user-output.lua). The " Details: <log>" tail is the
-- secondary part and is cut off before judging. What remains must be at least
-- two sentences, and its LAST sentence (the next step) must:
--   - start with an action word (NEXT_STEP_START below), and
--   - name no command, flag, env var or internal surface: no wsl, podman,
--     --flag, $env:, %VAR%, TILLANDSIAS_, "exit $", and no $variable at all.
--
--   1  self-check: a bare message, a wsl next step, a --flag next step, an
--      $env: next step and an exit-code next step are each REFUSED; two good
--      messages are accepted (a judge that accepts everything fails here)
--   2  cardinality: the Die calls judged equal the raw `Die "` count in the
--      stripped source, and there are at least 10 (a parser that sees nothing
--      cannot pass)
--   3  every Die call in the installer carries a plain next step
--
-- Pre-fix (trunk 20960e4c2): arm 3 FAILS at :239, :790, :913, :959, :1061.
--
-- Usage: tillandsias-plan script run scripts/lua/test-installer-fatal-messages-carry-a-next-step.lua

local SRC = env.get("TILLANDSIAS_INSTALLER_SRC")
if SRC == nil or SRC == "" then SRC = "scripts/install-windows.ps1" end
if not fs.exists(SRC) then
    verdict.emit("could-not-run:installer-fatal-next-step:installer-missing:" .. SRC, 2)
end

local fails, arms = 0, 0
local function check(name, cond, detail)
    arms = arms + 1
    if cond then
        print("ok: " .. name)
    else
        fails = fails + 1
        print("FAIL: " .. name .. (detail and (" -- " .. detail) or ""))
    end
end

local NEXT_STEP_START = {
    "Restart", "Please", "Try", "Check", "Free", "Install", "Open", "Update",
    "Wait", "Connect", "Sign",
}
local FORBIDDEN = {
    { "[Ww][Ss][Ll]", "wsl" },
    { "[Pp][Oo][Dd][Mm][Aa][Nn]", "podman" },
    { "%-%-%a", "a --flag" },
    { "%$", "a variable" },
    { "%%%u+%%", "a %VAR%" },
    { "TILLANDSIAS_", "a TILLANDSIAS_ variable" },
}

-- nil when the message carries a plain next step, else the reason it does not.
local function judge(msg)
    local body = msg
    local d = string.find(body, " Details:", 1, true)
    if d then body = string.sub(body, 1, d - 1) end
    body = text.trim(body)
    local sentences = {}
    for s in string.gmatch(body, "[^%.!]+[%.!]?") do
        s = text.trim(s)
        if s ~= "" then sentences[#sentences + 1] = s end
    end
    if #sentences < 2 then return "one sentence only: says what happened, not what to do" end
    local step = sentences[#sentences]
    local first = string.match(step, "^(%a+)")
    local started = false
    for _, w in ipairs(NEXT_STEP_START) do if first == w then started = true end end
    if not started then return "next step does not start with an action word: " .. step end
    for _, f in ipairs(FORBIDDEN) do
        if string.find(step, f[1]) then return "next step names " .. f[2] .. ": " .. step end
    end
    return nil
end

-- ARM 1: the judge refuses what it must refuse.
local refused = {
    "This Tillandsias release is incomplete, so nothing was installed.",
    "Setup failed. Run wsl --shutdown and try again.",
    "Setup failed. Try again with --debug.",
    "Setup failed. Please set $env:TILLANDSIAS_VERSION and try again.",
    "The download did not start (exit $VerExit). Details: $InstallLog",
}
for i, m in ipairs(refused) do
    check("1 judge refuses sample " .. i, judge(m) ~= nil, m)
end
check("1 judge accepts a plain next step with a log tail",
    judge("The download was damaged, so nothing was installed. Please try again. Details: $InstallLog") == nil)
check("1 judge accepts a restart next step",
    judge("Tillandsias failed its self-check. Restart Windows and run the installer again.") == nil)

-- Comment-stripped source lines, with their line numbers.
local function strip_comment(line)
    local i = 1
    while true do
        local j = string.find(line, "#", i, true)
        if j == nil then return line end
        if j == 1 or string.find(string.sub(line, j - 1, j - 1), "%s") then
            return string.sub(line, 1, j - 1)
        end
        i = j + 1
    end
end

local raw, judged, bad = 0, 0, {}
local in_block = false
local n = 0
for line in string.gmatch(fs.read(SRC) .. "\n", "([^\n]*)\n") do
    n = n + 1
    local code = line
    if in_block then
        if string.find(code, "#>", 1, true) then in_block = false end
        code = ""
    elseif string.find(code, "<#", 1, true) then
        if not string.find(code, "#>", 1, true) then in_block = true end
        code = ""
    end
    local power_user = string.find(line, "# power-user-only", 1, true) ~= nil
    code = strip_comment(code)
    for _ in string.gmatch(code, "Die \"") do
        if not power_user then raw = raw + 1 end
    end
    if not power_user then
        for msg in string.gmatch(code, "Die \"([^\"]*)\"") do
            judged = judged + 1
            local why = judge(msg)
            if why then bad[#bad + 1] = SRC .. ":" .. n .. ": " .. why end
        end
    end
end

-- ARM 2: the parser saw every call.
check("2 every Die call was judged (" .. judged .. " of " .. raw .. ")",
    judged == raw and judged >= 10, "judged=" .. judged .. " raw=" .. raw)

-- ARM 3: the real installer.
check("3 every Die message carries a plain next step", #bad == 0, table.concat(bad, " | "))

if fails > 0 then
    verdict.emit("refused:installer-fatal-next-step:" .. fails .. " of " .. arms .. " arms", 1)
end
verdict.emit("ok:installer-fatal-next-step:" .. arms .. " arms", 0)
