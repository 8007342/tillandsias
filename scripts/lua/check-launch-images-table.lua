-- @trace order:1776-ch4m
-- @env TILLANDSIAS_LAUNCH_IMAGES_SCAN
--
-- check-launch-images-table.lua — a module of the headless crate that names a
-- versioned image it is about to run also ensures that image.
--
-- WHY (1776-ch4m, the operator's live finding 2026-10-17). A forge's first
-- browser.open on a host that never ran --init failed "chromium-framework
-- image missing": browser_open.rs ran `tillandsias-chromium-framework:v...`
-- with pull_never and no ensure, while four inline ensure lists in main.rs
-- had drifted apart. The lists are now one table (launch_images.rs); this
-- guard keeps every image-naming module tied to it.
--
-- A LITERAL is, in production code (test modules are cut out), a
-- `ContainerSpec::new(format!("tillandsias-<name>:v` or a
-- `versioned_image_tag("<name>"`. A module COVERS <name> when:
--   - it names a `LaunchSite::<Site>` whose launch_images.rs list has <name>;
--   - a line of it calling ensure_versioned_images( or ensure_image_exists(
--     quotes "<name>";
--   - <name> is the base `image_dependency` gives a covered image (the seam
--     builds the base itself: forge -> forge-base);
--   - or the literal's line, or the comment block right above it, says
--     `launch-images-ok: <why>`.
-- ZERO literals is a refusal: a guard that found nothing checked nothing.
-- TILLANDSIAS_LAUNCH_IMAGES_SCAN (the crate's src dir) is the fixture seam.
--
-- Verdicts:
--   ok:launch-images-table:modules=<n>:literals=<k>:allowed=<a>   exit 0
--   violation:launch-images-table:sites=<n>                        exit 1
--   refused:launch-images-table:no-literals                        exit 1

local NAME = "launch-images-table"
local SRC = env.get("TILLANDSIAS_LAUNCH_IMAGES_SCAN")
if not SRC or SRC == "" then SRC = "crates/tillandsias-headless/src" end

local function read(f)
    local ok, s = pcall(fs.read, f)
    if ok then return s end
    return nil
end

-- Cut every column-0 `#[cfg(test)] mod <name> {` through its column-0 `}`
-- (rustfmt's shape; brace counting is fooled by braces inside strings),
-- keeping line numbers.
local function production(src)
    local keep, skipping, pending = {}, false, false
    for _, l in ipairs(text.lines(src)) do
        if skipping then
            keep[#keep + 1] = ""
            if l == "}" then skipping = false end
        elseif pending and l:match("^mod%s+[%w_]+%s*{") then
            keep[#keep + 1] = ""
            skipping, pending = true, false
        else
            pending = l == "#[cfg(test)]"
            keep[#keep + 1] = l
        end
    end
    return table.concat(keep, "\n")
end

local function line_of(src, pos)
    local n = 1
    for _ in src:sub(1, pos):gmatch("\n") do n = n + 1 end
    return n
end

-- The table: site -> { name = true }.
local sites = {}
local table_src = read(SRC .. "/launch_images.rs")
if table_src then
    for site, list in production(table_src):gmatch("LaunchSite::(%w+)%s*=>%s*&%[(.-)%]") do
        local names = {}
        for n in list:gmatch('"([%w%-]+)"') do names[n] = true end
        sites[site] = names
    end
end

local ok_walk, files = pcall(fs.walk, SRC)
if not ok_walk or not files then files = {} end

-- The seam's dependency map, from `fn image_dependency`.
local base_of = {}
for _, f in ipairs(files) do
    local src = f:match("%.rs$") and read(f)
    local at = src and src:find("fn image_dependency", 1, true)
    if at then
        local body = src:sub(at):match("^.-(%b{})") or ""
        for img, base in body:gmatch('"([%w%-]+)"%s*=>%s*Some%("([%w%-]+)"%)') do base_of[img] = base end
    end
end

local function marked(lines, i)
    if (lines[i] or ""):find("launch-images-ok:", 1, true) then return true end
    local j = i - 1
    while j >= 1 and lines[j]:match("^%s*//") do
        if lines[j]:find("launch-images-ok:", 1, true) then return true end
        j = j - 1
    end
    return false
end

local modules, literals, allowed, refused = 0, 0, 0, {}
for _, f in ipairs(files) do
    local base = f:match("([^/]+)$") or f
    local raw = f:match("%.rs$") and base ~= "launch_images.rs" and read(f)
    if raw then
        local src = production(raw)
        local found = {}
        for pos, n in src:gmatch('()ContainerSpec::new%(%s*format!%(%s*"tillandsias%-([%w%-]+):v') do
            found[#found + 1] = { pos = pos, name = n }
        end
        for pos, n in src:gmatch('()versioned_image_tag%(%s*"([%w%-]+)"') do
            found[#found + 1] = { pos = pos, name = n }
        end
        if #found > 0 then
            modules = modules + 1
            local covered = {}
            for site in src:gmatch("LaunchSite::(%w+)") do
                for n in pairs(sites[site] or {}) do covered[n] = true end
            end
            local lines = text.lines(src)
            for _, l in ipairs(lines) do
                if l:find("ensure_versioned_images(", 1, true) or l:find("ensure_image_exists(", 1, true) then
                    for n in l:gmatch('"([%w%-]+)"') do covered[n] = true end
                end
            end
            for img in pairs(covered) do
                local b = base_of[img]
                while b and not covered[b] do covered[b] = true; b = base_of[b] end
            end
            for _, lit in ipairs(found) do
                literals = literals + 1
                local i = line_of(src, lit.pos)
                local here = lines[i] or ""
                if covered[lit.name] then
                    -- covered by the table, an ensure line, or a dependency
                elseif marked(lines, i) then
                    allowed = allowed + 1
                else
                    refused[#refused + 1] = f .. ":" .. i .. ": " .. lit.name .. ": " .. text.trim(here)
                end
            end
        end
    end
end

if literals == 0 then
    out.line("why: no image literal was found under " .. SRC .. "; a guard that found nothing checked nothing")
    verdict.emit("refused:" .. NAME .. ":no-literals", 1)
end
if #refused > 0 then
    for _, s in ipairs(refused) do out.line("site: " .. s) end
    out.line("why: this module runs an image it never ensures, so a host that never ran --init fails 'image missing' (1776-ch4m)")
    out.line("remedy: add the image to the module's LaunchSite list in launch_images.rs and ensure that site, or mark the line `launch-images-ok: <why the image is already there>`")
    verdict.emit("violation:" .. NAME .. ":sites=" .. #refused, 1)
end
verdict.emit("ok:" .. NAME .. ":modules=" .. modules .. ":literals=" .. literals .. ":allowed=" .. allowed, 0)
