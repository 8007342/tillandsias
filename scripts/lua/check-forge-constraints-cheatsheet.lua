-- @trace spec:knowledge-source-of-truth
-- @trace order:1816-iyyc
--
-- check-forge-constraints-cheatsheet.lua — the forge-constraints cheatsheet must
-- exist, be listed in cheatsheets/INDEX.md, and state the no-docker rule plus
-- the other hard constraints, so retrieval (tellme grep path, spec index) can
-- answer "can I run docker in the forge". Pre-fix (file absent) this FAILS.
--
--   tillandsias-plan script run scripts/lua/check-forge-constraints-cheatsheet.lua

local SHEET = "cheatsheets/runtime/forge-constraints.md"
local INDEX = "cheatsheets/INDEX.md"

local function has(body, needle) return body:find(needle, 1, true) ~= nil end

local ok_s, sheet = pcall(fs.read, SHEET)
if not ok_s or type(sheet) ~= "string" then
    log.raw("  why: " .. SHEET .. " is absent, so no retrievable chunk says the forge has no docker")
    log.raw("  remedy: author it (see order 1816-iyyc) and run scripts/regenerate-cheatsheet-index.sh")
    verdict.emit("violation:forge-constraints-cheatsheet:absent", 1)
end
local ok_i, index = pcall(fs.read, INDEX)
index = (ok_i and type(index) == "string") and index or ""

local missing = {}
if not has(index, "- forge-constraints.md") then missing[#missing + 1] = "INDEX.md line" end
for _, k in ipairs({
    "NO docker and NO nested container daemon", "--cap-drop=ALL", "no-new-privileges",
    "inference:11434", "127.0.0.1:11436", "proxy:3128", "git mirror",
}) do
    if not has(sheet, k) then missing[#missing + 1] = k end
end
if #missing > 0 then
    for _, m in ipairs(missing) do log.raw("  missing: " .. m) end
    log.raw("  why: the sheet must carry the no-docker statement and be indexed to be retrievable")
    log.raw("  remedy: restore the missing statements; regenerate INDEX.md with scripts/regenerate-cheatsheet-index.sh")
    verdict.emit("violation:forge-constraints-cheatsheet:" .. #missing .. " missing", 1)
end
verdict.emit("ok:forge-constraints-cheatsheet", 0)
