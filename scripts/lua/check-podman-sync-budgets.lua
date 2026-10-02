-- @env PODMAN_SYNC_SEARCH_ROOT PODMAN_SYNC_ESCAPE_HATCHES
-- @read-env PODMAN_SYNC_SEARCH_ROOT
-- @trace spec:podman-orchestration, order:1533-ew3n
-- Lua-authoritative source scan.  The root is intentionally repo-relative;
-- fixtures set TILLANDSIAS_REPO_ROOT to their throwaway tree.
local root = env.get("PODMAN_SYNC_SEARCH_ROOT") or "crates"
local raw_allowed = env.get("PODMAN_SYNC_ESCAPE_HATCHES")
if raw_allowed == nil or raw_allowed == "" then raw_allowed = "1" end
if not text.is_match(raw_allowed, "^-?[0-9]+$") then
    verdict.emit("blocked:podman-sync-bounded:invalid-escape-hatches:" .. raw_allowed, 2)
end
local allowed = tonumber(raw_allowed)
local files
if root:sub(1, 1) == "/" then
    -- `fs.walk` deliberately refuses external starts.  Preserve the historical
    -- explicit-root seam with one typed, argv-only listing; Lua still owns every
    -- filter, verdict and source read (which is limited by @read-env above).
    local listed = proc.run({ argv = { "find", root, "-type", "f", "-name", "*.rs" }, timeout_ms = 30000 })
    if not listed.ok then
        verdict.emit("blocked:podman-sync-bounded:search-root-unreadable:" .. root, 2)
    end
    files = {}
    for _, file in ipairs(text.lines(listed.stdout or "")) do files[#files + 1] = file end
else
    files = fs.walk(root, { suffix = ".rs" })
end
local function raw_lines(s)
    local out = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    if s:sub(-1) == "\n" then out[#out] = nil end
    return out
end
local function lines_matching(pattern, filter, include_tests)
    local matches = {}
    for _, file in ipairs(files) do
        if include_tests or not text.is_match(file, [[/tests?/]]) then
            local ok, source = pcall(fs.read, file)
            if ok then
                local normalized, raw = text.lines(source), raw_lines(source)
                for n, line in ipairs(normalized) do
                    if text.is_match(line, pattern) and (not filter or filter(file, line)) then
                        matches[#matches + 1] = file .. ":" .. n .. ":" .. raw[n]
                    end
                end
            end
        end
    end
    return matches
end
local direct = lines_matching([=[Command::new\((")?[^)]*podman]=], function(file, line)
    return not text.is_match(line, [=[^[[:space:]]*//]=]) and not line:find("source.contains", 1, true)
        and not line:find("fn podman_cmd_sync_std", 1, true) and not file:find("src/lib.rs", 1, true)
end)
if #direct > 0 then
    for _, line in ipairs(direct) do log.raw(line) end
    verdict.emit("violation:direct-command:" .. #direct, 1)
end
local hatches = lines_matching([=[spawn_caller_owned_lifetime\(\)]=], function(_, line)
    return not line:find("pub fn spawn_caller_owned_lifetime", 1, true)
end, true)
if #hatches > allowed then
    log.raw("expected at most " .. allowed .. " caller-owned spawn(s); found " .. #hatches .. ":")
    for _, line in ipairs(hatches) do log.raw(line) end
    verdict.emit("violation:escape-hatch-grew:" .. #hatches, 1)
end
local capture = lines_matching("read_to_end", function(file, line)
    return file:find("tillandsias-podman/src/", 1, true) and not text.is_match(line, [=[^[[:space:]]*//]=])
end)
if #capture > 0 then
    for _, line in ipairs(capture) do log.raw(line) end
    verdict.emit("violation:unbounded-capture:" .. #capture, 1)
end
local sleep = lines_matching([=[(^|[^[:alnum:]_])(std::)?thread::sleep[[:space:]]*\(]=], function(file, line)
    return file:find("tillandsias-podman/src/", 1, true) and not text.is_match(line, [=[^[[:space:]]*(//|/\*|\*)]=])
        and not line:find("source.contains", 1, true)
end)
if #sleep > 0 then
    for _, line in ipairs(sleep) do log.raw(line) end
    verdict.emit("violation:sleep-poll:" .. #sleep, 1)
end
verdict.emit("ok:podman-sync-bounded:" .. #hatches, 0)
