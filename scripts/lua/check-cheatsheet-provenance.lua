-- @env PATH HOME
-- @trace order:2080-kkki, order:588-8mh8, spec:cheatsheet-source-layer
--
-- check-cheatsheet-provenance.lua — every cheatsheet staged into the forge image carries a
-- `## Provenance` section, except the ones the floor lists, and the floor only shrinks.
--
-- WHY (2080-kkki, child of 588-8mh8). The experts treat cheatsheets as ground truth, and a sheet
-- with no provenance is an uncitable claim that looks covered. On 2026-11-27, 28 of the 254
-- staged sheets had no Provenance section and the source check exited zero: nothing refused them.
-- RULING (coordinator, 2026-11-27): a ratchet. Today's 28 are the floor; a NEW sheet without
-- provenance is refused; a floor entry that now has provenance (or is gone) is refused too, so the
-- floor can only shrink.
--
-- Scope: images/default/cheatsheets/**/*.md, the staged copy that reaches the forge (the authored
-- tree is held equal to it by scripts/stage-image-cheatsheets.sh). INDEX.md, TEMPLATE.md and
-- README.md are not sheets.
--
-- Usage: tillandsias-plan script run scripts/lua/check-cheatsheet-provenance.lua [-- --root DIR --floor FILE]
-- Verdict: ok:cheatsheet-provenance:<n> sheets <f> on the floor | violation:cheatsheet-provenance:<n>

local NAME = "cheatsheet-provenance"
local root, floorf = "images/default/cheatsheets", "scripts/portability/cheatsheet-no-provenance-floor.txt"
do
    local i = 1
    while arg and arg[i] do
        if arg[i] == "--root" then root = arg[i + 1]; i = i + 2
        elseif arg[i] == "--floor" then floorf = arg[i + 1]; i = i + 2
        else i = i + 1 end
    end
end
local EXEMPT = { ["INDEX.md"] = true, ["TEMPLATE.md"] = true, ["README.md"] = true }
local okw, files = pcall(fs.walk, root, { suffix = ".md" })
if not okw or not files or #files == 0 then verdict.could_not_run(NAME, "no sheets under " .. root) end

local floor, floor_n = {}, 0
for l in ((fs.exists(floorf) and fs.read(floorf)) or ""):gmatch("[^\n]+") do
    if not l:match("^%s*#") and l:match("%S") then floor[text.trim(l)] = true; floor_n = floor_n + 1 end
end

local bad, seen, n = {}, {}, 0
for _, f in ipairs(files) do
    local rel = f:sub(#root + 2)
    if not EXEMPT[rel:match("([^/]+)$")] then
        n = n + 1
        seen[rel] = true
        local has = ("\n" .. (fs.read(f) or "")):find("\n## Provenance", 1, true) ~= nil
        if not has and not floor[rel] then
            bad[#bad + 1] = "no-provenance: " .. rel .. " (a sheet the forge reads has no ## Provenance section, and the floor does not list it)"
        elseif has and floor[rel] then
            bad[#bad + 1] = "floor-stale: " .. rel .. " has a Provenance section now: delete its line from " .. floorf .. " (the floor only shrinks)"
        end
    end
end
for rel in pairs(floor) do
    if not seen[rel] then bad[#bad + 1] = "floor-stale: " .. rel .. " is no longer a staged sheet: delete its line from " .. floorf end
end
table.sort(bad)
for _, b in ipairs(bad) do out.line("REFUSED: " .. b) end
if #bad > 0 then
    out.line("  why: a cheatsheet without provenance is an uncitable claim the experts read as ground truth (2080-kkki)")
    out.line("  remedy: add a ## Provenance section naming the sheet's sources; for a floor-stale line, delete it from the floor")
    verdict.emit("violation:" .. NAME .. ":" .. #bad, 1)
end
verdict.ok(NAME, n .. " sheets " .. floor_n .. " on the floor")
