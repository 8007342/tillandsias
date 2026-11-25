-- @env PATH HOME
-- @trace order:1401-bcd7, order:2349-b3u2
--
-- test-json-get-help-names-its-subset.lua — every line of `tillandsias-plan json get --help`
-- holds against the parser. Ported from the .sh of the same name (2349-b3u2).
--
--   1 --help, -h and `json --help` print one text     2 `yaml get --help` names yaml
--   3 every flag has a help line                      4 every supported form is named and parses
--   5 every refused form is named and exits 3 unsupported
--   6 every filter reshape parses
--
-- Usage: tillandsias-plan script run scripts/lua/test-json-get-help-names-its-subset.lua
-- Verdict: ok:json-get-help-names-its-subset:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("json-get-help-names-its-subset")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local function plan(...)
    local r = proc.run{ argv = { PLAN, ... }, cwd = ROOT, stdin = "", env_unset = { "TILLANDSIAS_*" }, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, timeout_ms = 30000 }
    return r.code, r.stdout or "", (r.stdout or "") .. (r.stderr or "")
end
local rc, help = plan("json", "get", "--help")
local rs, short = plan("json", "get", "-h")
local rb, bare = plan("json", "--help")
T:arm("0 PREMISE the help names what is supported and what is refused", text.contains(help, "supported:") and text.contains(help, "refused"), help)
T:arm("1 --help, -h and json --help exit 0 with one text", rc == 0 and rs == 0 and rb == 0 and short == help and bare == help, "rc=" .. tostring(rc) .. "," .. tostring(rs) .. "," .. tostring(rb))
local _, y = plan("yaml", "get", "--help")
T:arm("2 yaml get --help names yaml and not json get", text.contains(y, "tillandsias-plan yaml get") and text.contains(y, "over yaml input") and not text.contains(y, "json get"), y:sub(1, 200))
local function none(name, missing) T:arm(name, #missing == 0, table.concat(missing, " ")) end
local m = {}
for _, f in ipairs{ "-r, --raw-output", "-c, --compact-output", "-e, --exit-status", "-n, --null-input", "-s, --slurp", "-M", "--arg k v", "--argjson k v", "--parse-only", "-h, --help", "reads stdin" } do
    if not text.contains(help, f) then m[#m + 1] = "[" .. f .. "]" end
end
none("3 every flag has a help line", m)
-- rows: { form as the help spells it, filter to parse (default: the form) }
local function supported(name, rows)
    local miss = {}
    for _, r in ipairs(rows) do
        local form, probe = r[1], r[2] or r[1]
        if not text.contains(help, form) then miss[#miss + 1] = "[help:" .. form .. "]"
        else
            local c, _, o = plan("json", "get", "--parse-only", probe)
            if c ~= 0 then miss[#miss + 1] = "[parse:" .. probe .. " rc=" .. tostring(c) .. " " .. o .. "]" end
        end
    end
    none(name, miss)
end
supported("4 every supported form is named and parses", { { ".a.b" }, { '.["x-y"]' }, { ".a[-1]" }, { ".[$k]" }, { "keys[]" }, { ".a[]?" }, { '.a // "default"' }, { "[.a[] | .k]" },
    { "select(f)", "select(.a == 1)" }, { "has(k)", 'has("a")' }, { "keys_unsorted" }, { "ascii_downcase" }, { "tostring" } })
m = {}
for _, r in ipairs{ { 'join(",")', 'join(",")' }, { [["\(.a) \(.b)"]], [["\(.a)"]] }, { "{a: .a}", "{a: .a}" }, { "map(f)", "map(.a)" }, { "arithmetic", ".a + 1" },
    { "if/then/else", "if . then 1 else 2 end" }, { ". as $v", ". as $v | $v" }, { "slices .[1:3]", ".[1:3]" }, { "@csv", "@csv" }, { "test split startswith contains ltrimstr", 'test("a")' },
    { "first last", "first" }, { "sort unique", "sort" }, { "to_entries values", "to_entries" }, { "any", "any" }, { "..  reduce  def  try", ".." } } do
    if not text.contains(help, r[1]) then m[#m + 1] = "[help:" .. r[1] .. "]"
    else
        local c, _, o = plan("json", "get", "--parse-only", r[2])
        if c ~= 3 or o:sub(1, 12) ~= "unsupported:" then m[#m + 1] = "[refuse:" .. r[2] .. " rc=" .. tostring(c) .. " " .. o .. "]" end
    end
end
none("5 every refused form is named and refused as unsupported", m)
supported("6 every filter reshape parses", { { "[.[] | f]", "[.[] | .a]" }, { "[.a, .b]" }, { ".[0]" }, { "[.[] | select(cond)] | length > 0", "[.[] | select(.a)] | length > 0" } })
T:finish()
