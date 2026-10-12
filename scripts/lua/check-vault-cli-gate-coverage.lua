-- @trace order:1406-9ctt, order:1577-g96z, spec:tillandsias-vault
--
-- check-vault-cli-gate-coverage.lua — every verb a vault-cli.sh DISPATCHES must
-- be in its central CA gate, so a new verb cannot reach Vault unverified.
-- PORTED from check-vault-cli-gate-coverage.sh as the carried item that pays
-- 1577-g96z's own shell-to-lua obligation (methodology carried_obligations).
--
-- WHY A PROPERTY, NOT A LIST. litmus:vault-cli-verifies-tls used to grep for a
-- literal verb list; when write-json was added (1381-za6b/1383-5hpk) the GATE
-- grew correctly and the PIN went red, because a pinned list tests the list, not
-- the guarantee. This compares the two lists the script itself carries: the
-- `<verbs>) require_cacert` gate line (the FIRST such line), and the
-- dispatcher's single-verb `<verb>) … cmd_…` arms. usage/help (no I/O, no
-- cmd_ call) are exempt, as the script's own comment says.
--
-- WHAT IT CANNOT SEE: a verb dispatched by any other shape (a multi-verb arm,
-- a function table) is not counted; a gate applied somewhere other than that
-- one line is not seen. It checks the script's two lists agree, not that
-- require_cacert itself verifies anything (the litmus's other steps do that).
--
-- Usage: script run check-vault-cli-gate-coverage.lua -- <path/to/vault-cli.sh>
-- OUTPUT (unchanged from the .sh):
--   ok:vault-cli-gate-coverage:<file>:<n> verbs                    exit 0
--   refused:vault-cli-gate-coverage:<file>:ungated=<verbs>         exit 1
--   could-not-run:vault-cli-gate-coverage:<file>:<why>             exit 3

local f = arg[1]
local ok_r, content = false, nil
if f and f ~= "" then ok_r, content = pcall(fs.read, f) end
if not ok_r then
    verdict.emit("could-not-run:vault-cli-gate-coverage:" .. ((f and f ~= "") and f or "<none>") .. ":no-such-file", 3)
end

local gate, verbs, seen = nil, {}, {}
for _, l in ipairs(text.lines(content)) do
    if not gate then
        local g = l:match("^%s*([a-z|%-]+)%)%s*require_cacert")
        if g then gate = " " .. g:gsub("|", " ") .. " " end
    end
    local v = l:match("^%s*([a-z%-]+)%)%s.*cmd_")
    if v and not seen[v] then seen[v] = true; verbs[#verbs + 1] = v end
end
if not gate then verdict.emit("could-not-run:vault-cli-gate-coverage:" .. f .. ":no-gate-line", 3) end
if #verbs == 0 then verdict.emit("could-not-run:vault-cli-gate-coverage:" .. f .. ":no-dispatch-arms", 3) end
table.sort(verbs)

local missing = {}
for _, v in ipairs(verbs) do
    if not gate:find(" " .. v .. " ", 1, true) then missing[#missing + 1] = v end
end
if #missing > 0 then
    verdict.emit("refused:vault-cli-gate-coverage:" .. f .. ":ungated=" .. table.concat(missing, ","), 1)
end
verdict.emit("ok:vault-cli-gate-coverage:" .. f .. ":" .. #verbs .. " verbs", 0)
