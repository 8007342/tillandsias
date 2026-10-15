-- @trace order:1049-s35z, order:1696-gz2y
--
-- check-jq-multiline-capture-strips-cr.lua — a jq capture that can yield MORE
-- THAN ONE LINE must strip carriage returns. Ported from
-- scripts/check-jq-multiline-capture-strips-cr.sh, the shell-to-lua item the
-- 1696-gz2y follow-up carried; same rule, grammar, exit codes and stderr.
--
-- WHY ONLY MULTI-LINE, measured on yolanda 2026-09-05 with `od -c` on the value
-- rather than grep, because MSYS grep treats CR as part of the line ending and
-- hides it:
--
--   v="$(echo '{"a":"x"}' | jq -r .a)"          -> len 1, no CR. SAFE.
--   while read l; do ...; done < <(jq -r '.a[]') -> "one" arrives len 4: o n e \r
--
-- jq.exe writes CRLF, and command substitution strips the trailing line ending
-- including the CR — so ONLY THE FINAL LINE loses it and every preceding line
-- keeps it. Exposure is therefore a property of whether a capture can yield
-- multiple lines, NOT of using jq. That is why the litmus runner broke while
-- 62 sibling call sites were fine.
--
-- `| head -1` IS A GUARD: head reduces the stream to ONE line before capture,
-- and command substitution then strips that line's ending, CR included.
-- Measured: `jq -r '.a[]' | head -1` captures len 3, not 4.
--
-- WHAT COUNTS AS MULTI-LINE-CAPABLE: a `jq -r` whose filter iterates with `[]`
-- before any pipe. A filter that reduces to one line — `| max`, `| join(...)`,
-- `| add`, `| length`, `| first`, `| any`, `| all`, or a following
-- `| head`/`| tail` — is exempt.
--
-- Usage: tillandsias-plan script run scripts/lua/check-jq-multiline-capture-strips-cr.lua [-- <dir>]
-- <dir> (default scripts) is scanned for *.sh files; it must be inside the
-- repository (the runtime's reads are confined to it).
--
-- GRAMMAR — exactly one line:
--   ok:jq-multiline-capture-strips-cr:<n> multi-line site(s), all stripped
--   violation:jq-multiline-capture-unstripped:<n> site(s)

local SCAN_DIR = arg[1] or "scripts"
if not fs.exists(SCAN_DIR) then
    verdict.emit("ok:jq-multiline-capture-strips-cr:0 multi-line site(s), all stripped", 0)
end

local SELF = { ["check-jq-multiline-capture-strips-cr.sh"] = true, ["test-jq-multiline-capture.sh"] = true }
local REDUCERS = { "| max", "| join(", "| add", "| length", "| first", "| any", "| all",
    "| head ", "| head -", "| tail ", "| tail -" }

local files = fs.walk(SCAN_DIR, { suffix = ".sh" })
table.sort(files)
local violations, multiline = {}, 0
for _, file in ipairs(files) do
    local base = file:match("[^/]+$")
    local ok, body = pcall(fs.read, file)
    if ok and body and not SELF[base] then
        local n = 0
        for line in (body .. "\n"):gmatch("(.-)\n") do
            n = n + 1
            -- grep -E "jq -r[^|]*\[\]": `jq -r`, then no pipe before a `[]`.
            local s = line:find("jq -r", 1, true)
            local hit = false
            while s and not hit do
                local tail = line:sub(s + 5)
                local bracket = tail:find("[]", 1, true)
                local pipe = tail:find("|", 1, true)
                if bracket and (not pipe or bracket < pipe) then hit = true end
                s = line:find("jq -r", s + 1, true)
            end
            local trimmed = line:gsub("^%s+", "")
            if hit and trimmed:sub(1, 1) ~= "#" then
                local reduced = false
                for _, r in ipairs(REDUCERS) do
                    if line:find(r, 1, true) then reduced = true; break end
                end
                if not reduced then
                    multiline = multiline + 1
                    if not line:find("tr -d", 1, true) then
                        violations[#violations + 1] = file .. ":" .. n .. ": multi-line jq capture with no CR strip"
                    end
                end
            end
        end
    end
end

if #violations > 0 then
    for _, v in ipairs(violations) do log.raw("  " .. v) end
    log.raw("  jq.exe writes CRLF. Command substitution strips only the FINAL")
    log.raw("  line ending, so every line but the last arrives with a trailing")
    log.raw("  carriage return. A value compared, indexed, or used to build a")
    log.raw("  path is then silently wrong on Windows — and MSYS grep will not")
    log.raw("  show you the CR, only od -c will.")
    log.raw("  Fix: pipe the jq output through `tr -d '\\r'`.")
    log.raw("  Note a pipeline that reduces to ONE line before capture is safe:")
    log.raw("  `| head -1`, `| max`, `| join(...)` all leave a single line,")
    log.raw("  whose ending command substitution strips, CR included (1049-s35z).")
    verdict.emit("violation:jq-multiline-capture-unstripped:" .. #violations .. " site(s)", 1)
end
verdict.emit("ok:jq-multiline-capture-strips-cr:" .. multiline .. " multi-line site(s), all stripped", 0)
