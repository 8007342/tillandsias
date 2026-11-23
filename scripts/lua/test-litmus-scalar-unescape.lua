-- @trace spec:litmus-framework, order:2282-peuy, order:875-v7hv
--
-- test-litmus-scalar-unescape.lua — run-litmus-test.sh reads a step's fields with
-- bash regexes, which capture the RAW BYTES of a double-quoted YAML scalar. Every
-- such field must go through yaml_unescape_dq: a failure_pattern carrying \" that
-- is not unescaped can never match, so a real failure reports green.
--   A SEMANTICS  the shipped function, loaded by name, over escaped inputs
--   B CONTROL    a wrong-order copy answers differently on the ordering input
--   C ROUTING    each double-quoted field goes through the helper, none keeps a
--                raw capture; the PLAIN expected_behavior branch stays raw
--                (an unquoted YAML scalar has no escape sequences)
--
-- Verdict: ok:litmus-scalar-unescape | violation:litmus-scalar-unescape

local fixture = require "common.fixture"
local T = fixture.new("litmus-scalar-unescape")
local src = fs.read("scripts/run-litmus-test.sh")

-- The REAL function, so this cannot drift into testing a copy.
local fn, inside = {}, false
for _, l in ipairs(text.lines(src)) do
    if l:find("^yaml_unescape_dq%(%) %{") then inside = true end
    if inside then
        fn[#fn + 1] = l
        if l:find("^%}") then break end
    end
end
if #fn == 0 then T:refuse("helper-absent", "yaml_unescape_dq not defined in run-litmus-test.sh") end
local FN = table.concat(fn, "\n") .. "\n"
local function call(body, input)
    -- By env, never argv: native msys drops double quotes from argv (yolanda, #1451).
    local r = T:run{ fixture.posix_shell(), "-s", stdin = body .. 'yaml_unescape_dq "$IN"\n', env = { IN = input } }
    return r.code == 0 and (r.stdout or "") or ("rc=" .. tostring(r.code) .. " " .. tostring(r.stderr))
end
local function check(label, input, want)
    local got = call(FN, input)
    T:arm("A " .. label, got == want, "[" .. got .. "] want [" .. want .. "]")
end
check("an escaped quote becomes a quote", [[a\"b]], [[a"b]])
check("an escaped backslash becomes one", [[a\\b]], [[a\b]])
check("plain text is untouched", "abc def", "abc def")
check("the empty string is untouched", "", "")
check("a real-world grep pattern survives", [[grep -F 'x(\"k\".to_string())']], [[grep -F 'x("k".to_string())']])
check("ordering: an escaped backslash before a quote keeps the quote literal", [[x\\"y]], [[x\"y]])

local WRONG = [[yaml_unescape_dq() { local s="$1"; s="${s//\\\\/\\}"; s="${s//\\\"/\"}"; printf '%s' "$s"; }
]]
local w, g = call(WRONG, [[x\\"y]]), call(FN, [[x\\"y]])
T:arm("B a wrong-order unescape gives a different answer", w == [[x"y]] and w ~= g, w .. " vs " .. g)

local function count(field, rhs)
    local n = 0
    for _, l in ipairs(text.lines(src)) do
        if l:find("^%s*" .. field .. rhs) then n = n + 1 end
    end
    return n
end
local DQ, RAW = '="%$%(yaml_unescape_dq ', '="%${BASH_REMATCH%[1%]}"%s*$'
for _, f in ipairs({ "current_step_command", "current_step_success_pattern", "current_step_failure_pattern" }) do
    T:arm("C " .. f .. " is unescaped through the helper", count(f, DQ) >= 1, count(f, DQ))
    T:arm("C " .. f .. " has no raw capture", count(f, RAW) == 0, count(f, RAW))
end
T:arm("C one double-quoted expected_behavior branch, unescaped", count("current_step_expected", DQ) == 1, count("current_step_expected", DQ))
T:arm("C one PLAIN expected_behavior branch, raw", count("current_step_expected", RAW) == 1, count("current_step_expected", RAW))
T:finish()
