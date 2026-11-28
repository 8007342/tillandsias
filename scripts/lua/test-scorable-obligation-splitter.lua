-- @env PATH HOME SCORABLE_PIN_SHA
-- @trace order:1331-884p, order:2386-zxgc, order:2406-7f88
--
-- test-scorable-obligation-splitter.lua — the row splitter in check-scorable-obligation-added.sh
-- reads a verifiable_closure below a nested list at any indent, invents no row, loses no closure on
-- the live ledger, and is not fooled by example YAML inside a block scalar. Ported from the .sh of
-- the same name (2386-zxgc). The awk program is cut from the shipped guard and from the pinned pre-fix
-- one (SCORABLE_PIN_SHA), and each is run by awk.
--
--   1 the indent-4 closure: unread before the fix, read after; indent 6 read by both
--   2 MUTATION the pinned and current splitters differ, and the pinned one fails the fixture
--   3 the live ledger: no row vanishes or appears, at least one closure recovered, none lost
--   4 a guard with the pinned splitter refuses a row it cannot read, never passes it
--   5 example YAML inside a block scalar neither eats the closure nor becomes a packet
--
-- Usage: tillandsias-plan script run scripts/lua/test-scorable-obligation-splitter.lua
-- Verdict: ok:scorable-obligation-splitter:<n> arms | violation:... | skip:...:pin-unreachable

local fixture = require "common.fixture"
local T = fixture.new("scorable-obligation-splitter")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local GUARD = "scripts/check-scorable-obligation-added.sh"
local PIN = env.get("SCORABLE_PIN_SHA")
if not PIN or PIN == "" then PIN = "ff6fc4fdde3ee02c9ae41bf2232417c563f9ce50" end
-- COMPOSED, never a literal name another guard would bind (721-77yu).
local L = "lit" .. "mus:"
local S_FIX, S_WIT, S_PROSE = L .. "fixture-closure-is-read", L .. "witness-closure-is-read", L .. "prose-does-not-eat-the-closure"
local w = T:scratch()
-- The awk body between `_BLOCK_AWK='` and its closing `    '`.
local function block(src)
    local b = ("\n" .. src:gsub("\r", "")):match("\n_BLOCK_AWK='\n(.-)\n    '\n")
    return b and b .. "\n"
end
local pin = T:run{ "git", "-C", ROOT, "show", PIN .. ":" .. GUARD }
if pin.code ~= 0 then T:skip("pin-unreachable:" .. PIN) end
local OLD, NEW = block(pin.stdout or ""), block(fs.read(GUARD))
T:arm("0 both splitters are cut out", OLD ~= nil and NEW ~= nil, "a block is empty")
if not (OLD and NEW) then T:finish() end
fs.write(w.rel .. "/old.awk", OLD); fs.write(w.rel .. "/new.awk", NEW)
-- An awk that does not honour \037 would read every field empty, and blame the subject for it.
local probe = text.trim(T:run{ SH, "-s", stdin = "printf 'a\\037b\\n' | awk -F'\\037' '{print NF}'\n" }.stdout or "")
if probe ~= "2" then
    T:cleanup()
    verdict.emit("could-not-run:scorable-splitter:awk-field-separator-unsupported:NF=" .. probe, 3)
end
-- Records: one line per row, fields split on \037; the closure is field 3.
local function records(prog, file)
    local r = T:run{ "awk", "-f", w.abs .. "/" .. prog, file, cwd = ROOT }
    local l = {}
    for line in ((r.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then l[#l + 1] = { line:match("^([^\31]*)\31([^\31]*)\31([^\31]*)") } end
    end
    return l
end
local function closure(prog, file) local r = records(prog, file); return r[1] and r[1][3] or "" end
local function fixture_(indent, name)
    local pad = string.rep(" ", indent)
    fs.write(w.rel .. "/" .. name, "packets:\n  - packet_id: fixture-splitter-" .. indent .. "-space-nested-list\n    order: 9999-f" .. indent .. "\n    status: ready\n    capability_tags:\n"
        .. pad .. "- plan\n" .. pad .. "- tooling\n    verifiable_closure: |\n      " .. S_FIX .. "\n")
    return w.abs .. "/" .. name
end
local BAD, GOOD = fixture_(4, "bad.yaml"), fixture_(6, "good.yaml")
T:arm("1a the pinned splitter did not read the indent-4 closure (the pin is the pre-fix code)", closure("old.awk", BAD) == "", closure("old.awk", BAD))
T:arm("1b it read the indent-6 one", closure("old.awk", GOOD) == S_FIX, closure("old.awk", GOOD))
T:arm("1c the current one reads both", closure("new.awk", BAD) == S_FIX and closure("new.awk", GOOD) == S_FIX, closure("new.awk", BAD) .. " " .. closure("new.awk", GOOD))
T:arm("2 MUTATION the splitters differ, so the revert is real", OLD ~= NEW, "identical")

-- The live ledger, file by file, keyed on file and packet.
local function keyed(prog)
    local k = {}
    local files = { "plan/index.yaml" }
    for _, f in ipairs(fs.list("plan/index.d")) do
        if f:match("%.yaml$") then files[#files + 1] = "plan/index.d/" .. f end
    end
    -- ONE shell per splitter, awk still once per FILE: the splitter's own END
    -- flushes a file's last row, so one awk over every file would read
    -- differently. One proc.run per file was 2 x 7,740 spawns through the runner
    -- on 2026-11-26, 74-105 s against the 60 s litmus budget (2364-qgr7); this
    -- pass is 27 s on the same host. Arm 3 compares closures only as empty or
    -- not, so a marker line names each file and ONE awk compacts the stream to
    -- <file>\036<packet>\037<x when the closure is non-empty>. The full closure
    -- text was 13.7 MB, past the runner's capture cap (which silently lost 8 rows
    -- when this was first tried), so truncation is a failed arm, never trusted.
    -- A record that does not split into three fields keys as <file>| with no
    -- closure, exactly as the per-file pass keyed it.
    local r = T:run{ SH, "-s", "--", w.abs .. "/" .. prog, cwd = ROOT, timeout_ms = 600000,
        stdin = 'prog="$1"\n{ while IFS= read -r f; do printf \'\\036%s\\n\' "$f"; awk -f "$prog" "$f"; done <<\'__FILES__\'\n'
            .. table.concat(files, "\n") .. "\n__FILES__\n"
            .. "} | awk -F'\\037' '/^\\036/ { f = substr($0, 2); next }"
            .. " { if (NF >= 3) print f \"\\036\" $1 \"\\037\" ($3 != \"\" ? \"x\" : \"\");"
            .. " else print f \"\\036\\037\" }'" }
    if r.code ~= 0 or r.truncated then
        T:arm("3 the live-ledger pass ran and its output was whole", false,
            "rc=" .. tostring(r.code) .. " truncated=" .. tostring(r.truncated) .. " " .. (r.stderr or ""):sub(1, 200))
    end
    for line in ((r.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
        local f, id, x = line:match("^([^\30]*)\30([^\31]*)\31(x?)$")
        if f then k[f .. "|" .. id] = x end
    end
    return k
end
local ko, kn = keyed("old.awk"), keyed("new.awk")
local vanished, appeared, recovered, lost, n = 0, 0, 0, 0, 0
for key, c in pairs(ko) do
    n = n + 1
    if kn[key] == nil then vanished = vanished + 1
    elseif c == "" and kn[key] ~= "" then recovered = recovered + 1
    elseif c ~= "" and kn[key] == "" then lost = lost + 1 end
end
for key in pairs(kn) do
    if ko[key] == nil then appeared = appeared + 1 end
end
T:arm("3a no row vanished and none appeared", n > 0 and vanished == 0 and appeared == 0, n .. " rows, vanished=" .. vanished .. " appeared=" .. appeared)
T:arm("3b no closure was lost", lost == 0, lost .. " lost")
T:arm("3c at least one closure was recovered on the live ledger", recovered >= 1, recovered .. " recovered")

-- The guard with the pinned splitter spliced in, on a scratch repository.
local src = fs.read(GUARD):gsub("\r", "")
local a, z = src:find("\n_BLOCK_AWK='\n", 1, true)
local e = a and src:find("\n    '\n", z, true)
local blind = a and e and src:sub(1, z) .. OLD:sub(1, -2) .. src:sub(e)
T:arm("4a the splice changes the guard", blind ~= nil and blind ~= src, "no-op")
if blind and blind ~= src then
    local g = T:git_repo()
    fs.mkdir(g.rel .. "/plan/index.d"); fs.mkdir(g.rel .. "/scripts")
    fs.write(g.rel .. "/" .. GUARD, src); fs.write(g.rel .. "/scripts/blind.sh", blind)
    T:must{ "git", "-C", g.abs, "add", "-A" }; T:must{ "git", "-C", g.abs, "commit", "-qm", "base" }; T:must{ "git", "-C", g.abs, "branch", "-q", "base-ref" }
    fs.write(g.rel .. "/plan/index.d/20260101t000000z-witness.yaml", "packets:\n  - packet_id: witness-row-with-a-nested-list-above-its-closure\n    order: 9999-w1tn\n    status: ready\n    capability_tags:\n    - plan\n    verifiable_closure: |\n      " .. S_WIT .. "\n")
    T:must{ "git", "-C", g.abs, "add", "-A" }; T:must{ "git", "-C", g.abs, "commit", "-qm", "new" }
    local function verdict_(script)
        local r = proc.run{ argv = { SH, script, "base-ref" }, cwd = g.abs, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
        for l in ("\n" .. (r.stdout or "") .. (r.stderr or "")):gmatch("\n([^\n]*)") do
            if l:match("^ok:") or l:match("^violation:") or l:match("^skip:") then return l end
        end
        return ""
    end
    local bv, fv = verdict_("scripts/blind.sh"), verdict_(GUARD)
    local strict = text.contains(src, "scorable-obligation-parse-failure")
    if strict then
        T:arm("4b STRICT the blind parser blames itself", bv:match("^violation:scorable%-obligation%-parse%-failure:") ~= nil, bv)
    else
        T:arm("4b RELAXED the blind parser refuses rather than passing silently", bv:match("^violation:scorable%-obligation%-missing:") ~= nil, bv)
    end
    T:arm("4c the fixed guard accepts the same row", fv == "ok:scorable-obligations:1 checked", fv)
end

fs.write(w.rel .. "/prose.yaml", "packets:\n  - packet_id: a-row-whose-context-documents-yaml-before-stating-its-closure\n    order: 9999-prose\n    status: ready\n    context: |\n      The fragment README shows a correction like this:\n\n        packets:\n          - packet_id: the-packet-being-repaired\n            status: completed\n\n      which is the shape we accept.\n    verifiable_closure: |\n      " .. S_PROSE .. "\n")
local pr, pre = records("new.awk", w.abs .. "/prose.yaml"), closure("old.awk", w.abs .. "/prose.yaml")
T:arm("5a example YAML in a block scalar does not eat the closure", pr[1] ~= nil and pr[1][3] == S_PROSE, pr[1] and pr[1][3] or "none")
T:arm("5b and does not become a phantom packet", #pr == 1, #pr .. " records")
T:arm("5c and the pinned splitter read nothing the current one does not", pre == "" or (pr[1] and pr[1][3] ~= ""), pre)
T:finish()
