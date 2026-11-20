-- @trace order:2119-swiw
--
-- check-in-toolbox-jq.lua — the census of jq call sites in code that runs
-- where jq is NOT installed: inside the tillandsias-nix toolbox, or inside a
-- container image whose Containerfile does not install jq. It must be 0, or
-- each remaining site must carry a named exception below.
--
-- WHY (MEASURED on lenovinha 2026-11-20, 2118-u5b7). The tillandsias-nix toolbox
-- that scripts/nix-toolbox.sh ensures has no jq. scripts/nix-deps-drv-paths.sh,
-- run inside it, printed blocked:nix-deps-drv:no-deps-input although `nix
-- derivation show` succeeded: the jq filter failed and the pipeline yielded
-- nothing. A missing jq looks like an empty answer, not like an error. In the
-- same census the tillandsias-builder toolbox, the host, and the forge, git and
-- vault images all had jq. The inference image has none, and its one jq
-- mention is a comment. New code uses `tillandsias-plan json get`, which takes
-- jq's filter grammar (coordinator ruling 2026-11-20); jq is not added to the
-- toolbox.
--
-- WHAT IS COUNTED
--   (1) every script a repo script runs INSIDE the nix toolbox:
--       `nix-toolbox.sh" run -- [bash] <path>.sh`, followed to its target;
--   (2) every images/<name>/**/*.sh whose images/<name>/Containerfile* does
--       not install jq.
--   A SITE is a non-comment line with `jq` as a command word.
--
-- GRAMMAR (one line on stdout)
--   ok:in-toolbox-jq:toolbox-run=<n>:images-without-jq=<m>:sites=0:exceptions=<k>
--   violation:in-toolbox-jq:<file>:<line>   (one per site, then)
--   violation:in-toolbox-jq:sites=<n>       exit 1
--
-- Usage: tillandsias-plan script run scripts/lua/check-in-toolbox-jq.lua [-- --root DIR]

-- Sites that may remain, each with the reason. Empty today.
local EXCEPTIONS = {
    -- ["images/x/foo.sh"] = "reason",
}

local root = "."
local i = 1
while arg and arg[i] do
    if arg[i] == "--root" and arg[i + 1] then root = arg[i + 1]; i = i + 2 else i = i + 1 end
end
local function p(rel) return root == "." and rel or (root .. "/" .. rel) end

local function jq_sites(body)
    local out = {}
    for n, l in ipairs(text.lines(body or "")) do
        local t = text.trim(l)
        if t:sub(1, 1) ~= "#" then
            local padded = " " .. l .. " "
            -- jq as a command word: preceded by start, space, |, (, $( or ;
            -- and followed by a space or end, never part of a longer name.
            if padded:find("[%s|(;`]jq[%s]") or padded:find('"jq"') then
                out[#out + 1] = n
            end
        end
    end
    return out
end

local sites, report = 0, {}
local function count(rel)
    if EXCEPTIONS[rel] then return 0 end
    local body = fs.exists(p(rel)) and fs.read(p(rel)) or nil
    local found = 0
    for _, n in ipairs(jq_sites(body)) do
        report[#report + 1] = rel .. ":" .. n
        found = found + 1
    end
    sites = sites + found
end

-- (1) toolbox-run targets
local targets, seen = {}, {}
local scan = fs.walk(p("scripts"), { suffix = ".sh" }) or {}
if fs.exists(p("build.sh")) then scan[#scan + 1] = p("build.sh") end
for _, f in ipairs(scan) do
    for _, l in ipairs(text.lines(fs.read(f) or "")) do
        local tgt = l:match('nix%-toolbox%.sh"?%s+run%s+%-%-%s+bash%s+"?([%w%$_{}/.%-]+%.sh)')
            or l:match('nix%-toolbox%.sh"?%s+run%s+%-%-%s+"?([%w%$_{}/.%-]+%.sh)')
        if tgt then
            local rel = tgt:gsub('^%$[{]?[%w_]+[}]?/', ""):gsub("^%./", "")
            if not rel:match("^scripts/") then rel = "scripts/" .. rel:gsub("^.*/scripts/", "") end
            if not seen[rel] then seen[rel] = true; targets[#targets + 1] = rel end
        end
    end
end
for _, rel in ipairs(targets) do count(rel) end

-- (2) images whose Containerfile does not install jq. fs.list returns files
-- only, so walk images/ and group by the first directory under it.
local images_without = 0
local by_image = {}
local order = {}
for _, f in ipairs(fs.walk(p("images"), {}) or {}) do
    local rel = root == "." and f or f:sub(#root + 2)
    local name = rel:match("^images/([^/]+)/")
    if name then
        if not by_image[name] then by_image[name] = { cf = {}, sh = {} }; order[#order + 1] = name end
        local base = path.basename(rel)
        if base:match("^Containerfile") and rel:match("^images/[^/]+/Containerfile") then
            table.insert(by_image[name].cf, rel)
        elseif rel:match("%.sh$") then
            table.insert(by_image[name].sh, rel)
        end
    end
end
table.sort(order)
for _, name in ipairs(order) do
    local img = by_image[name]
    if #img.cf > 0 then
        local installs = false
        for _, cf in ipairs(img.cf) do
            for _, l in ipairs(text.lines(fs.read(p(cf)) or "")) do
                local t = text.trim(l)
                if t:sub(1, 1) ~= "#" and (" " .. t .. " "):find("[%s\\]jq[%s\\]") then installs = true end
            end
        end
        if not installs then
            images_without = images_without + 1
            for _, sh in ipairs(img.sh) do count(sh) end
        end
    end
end

local nexc = 0
for _ in pairs(EXCEPTIONS) do nexc = nexc + 1 end
if sites == 0 then
    out.line(("ok:in-toolbox-jq:toolbox-run=%d:images-without-jq=%d:sites=0:exceptions=%d")
        :format(#targets, images_without, nexc))
    verdict.emit("ok:in-toolbox-jq", 0)
end
for _, r in ipairs(report) do out.line("violation:in-toolbox-jq:" .. r) end
log.raw("why: jq is not installed where these lines run (the tillandsias-nix toolbox, or an image that does not install it); a missing jq reads as an empty answer")
log.raw("remedy: use tillandsias-plan json get (jq filter grammar), or add a named entry to EXCEPTIONS in scripts/lua/check-in-toolbox-jq.lua")
verdict.emit("violation:in-toolbox-jq:sites=" .. sites, 1)
