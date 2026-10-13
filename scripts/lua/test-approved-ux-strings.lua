-- @trace order:1642-cc54
-- @env PATH
--
-- test-approved-ux-strings.lua — scripts/check-approved-ux-strings.sh finds an
-- operator approval recorded TODAY (an append-event fragment), still refuses a
-- prose mention or a reword, and answers the same however long the notes are.
--
-- Two defects found 2026-10-12 while recording the operator's approval of
-- "Rebuilding your workspace after an unexpected shutdown…" (1642-cc54):
--   * the parser matched only the DASHED `- type: operator_note` of the base
--     ledger, while append-event fragments write `event:` then an UNDASHED
--     `type: operator_note`, so an approval was invisible until a compaction;
--   * `operator_notes | grep -qF` under pipefail is a SIGPIPE verdict: grep -q
--     exits on its first match, awk dies writing into the closed pipe, and
--     pipefail turns the match into "unapproved" once the notes outgrow the
--     pipe buffer.
--
-- Each arm runs the gate in a SCRATCH tree (its own scripts/, plan/ and the
-- two source files its table names), never this checkout's ledger. Arms 1
-- and 3 also run the PRE-FIX gate (git show 335f7785d) and expect it red.
--   1 FRAGMENT   an append-event-shaped operator_note approves the string;
--                the pre-fix gate refuses it
--   2 PROSE      the same sentence in a `note` event approves nothing
--   3 LONG       3000 earlier notes ahead of the approval: still approved;
--                the pre-fix gate (were it able to read the fragment form)
--                is shown red by arm 1, and this arm pins the SIGPIPE fix
--   4 REWORD     code that says something else is refused
--   5 NO-ARCHIVE a tree with no plan/archive/*.yaml still reads the notes:
--                under set -u, bash 3.2 calls an empty array unbound, and
--                the pre-fix gate then read nothing at all
--
-- Usage: tillandsias-plan script run scripts/lua/test-approved-ux-strings.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("approved-ux-strings-fixture", "git rev-parse --show-toplevel did not answer")
end

local PREFIX = "335f7785d"
local old = proc.run({ argv = { "git", "show", PREFIX .. ":scripts/check-approved-ux-strings.sh" },
    cwd = ROOT, timeout_ms = 30000 })
if old.status ~= "exited" or old.code ~= 0 then
    verdict.could_not_run("approved-ux-strings-fixture", "git show " .. PREFIX .. " did not answer")
end
local NEW = fs.read("scripts/check-approved-ux-strings.sh")

local REL = "target/plan-scratch/approved-ux-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local A = ROOT .. "/" .. REL

local SENTENCE = "Rebuilding your workspace after an unexpected shutdown\u{2026}"
local BRINGUP = "Getting your workspace ready\u{2026}"

local failed = {}
local function arm(name, cond, got)
    got = tostring(got):gsub("\n", " | ")
    if cond then out.line("ok:   " .. name .. " — " .. got) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

-- A scratch tree: the gate, a base ledger approving the bring-up line (dashed
-- base form), the two source files the gate's table reads, and `fragment` as
-- the only file under plan/index.d.
local n = 0
local function tree(gate, code_sentence, fragment, no_archive)
    n = n + 1
    local T = REL .. "/t" .. n
    fs.mkdir(T .. "/scripts")
    fs.mkdir(T .. "/plan/index.d")
    fs.mkdir(T .. "/crates/tillandsias-headless/src")
    fs.mkdir(T .. "/crates/tillandsias-macos-tray/src")
    fs.write(T .. "/scripts/check-approved-ux-strings.sh", gate)
    fs.write(T .. "/plan/index.yaml", table.concat({
        "packets:",
        "  - packet_id: bring-up",
        "    events:",
        "      - type: operator_note",
        "        summary: |-",
        "          Approved: " .. BRINGUP,
        "" }, "\n"))
    fs.write(T .. "/crates/tillandsias-headless/src/bringup_progress.rs",
        'const APPROVED_SENTENCE: &str = "' .. BRINGUP .. '";\n')
    fs.write(T .. "/crates/tillandsias-macos-tray/src/reset_state.rs",
        'pub(crate) const REBUILD_STATUS: &str = "' .. code_sentence .. '";\n')
    fs.write(T .. "/plan/index.d/frag.yaml", fragment)
    if not no_archive then
        fs.mkdir(T .. "/plan/archive")
        fs.write(T .. "/plan/archive/old.yaml", "packets: []\n")
    end
    local r = proc.run({ argv = { "bash", A .. "/t" .. n .. "/scripts/check-approved-ux-strings.sh" },
        cwd = ROOT, timeout_ms = 60000 })
    return r.code, text.trim((r.stdout or "") .. " " .. (r.stderr or ""))
end

-- The exact shape tillandsias-plan append-event writes.
local function event_fragment(kind, body)
    return table.concat({
        "events:",
        "  - packet_id: unclean-rebuild",
        "    event:",
        "      type: " .. kind,
        '      ts: "2026-10-12T22:32:18Z"',
        "      host: fixture",
        "      summary: |-",
        "        " .. body,
        "" }, "\n")
end

local approval = event_fragment("operator_note", "Approved status line, exact text: " .. SENTENCE)

local rc, o = tree(NEW, SENTENCE, approval)
arm("1 FRAGMENT an append-event operator_note approves the string", rc == 0 and o:find("ok:approved-ux-strings", 1, true) ~= nil, rc .. " " .. o)
local orc, oo = tree(old.stdout, SENTENCE, approval)
arm("1 FRAGMENT the pre-fix gate refuses the same approval (red before the fix)", orc ~= 0, orc .. " " .. oo:sub(1, 120))

rc, o = tree(NEW, SENTENCE, event_fragment("note", "We should say: " .. SENTENCE))
arm("2 PROSE a note event quoting the sentence approves nothing", rc ~= 0 and o:find("UNAPPROVED", 1, true) ~= nil, rc .. " " .. o:sub(1, 120))

local many = { "events:" }
for i = 1, 3000 do
    many[#many + 1] = "  - packet_id: filler-" .. i
    many[#many + 1] = "    event:"
    many[#many + 1] = "      type: operator_note"
    many[#many + 1] = "      summary: |-"
    many[#many + 1] = "        filler approval number " .. i .. " for some other surface entirely"
end
many[#many + 1] = "  - packet_id: unclean-rebuild"
many[#many + 1] = "    event:"
many[#many + 1] = "      type: operator_note"
many[#many + 1] = "      summary: |-"
many[#many + 1] = "        Approved status line, exact text: " .. SENTENCE
many[#many + 1] = ""
rc, o = tree(NEW, SENTENCE, table.concat(many, "\n"))
arm("3 LONG 3000 notes ahead of the approval: still approved (no SIGPIPE verdict)", rc == 0, rc .. " " .. o:sub(1, 120))

rc, o = tree(NEW, SENTENCE, approval, true)
arm("5 NO-ARCHIVE a tree with no plan/archive still reads the notes (bash 3.2 empty-array guard)", rc == 0, rc .. " " .. o:sub(1, 120))
-- The pre-fix half is a negative control only where the defect exists: an
-- empty "${A[@]}" is unbound under set -u on bash < 4.4 (stock macOS 3.2),
-- and fine on 4.4+ (Linux), where the pre-fix gate rightly passes. Ask the
-- same `bash` the gate runs under (`--version`: the runtime refuses `bash -c`).
-- A version it cannot read FAILS the arm; a probe that silently skips would
-- retire the control on the very host it exists for.
local bv = proc.run({ argv = { "bash", "--version" }, timeout_ms = 10000 })
local major, minor = (bv.stdout or ""):match("version (%d+)%.(%d+)")
major, minor = tonumber(major), tonumber(minor)
if not major then
    arm("5 NO-ARCHIVE read the gate's bash version", false, tostring(bv.status) .. " " .. tostring(bv.stdout))
elseif major < 4 or (major == 4 and minor < 4) then
    local arc, ao = tree(old.stdout, BRINGUP, "events: []\n", true)
    arm("5 NO-ARCHIVE the pre-fix gate refuses even the base-ledger approval there (bash " .. major .. "." .. minor .. ")", arc ~= 0 and ao:find("unbound variable", 1, true) ~= nil, arc .. " " .. ao:sub(1, 120))
else
    out.line("skip: 5 NO-ARCHIVE pre-fix control needs bash<4.4 (this bash is " .. tostring(major) .. "." .. tostring(minor) .. ")")
end

rc, o = tree(NEW, "Setting things up again\u{2026}", approval)
arm("4 REWORD code that says something else is refused", rc ~= 0 and o:find("UNAPPROVED", 1, true) ~= nil, rc .. " " .. o:sub(1, 120))

proc.run({ argv = { "rm", "-rf", A }, timeout_ms = 60000 })
if #failed > 0 then
    verdict.emit("violation:approved-ux-strings-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("approved-ux-strings-fixture", "5 arms")
