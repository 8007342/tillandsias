-- @trace order:2080-8i25
--
-- check-workspace-members-used.lua — every workspace member earns its place,
-- and every directory under crates/ is a crate.
--
-- A member passes when ONE of these holds:
--   * another crates/*/Cargo.toml names it as a dependency (any table,
--     dev- and build-dependencies included);
--   * it has a binary target (src/main.rs, src/bin/, or a [[bin]] table);
--   * it is in ALLOWLIST below with a stated reason.
-- A directory under crates/ with no Cargo.toml is refused outright: it is not
-- built, not tested, and documentation that points at it describes code that
-- does not exist (crates/tillandsias-litmus, removed by 2080-8i25).
--
-- A ZERO COUNT IS A FAILURE: a guard that read no members must not print the
-- same verdict as one that read all of them.
--
-- Verdicts:
--   ok:workspace-members-used:<n> members, <a> allowlisted       exit 0
--   refused:workspace-member-unused:<crate>                      one per crate, exit 1
--   refused:crate-dir-without-manifest:<dir>                     one per dir, exit 1
--   refused:workspace-members-used:0                             exit 1
-- Usage: tillandsias-plan script run scripts/lua/check-workspace-members-used.lua [-- ROOT]
local root = arg[1] or "."

-- name -> reason. A reason is a sentence a reader can check, not "keep".
local ALLOWLIST = {
    ["tillandsias-fleet-core"] = "no-I/O score core designed to build unchanged for wasm32 and run in the Cloudflare Worker rendezvous (1548-9n28); its consumers are not in this workspace yet",
}

local function read(path)
    local ok, src = pcall(fs.read, path)
    if ok then return src end
    return nil
end

local top = read(root .. "/Cargo.toml")
if not top then verdict.refused("workspace-members-used:no-root-manifest") end

-- [workspace] members = [ ... ]
local members = {}
local block = top:match("%[workspace%].-members%s*=%s*(%b[])")
for m in (block or ""):gmatch('"([^"]+)"') do members[#members + 1] = m end
if #members == 0 then
    log.raw("  no workspace members were read from Cargo.toml — this guard inspected nothing")
    verdict.refused("workspace-members-used:0")
end

-- package name per member, and every member manifest's text
local pkg, manifests = {}, {}
for _, m in ipairs(members) do
    local src = read(root .. "/" .. m .. "/Cargo.toml") or ""
    manifests[m] = src
    local pkgblock = src:match("%[package%](.-)\n%[") or src:match("%[package%](.*)$") or ""
    pkg[m] = pkgblock:match('\nname%s*=%s*"([^"]+)"') or m:match("([^/]+)$")
end

local function escape(s) return (s:gsub("%W", "%%%0")) end

local function depended_on(m)
    local name = escape(pkg[m])
    for other, src in pairs(manifests) do
        if other ~= m then
            for _, line in ipairs(text.lines(src)) do
                local l = line:gsub("#.*$", "")
                if l:match("^%s*" .. name .. "%s*=") or l:match('package%s*=%s*"' .. name .. '"')
                    or l:match("^%[[%w%-%.]*dependencies%." .. name .. "%]") then
                    return true
                end
            end
        end
    end
    return false
end

local function has_bin(m)
    local dir = root .. "/" .. m
    if fs.exists(dir .. "/src/main.rs") or fs.exists(dir .. "/src/bin") then return true end
    return manifests[m]:match("\n%[%[bin%]%]") ~= nil
end

local bad, allowed = {}, 0
for _, m in ipairs(members) do
    if not (depended_on(m) or has_bin(m)) then
        if ALLOWLIST[pkg[m]] then
            allowed = allowed + 1
        else
            bad[#bad + 1] = "refused:workspace-member-unused:" .. pkg[m]
        end
    end
end

-- fs.list returns FILES only, so the directories come from fs.walk's paths:
-- the first component under crates/ of every file is a crate directory.
local ok_walk, files = pcall(fs.walk, root == "." and "crates" or (root .. "/crates"))
local dirs, ndirs = {}, 0
for _, f in ipairs(ok_walk and files or {}) do
    local name = f:gsub("\\", "/"):match("crates/([^/]+)/")
    if name and not dirs[name] then dirs[name] = true; ndirs = ndirs + 1 end
end
if ndirs == 0 then
    log.raw("  no directories were found under crates/ — this guard inspected nothing")
    verdict.refused("workspace-members-used:0")
end
for name in pairs(dirs) do
    if not fs.exists(root .. "/crates/" .. name .. "/Cargo.toml") then
        bad[#bad + 1] = "refused:crate-dir-without-manifest:crates/" .. name
    end
end

table.sort(bad)
if #bad > 0 then
    for i = 1, #bad - 1 do out.line(bad[i]) end
    verdict.emit(bad[#bad], 1)
    return
end
verdict.ok("workspace-members-used", #members .. " members, " .. allowed .. " allowlisted")
