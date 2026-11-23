-- @trace order:2257-ba7e, order:626-w3fn, order:1642-cc54, spec:tray-ux
--
-- check-approved-ux-strings.lua — every end-user UX string in the table below is
-- still the one the operator APPROVED in the ledger (626-w3fn). Ported from
-- scripts/check-approved-ux-strings.sh.
--
-- WHY A GATE AND NOT A UNIT TEST: an in-file test is edited together with its
-- constant by one find-and-replace (measured on bringup_progress.rs). The ledger
-- is a different file by a different actor, and spec:tray-ux puts the authority
-- there: "an operator_note or operator-attributed event on the packet".
--
-- SO ONLY operator_note BODIES ARE SEARCHED, never the whole ledger: searching it
-- all let a prose mention of a rejected reword approve it (the 626-w3fn notes
-- quote their own counterexample). Base ledger, plan/index.d (an approval
-- recorded today) and plan/archive (the approved packet completed) are read.
-- Two shapes open a note: the base's dashed `- type: operator_note`, and the
-- undashed `type:` under `event:` that append-event writes (1642-cc54).
-- A capture ends with its file. (The .sh carried it into the next file, so a
-- comment at that file's top read as part of an approval.)
--
-- ONLY POST-2026-07-22 APPROVALS BELONG IN THE TABLE: the curation rule was
-- codified 2026-07-21 (01696cd54), and enforcing older strings would invent an
-- approval nobody gave. Adding a row asserts that an operator_note records THIS
-- EXACT string. (929-47u8 audits the rest.)
--
-- It cannot tell an operator_note from a note that calls itself one; it closes
-- the drift-after-approval hole, which is the mechanically checkable one.
--
-- Verdicts (as the .sh's):
--   ok:approved-ux-strings:<n> checked against the ledger   exit 0
--   skip:approved-ux-strings:no-ledger                      exit 0
--   blocked:approved-ux-strings:<checked>                   exit 1

local ROWS = {
    { "crates/tillandsias-headless/src/bringup_progress.rs",
      'const APPROVED_SENTENCE: &str = "', "bring-up progress (626-w3fn)" },
    { "crates/tillandsias-macos-tray/src/reset_state.rs",
      'pub(crate) const REBUILD_STATUS: &str = "', "unclean-stop rebuild status (1642-cc54)" },
}
local LEDGER = "plan/index.yaml"

local function read(p)
    local good, body = pcall(fs.read, p)
    return good and body or nil
end
local base = read(LEDGER)
if not base then verdict.emit("skip:approved-ux-strings:no-ledger", 0) end

local notes = {}
local function collect(body)
    local inside = false
    for l in (body .. "\n"):gmatch("([^\n]*)\n") do
        local kind = l:match("^%s*type:(.*)$") or l:match("^%s*%-%s*type:(.*)$")
        if kind then inside = kind:match("^%s*operator_note%s*$") ~= nil
        elseif l:find("^%s*event:%s*$") or l:find("^%s*%-%s*packet_id:")
            or l:find("^%s*packets:%s*$") or l:find("^%s*events:%s*$") or l:find("^%s*status:%s*$") then
            inside = false
        elseif inside then notes[#notes + 1] = l end
    end
end
collect(base)
for _, dir in ipairs({ "plan/index.d", "plan/archive" }) do
    if fs.exists(dir) then
        for _, f in ipairs(fs.list(dir)) do
            local name = f:match("([^/]+%.yaml)$")
            if name and name:sub(1, 1) ~= "." then
                local body = read(dir .. "/" .. name)
                -- An unreadable fragment could only HIDE an approval; say so.
                if body then collect(body) else log.raw("note:approved-ux-strings:unreadable:" .. dir .. "/" .. name) end
            end
        end
    end
end
local NOTES = table.concat(notes, "\n")

local checked, fail = 0, false
for _, row in ipairs(ROWS) do
    local src, prefix, label = row[1], row[2], row[3]
    local body = read(src)
    if not body then
        log.raw("blocked:approved-ux-strings:missing-source — " .. src .. " (" .. label .. ")")
        fail = true
    else
        local s
        for l in (body .. "\n"):gmatch("([^\n]*)\n") do
            if l:sub(1, #prefix) == prefix and l:sub(-2) == '";' and #l >= #prefix + 2 then
                s = l:sub(#prefix + 1, -3); break
            end
        end
        checked = checked + 1
        if not s or s == "" then
            log.raw("blocked:approved-ux-strings:no-string — could not extract from " .. src .. " (" .. label .. ")")
            fail = true
        elseif not NOTES:find(s, 1, true) then
            fail = true
            log.raw('[check-approved-ux-strings] UNAPPROVED end-user UX string.\n\n  surface   : ' .. label
                .. "\n  in code   : " .. src .. '\n  string    : "' .. s .. '"\n  ledger    : ' .. LEDGER
                .. " — no operator approval records this exact string\n\n"
                .. 'spec:tray-ux, Requirement "UX curation governance": no agent may alter any\n'
                .. 'user-visible surface "without EXPLICIT prior operator approval recorded in the\n'
                .. 'plan ledger", and the change "MUST NOT be implemented until the packet carries\n'
                .. 'recorded operator approval for that exact surface change".')
            log.raw("  why: " .. src .. " says a string no operator_note in the ledger records\n"
                .. "  remedy: revert it, or get the new wording approved by the operator and recorded as an"
                .. " operator_note on the packet FIRST")
        end
    end
end
-- A table that checked nothing is a failure: deleting it must not read as clean.
if checked == 0 then
    log.raw("blocked:approved-ux-strings:empty-table — no row was checked")
end
if fail or checked == 0 then verdict.emit("blocked:approved-ux-strings:" .. checked, 1) end
verdict.emit("ok:approved-ux-strings:" .. checked .. " checked against the ledger", 0)
