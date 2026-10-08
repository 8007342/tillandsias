-- @trace order:1053-a7qr, order:1526-gv3t
--
-- check-cheatsheet-source-anchors.lua — PORTED from
-- check-cheatsheet-source-anchors.sh, byte for byte, including its exact
-- per-violation stdout lines. A cheatsheet `sources:` anchor of the form
-- `<file> order:<id>` must name a file that EXISTS and that DECLARES that
-- order (`^ *order: *"?<id>"?( |$)`, not merely mentions it in prose — see
-- the .sh's header for the 804-ckst incident this exists to catch).
--
-- Authored cheatsheets only (cheatsheets/, not the derived
-- images/default/cheatsheets/ copy).
--
-- WHAT THE PORT MAKES UNREPRESENTABLE RATHER THAN AVOIDS: nothing — the .sh
-- already printed one `violation:cheatsheet-source-anchor:...` stdout line
-- PER bad anchor, in encounter order, with no separate summary line. This
-- port reproduces that exactly: every violation but the last is printed with
-- out.line, and the LAST one is the runner's own verdict line (verdict.emit),
-- so the total stdout line count and content are unchanged from the .sh.
--
-- Grammar (one line per violation on stdout, unchanged):
--   ok:cheatsheet-source-anchors:<n> checked
--   violation:cheatsheet-source-anchor:<file>:<anchor> — <reason>
local function split_entry(entry)
    local first_s = entry:find(" order:", 1, true)
    local file = entry:sub(1, first_s - 1)
    local pos, last_e = 1, nil
    while true do
        local s, e = entry:find(" order:", pos, true)
        if not s then break end
        last_e = e
        pos = e + 1
    end
    local ord = entry:sub(last_e + 1)
    return file, ord
end

-- The awk state machine, ported line for line: `sources:` opens the block,
-- any other top-level `key:` line closes it, and each `  - ` item inside it
-- that contains " order:" (after the leading "- " is stripped) is an entry.
local function source_entries(content)
    local entries = {}
    local in_src = false
    for _, l in ipairs(text.lines(content)) do
        if text.is_match(l, [=[^sources:]=]) then
            in_src = true
        elseif in_src and text.is_match(l, [=[^[a-z_]+:]=]) then
            in_src = false
        elseif in_src and text.is_match(l, [=[^[[:space:]]*-[[:space:]]]=]) then
            local item = (l:gsub("^%s*%-%s*", ""))
            if text.contains(item, " order:") then entries[#entries + 1] = item end
        end
    end
    return entries
end

local function declares(content, ord)
    local pat = [[^ *order: *"?]] .. ord .. [["?( |$)]]
    return text.first_match(content, pat) ~= nil
end

-- Order declared ANYWHERE, for the "declared in X, not the anchored file"
-- message: plan/index.yaml first (explicit in the .sh's argv), then
-- plan/archive/*.yaml sorted — first match wins, exactly `grep -rl ... | head -1`.
local function find_declared_elsewhere(ord)
    local pat = [[^ *order: *"?]] .. ord .. [["?( |$)]]
    local candidates = { "plan/index.yaml" }
    local ok_walk, archive = pcall(fs.walk, "plan/archive", { suffix = ".yaml" })
    if ok_walk then
        for _, f in ipairs(archive) do candidates[#candidates + 1] = f end
    end
    for _, f in ipairs(candidates) do
        local ok, content = pcall(fs.read, f)
        if ok and text.first_match(content, pat) ~= nil then
            return f
        end
    end
    return nil
end

local checked = 0
local violations = {}

local ok_sheets, sheets = pcall(fs.walk, "cheatsheets", { suffix = ".md" })
if ok_sheets then
    for _, sheet in ipairs(sheets) do
        local ok_read, content = pcall(fs.read, sheet)
        if ok_read then
            for _, entry in ipairs(source_entries(content)) do
                local file, ord = split_entry(entry)
                checked = checked + 1
                local ok_file, fcontent = pcall(fs.read, file)
                if not ok_file then
                    violations[#violations + 1] =
                        "violation:cheatsheet-source-anchor:" .. sheet .. ":" .. entry .. " — no such file"
                elseif not declares(fcontent, ord) then
                    local found = find_declared_elsewhere(ord)
                    if found then
                        violations[#violations + 1] =
                            "violation:cheatsheet-source-anchor:" .. sheet .. ":" .. entry ..
                            " — declared in " .. found .. ", not the anchored file"
                    else
                        violations[#violations + 1] =
                            "violation:cheatsheet-source-anchor:" .. sheet .. ":" .. entry ..
                            " — order declared nowhere"
                    end
                end
            end
        end
    end
end

if #violations > 0 then
    for i = 1, #violations - 1 do out.line(violations[i]) end
    log.raw("  A cheatsheet anchors an order to a file that does not declare it.")
    log.raw("  An anchor is a promise that the reader can follow it; one that")
    log.raw("  points at the live ledger for an archived packet sends them to a")
    log.raw("  file where the id appears only as prose in someone else's packet.")
    log.raw("  Fix the anchor to name the file that DECLARES the order.")
    verdict.emit(violations[#violations], 1)
end

verdict.ok("cheatsheet-source-anchors", checked .. " checked")
