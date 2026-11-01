-- ORDER 1935-m5ps (and 1935-dape, -w558, -9upa, -uaez, -wxpw).
-- Closure probe for the OpenSpec stale-change triage rows: a change is SETTLED
-- when openspec/changes/<name>/ is gone (archived) or every task in its
-- tasks.md is ticked. Prints ok:openspec-change-settled:<name> and exits 0, or
-- refused:openspec-change-settled:<name>:<done>/<total>-ticked and exits 1.
-- Usage: tillandsias-plan script run scripts/lua/probe-openspec-change-settled.lua <name>
local name = arg[1]
if not name or name == "" or name:find("[/.]") then
    verdict.could_not_run("openspec-change-settled", "usage: <change-name>")
end
local dir = "openspec/changes/" .. name
if not fs.exists(dir) then
    verdict.emit("ok:openspec-change-settled:" .. name .. " (archived)", 0)
end
local done, total = 0, 0
local ok, body = pcall(fs.read, dir .. "/tasks.md")
if ok and body then
    for _, l in ipairs(text.lines(body)) do
        if l:match("^%s*[-*] %[[xX]%]") then done = done + 1; total = total + 1
        elseif l:match("^%s*[-*] %[ %]") then total = total + 1 end
    end
end
if total > 0 and done == total then
    verdict.emit("ok:openspec-change-settled:" .. name .. " (" .. done .. "/" .. total .. " ticked)", 0)
end
verdict.emit("refused:openspec-change-settled:" .. name .. ":" .. done .. "/" .. total .. "-ticked", 1)
