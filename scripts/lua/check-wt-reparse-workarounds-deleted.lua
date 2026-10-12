-- @trace order:823-u5zf, order:1625-n3t3
-- @env TILLANDSIAS_WT_REPARSE_SCAN_ROOT
-- @read-env TILLANDSIAS_WT_REPARSE_SCAN_ROOT
--
-- check-wt-reparse-workarounds-deleted.lua — the wt.exe re-parse workarounds
-- must stay deleted, and a NOTE ABOUT THEIR DELETION MUST NOT COUNT AS ONE.
--
-- 823-u5zf's closure reads "a source scan finds no argv_survives_wt_reparse and
-- no wt_safe_title". Taken literally that scan is a grep, and a grep cannot
-- close this packet: the predicates are gone, but comments RECORDING that they
-- are gone still name them (host-shell/src/pty/mod.rs, notify_icon.rs). A
-- literal scan reports the packet incomplete forever, and the obvious repair —
-- deleting the comments so the grep passes — destroys the only explanation of
-- why the code looks the way it does. A name that appears in both the live text
-- and the prose about it cannot be classified by matching the name (1055-6yp8,
-- 1049-s35z).
--
-- So this scan classifies by POSITION, not by presence: an occurrence counts
-- only if it survives stripping the comment part of its line. Comments may
-- discuss the deleted predicates freely; code may not name them at all.
--
-- PORTED from check-wt-reparse-workarounds-deleted.sh (1625-n3t3), quirks
-- included, measured equal on the live tree and on planted cases:
--   * "the comment part" is everything from the FIRST `//` on the line, so a
--     `//` inside a string literal ("http://x") hides an identifier after it;
--   * a `/* ... */` block comment is not a comment to this scan, so an
--     identifier inside one is counted as code.
-- Both are the .sh's behaviour and are recorded on 1625-n3t3 rather than fixed
-- here. A mention is one matching LINE per symbol, as grep -n counts it.
--
-- GRAMMAR — exactly one line:
--   ok:wt-reparse-workarounds-deleted:<n> mention(s), all in comments   exit 0
--   violation:wt-reparse-workaround-live:<n> code occurrence(s)          exit 1
--
-- Usage: tillandsias-plan script run scripts/lua/check-wt-reparse-workarounds-deleted.lua [-- <dir>]
--   <dir> defaults to crates. An absolute <dir> outside the checkout must lie
--   under TILLANDSIAS_WT_REPARSE_SCAN_ROOT (the fixture's scratch tree).

local SCAN_DIR = arg[1] or "crates"
local SYMBOLS = { "argv_survives_wt_reparse", "wt_safe_title" }

-- grep -r ... 2>/dev/null: an unreadable or missing directory is no hits.
local ok_w, walked = pcall(fs.walk, SCAN_DIR, { suffix = ".rs" })
local files = ok_w and walked or {}

local bodies = {}
for _, f in ipairs(files) do
    local ok_r, body = pcall(fs.read, f)
    if ok_r and body then bodies[#bodies + 1] = { path = f, lines = text.lines(body) } end
end

local live = {}
local mentions = 0
for _, sym in ipairs(SYMBOLS) do
    for _, b in ipairs(bodies) do
        for n, line in ipairs(b.lines) do
            if line:find(sym, 1, true) then
                mentions = mentions + 1
                -- The code part is everything before the first `//`. A line
                -- whose text begins with the comment marker has no code part.
                local cut = line:find("//", 1, true)
                local code = cut and line:sub(1, cut - 1) or line
                if code:find(sym, 1, true) then
                    live[#live + 1] = b.path .. ":" .. n .. ": " .. sym .. " appears in CODE, not in a comment"
                end
            end
        end
    end
end

if #live > 0 then
    local detail = {}
    for _, l in ipairs(live) do detail[#detail + 1] = "  " .. l end
    detail[#detail + 1] = "  The wt.exe re-parse workarounds were deleted under 823-u5zf: every"
    detail[#detail + 1] = "  lane now emits a verbatim argv whose tokens are wt-safe, so a"
    detail[#detail + 1] = "  predicate deciding whether a FLATTENED string survives wt's"
    detail[#detail + 1] = "  re-parse has nothing left to guard. Re-introducing one means a"
    detail[#detail + 1] = "  lane fell back to conhost, which is the field failure 805-ek9e"
    detail[#detail + 1] = "  reports: no clickable links and no working paste, so an operator"
    detail[#detail + 1] = "  cannot complete a device-code login."
    verdict.emit("violation:wt-reparse-workaround-live:" .. #live .. " code occurrence(s)", 1, table.concat(detail, "\n"))
end

verdict.emit("ok:wt-reparse-workarounds-deleted:" .. mentions .. " mention(s), all in comments", 0)
