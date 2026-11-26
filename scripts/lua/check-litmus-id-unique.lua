-- @env PATH HOME
-- @trace order:2402-mw57
--
-- check-litmus-id-unique.lua — every litmus test's declared `name:` is its own: no two files
-- declare the same id, and each file declares the id its filename implies
-- (litmus:<x> lives in openspec/litmus-tests/litmus-<x>.yaml, which is how the runner resolves it).
--
-- WHY (2402-mw57). Two files declared `litmus:litmus-stdlib-portability-shape`. The runner resolves an id
-- to litmus-<x>.yaml, so it loaded one of them and the other's four steps never ran: a test that
-- reads as present in the corpus and asserts nothing. A duplicate id is always this case, because
-- at most one of the two files can be the one the id resolves to.
--
-- A file with no `name:` at all is reported as a note, not refused: it is not a litmus test of
-- this schema, and whether it is dead is a separate question.
--
-- Usage: tillandsias-plan script run scripts/lua/check-litmus-id-unique.lua [-- <dir>]
-- Verdict: ok:litmus-id-unique:<n> checked | violation:litmus-id-unique:<n>

local NAME = "litmus-id-unique"
local DIR = (arg and arg[1]) or "openspec/litmus-tests"
local ok_list, files = pcall(fs.list, DIR)
if not ok_list then verdict.could_not_run(NAME, "cannot list " .. DIR) end
table.sort(files)
local by_id, bad, n = {}, {}, 0
for _, f in ipairs(files) do
    if f:match("^litmus%-.+%.ya?ml$") then
        local body = fs.read(DIR .. "/" .. f)
        local id = ("\n" .. body):match("\nname:[ \t]*\"?([^\"\n#]-)\"?[ \t]*\n")
        if not id or id == "" then
            out.line("note:" .. NAME .. ":unnamed:" .. DIR .. "/" .. f)
        else
            n = n + 1
            by_id[id] = by_id[id] or {}
            table.insert(by_id[id], f)
            local want = "litmus:" .. f:gsub("^litmus%-", ""):gsub("%.ya?ml$", "")
            if id ~= want then
                bad[#bad + 1] = "REFUSED: " .. DIR .. "/" .. f .. " declares " .. id .. " but the runner resolves that id to "
                    .. DIR .. "/litmus-" .. id:gsub("^litmus:", "") .. ".yaml; this file would be " .. want
            end
        end
    end
end
local ids = {}
for id in pairs(by_id) do ids[#ids + 1] = id end
table.sort(ids)
for _, id in ipairs(ids) do
    local fl = by_id[id]
    if #fl > 1 then
        bad[#bad + 1] = "REFUSED: " .. id .. " is declared by " .. #fl .. " files (" .. table.concat(fl, ", ")
            .. "); the runner loads one and the others never run"
    end
end
for _, l in ipairs(bad) do out.line(l) end
if #bad > 0 then
    out.line("  remedy: merge the declarations into the file the id resolves to, or give the other file its own id")
    verdict.emit("violation:" .. NAME .. ":" .. #bad, 1)
end
verdict.ok(NAME, n .. " checked")
