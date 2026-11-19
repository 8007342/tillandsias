-- @trace spec:cheatsheet-source-layer, order:2090-ausx
--
-- check-cheatsheet-sources.lua — validate cheatsheet <-> verbatim-source binding.
-- (Ported from scripts/check-cheatsheet-sources.sh, which was a wrapper over the
-- Rust `tillandsias-policy check-cheatsheet-sources` subcommand; the shell-to-lua
-- item the 2090-ausx gate step carried. History: `git log -- scripts/check-cheatsheet-sources.sh`.)
--
-- Usage:
--   tillandsias-plan script run scripts/lua/check-cheatsheet-sources.lua -- [--no-sha]
--
-- Checks (per §5 of docs/strategy/cheatsheet-source-layer-plan.md):
--   1. For every cheatsheet's ## Provenance URL: must be in INDEX.json
--      (WARNING if unfetched — not yet blocking).
--   2. For every local: path in ## Provenance: file exists OR sidecar has
--      redistribution: do-not-bundle / manual-review-required.
--   3. Orphan detection: every INDEX.json entry must be cited by at least
--      one cheatsheet (WARNING, not ERROR — new fetches may not be cited yet).
--   4. SHA-check: re-hash present files, compare to INDEX.json manifest
--      (skip with --no-sha for speed in pre-commit contexts).
--
-- Fails only on ERROR-level findings; warnings never change the exit.
--
-- Grammar (ONE verdict line on stdout; the findings are on stderr):
--   ok:cheatsheet-sources-retired                          exit 0 (tombstone, no INDEX.json)
--   skip:cheatsheet-sources-not-fetched                    exit 0 (no INDEX.json, no tombstone)
--   ok:cheatsheet-sources:<n>-cheatsheets-<m>-local-<k>-sha-<w>-warnings   exit 0
--   refused:cheatsheet-sources:<n>-errors                  exit 1 (also unreadable/invalid INDEX.json)
--   could-not-run:cheatsheet-sources (reason on stderr)    exit 3 (not a work tree, unknown argument)

local NO_SHA = false
for _, a in ipairs(arg or {}) do
    if a == "--no-sha" then
        NO_SHA = true
    else
        verdict.could_not_run("cheatsheet-sources", "unknown-argument:" .. a .. " (usage: [--no-sha])")
    end
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("cheatsheet-sources", "not-a-git-work-tree")
end

local function read_file(p)
    local ok, body = pcall(fs.read, p)
    if ok and body then return body end
    return nil
end

local INDEX = ROOT .. "/cheatsheet-sources/INDEX.json"
local TOMB = ROOT .. "/cheatsheet-sources/.gitkeep-tombstone"

-- TWO REASONS INDEX.json CAN BE ABSENT, AND THEY MEAN OPPOSITE THINGS (order 372,
-- 2026-08-25): "not fetched yet" (migration; fetch is right) vs "deliberately
-- retired" (tombstone; fetching would UNDO the retirement). The tombstone is a
-- file, so the distinction is machine-decidable.
local index_text = read_file(INDEX)
if not index_text then
    if read_file(TOMB) ~= nil then
        log.raw("  the verbatim source layer was retired (see cheatsheet-sources/.gitkeep-tombstone); there is no INDEX.json to validate and there should not be one.")
        log.raw("  Replacement: image-baked /opt/cheatsheet-sources/ (bundled tier) and the per-project pull cache. Do NOT re-fetch into cheatsheet-sources/.")
        verdict.ok("cheatsheet-sources-retired")
    end
    log.raw("  " .. INDEX .. " does not exist - no sources fetched yet; nothing to validate")
    log.raw("  Run: scripts/fetch-cheatsheet-source.sh <URL> --cite cheatsheets/<path>")
    verdict.emit("skip:cheatsheet-sources-not-fetched", 0)
end

local parsed_ok, index = pcall(json.parse, index_text)
if not parsed_ok or type(index) ~= "table" then
    log.raw("ERROR: " .. INDEX .. " is not valid JSON")
    verdict.emit("refused:cheatsheet-sources:index-not-valid-json", 1)
end
local entries = {}
if type(index.entries) == "table" then
    for _, e in ipairs(index.entries) do
        if type(e) == "table" then entries[#entries + 1] = e end
    end
end

local function str(e, k)
    local v = e[k]
    if type(v) == "string" then return v end
    return ""
end

-- url_set: union of url/fetch_url/final_redirect values.
local url_set = {}
for _, e in ipairs(entries) do
    for _, k in ipairs({ "url", "fetch_url", "final_redirect" }) do
        local u = str(e, k)
        if u ~= "" then url_set[u] = true end
    end
end

-- Provenance parsing (faithful to the former Python extract_provenance).
local function contains(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

local function extract_angle_urls(line, urls)
    local i = 1
    while i <= #line do
        if line:sub(i, i) == "<" and line:sub(i + 1, i + 8) == "https://" then
            local close = line:find(">", i + 1, true)
            if close then
                local u = line:sub(i + 1, close - 1)
                if u ~= "" then urls[#urls + 1] = u end
                i = close + 1
                goto continue
            end
        end
        i = i + 1
        ::continue::
    end
end

local function extract_bare_urls(line, urls)
    local search = 1
    while true do
        local start = line:find("https://", search, true)
        if not start then return end
        local prev = start > 1 and line:sub(start - 1, start - 1) or ""
        if prev == "<" or prev == "`" then
            search = start + 8
            goto continue
        end
        do
            local scheme_end = start + 8 -- first byte after the scheme
            if scheme_end > #line or line:sub(scheme_end, scheme_end):match("%s") then
                search = math.max(scheme_end, start + 1)
                goto continue
            end
            -- the mandatory first char, then \S+ up to , > ) or whitespace
            local stop = scheme_end + 1
            while stop <= #line do
                local c = line:sub(stop, stop)
                if c:match("%s") or c == "," or c == ">" or c == ")" then break end
                stop = stop + 1
            end
            local u = line:sub(start, stop - 1):gsub("[%.,%)]+$", "")
            if u ~= "" and not contains(urls, u) then urls[#urls + 1] = u end
            search = math.max(stop, start + 1)
        end
        ::continue::
    end
end

local function extract_local_path(line)
    local s, e = line:find("local:", 1, true)
    if not s then return nil end
    local after = line:sub(e + 1):gsub("^%s+", "")
    if after:sub(1, 1) ~= "`" then return nil end
    local close = after:find("`", 2, true)
    if not close then return nil end
    local p = after:sub(2, close - 1)
    if p == "" then return nil end
    return p
end

local function extract_provenance(body)
    local urls, locals_ = {}, {}
    local in_prov = false
    for _, raw in ipairs(text.lines(body)) do
        local stripped = text.trim(raw)
        if stripped:match("^##%s+Provenance") then
            in_prov = true
        elseif in_prov and stripped:match("^##%s") then
            in_prov = false
        elseif in_prov then
            extract_angle_urls(stripped, urls)
            extract_bare_urls(stripped, urls)
            local lp = extract_local_path(stripped)
            if lp then locals_[#locals_ + 1] = lp end
        end
    end
    return urls, locals_
end

local function read_redistribution(meta)
    local body = read_file(meta)
    if not body then return "" end
    for _, line in ipairs(text.lines(body)) do
        local rest = line:gsub("%s+$", ""):match("^redistribution:(.*)$")
        if rest then return rest:match("^%s*(%S+)") or "" end
    end
    return ""
end

local mds = {}
local walk_ok, walked = pcall(fs.walk, ROOT .. "/cheatsheets", { suffix = ".md" })
if walk_ok and walked then
    for _, p in ipairs(walked) do
        local name = p:match("([^/]+)$") or p
        if name ~= "INDEX.md" and name ~= "TEMPLATE.md" then mds[#mds + 1] = p end
    end
end
table.sort(mds)

local errors, warnings = {}, {}
local cited = {}
local checked_urls, checked_local = 0, 0

for _, p in ipairs(mds) do
    local rel = p:sub(1, #ROOT + 1) == ROOT .. "/" and p:sub(#ROOT + 2) or p
    local body = read_file(p)
    if body then
        local urls, locals_ = extract_provenance(body)
        for _, u in ipairs(urls) do
            checked_urls = checked_urls + 1
            if not url_set[u] then
                warnings[#warnings + 1] = "UNFETCHED: " .. rel .. ": URL not in INDEX.json: " .. u
            end
        end
        for _, lp in ipairs(locals_) do
            checked_local = checked_local + 1
            cited[lp] = true
            if read_file(ROOT .. "/" .. lp) == nil then
                local meta = ROOT .. "/" .. lp .. ".meta.yaml"
                if read_file(meta) ~= nil then
                    local redist = read_redistribution(meta)
                    if redist ~= "do-not-bundle" and redist ~= "manual-review-required" then
                        errors[#errors + 1] = "MISSING FILE: " .. rel .. ": local: path has sidecar but no verbatim file and redistribution is '" .. redist .. "': " .. lp
                    end
                else
                    errors[#errors + 1] = "MISSING: " .. rel .. ": local: path does not exist (no file, no sidecar): " .. lp
                end
            end
        end
    end
end

-- Check 3: orphan detection.
for _, e in ipairs(entries) do
    local lp = str(e, "local_path")
    if lp ~= "" then
        local cited_by = type(e.cited_by) == "table" and #e.cited_by > 0
        if not cited[lp] and not cited_by then
            warnings[#warnings + 1] = "ORPHAN: " .. lp .. " is in INDEX.json but not cited by any cheatsheet"
        end
    end
end

-- Check 4: SHA-256 verification.
local sha_ok = 0
if not NO_SHA then
    for _, e in ipairs(entries) do
        local lp, expected = str(e, "local_path"), str(e, "content_sha256")
        if lp ~= "" and expected ~= "" then
            local body = read_file(ROOT .. "/" .. lp)
            if body then -- absent (do-not-bundle / not fetched): skip
                local actual = hash.sha256(body)
                if actual ~= expected then
                    errors[#errors + 1] = "SHA MISMATCH: " .. lp .. ": expected " .. expected:sub(1, 16) .. "... got " .. actual:sub(1, 16) .. "... (content modified after fetch)"
                else
                    sha_ok = sha_ok + 1
                end
            end
        end
    end
end

log.raw(string.format("check-cheatsheet-sources: %d cheatsheets, %d INDEX entries, %d provenance URLs, %d local: paths checked%s",
    #mds, #entries, checked_urls, checked_local, NO_SHA and " (SHA check skipped)" or (", " .. sha_ok .. " SHA verifications")))
if #warnings > 0 then
    log.raw("Warnings (" .. #warnings .. "):")
    for _, w in ipairs(warnings) do log.raw("  WARNING: " .. w) end
end
if #errors > 0 then
    log.raw("Errors (" .. #errors .. "):")
    for _, er in ipairs(errors) do log.raw("  ERROR: " .. er) end
    verdict.emit("refused:cheatsheet-sources:" .. #errors .. "-errors", 1)
end
verdict.ok("cheatsheet-sources", #mds .. "-cheatsheets-" .. checked_local .. "-local-" .. sha_ok .. "-sha-" .. #warnings .. "-warnings")
