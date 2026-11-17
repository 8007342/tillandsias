-- @trace order:925-erjs, order:748-tkjx, order:634-39ik, order:624-cf9f, order:2066-obsv
-- @env TILLANDSIAS_LITMUS_TESTS_DIR TILLANDSIAS_LINE_WINDOW_DISPOSITIONS
--
-- check-litmus-line-windows.lua — does any litmus ASSERTION depend on a
-- line-count window against a source file? (Ported from
-- scripts/check-litmus-line-windows.sh: the shell-to-lua item order 2066-obsv
-- carried for its gate step, task 3.6. Its history is in
-- `git log -- scripts/check-litmus-line-windows.sh`.)
--
-- WHY (925-erjs, from 748-tkjx's audit). `grep -A<N> 'anchor' file | grep -q
-- 'target'` measures FORMATTING: insert a comment above the anchor and the
-- target slides out of the window, so the test fails on CORRECT code; a window
-- too narrow to reach the real arm greens a broken one. 25 windows across 15
-- tests were converted to structural ranges; this check keeps the count from
-- silently growing back (it grew from 21 to 23 in one day).
--
-- WHAT IS A FINDING. A line of a `critical_path` section (only it decides a
-- verdict; a window in rollback prints context for a human) that is not a YAML
-- comment (every conversion quotes the form it replaced), runs grep with an
-- -A/-B/-C count, and names a source file. Each test still carrying one needs
-- a RECORDED DISPOSITION in openspec/litmus-tests/LINE-WINDOW-DISPOSITIONS.txt,
-- keyed by test file (a line number moves; a key that moves rots): a line
-- starting `<test.yaml>` followed by whitespace or `|`.
--
-- ADVISORY BY DEFAULT (634-39ik: enforcement never halts the line); `--strict`
-- exits 1 for a gate that wants to refuse new debt. Both directories must be
-- inside the repository (the runtime's fs is), which every caller's is. The
-- .sh printed `unavailable:<reason>` exit 2 for an unreadable input; the
-- runtime's grammar names that could-not-run, exit 3 (build.sh ignores both).
--
-- Grammar (exactly one line on stdout; unrecorded hits on stderr):
--   ok:litmus-line-windows:<n>-recorded                           exit 0
--   violation:litmus-line-windows-unrecorded:<n>                  exit 0 (1 with --strict)
--   could-not-run:litmus-line-windows  (reason on stderr)          exit 3

local function nonempty(v) return v ~= nil and v ~= "" end

local STRICT = false
for _, a in ipairs(arg or {}) do
    if a == "--strict" then STRICT = true end
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("litmus-line-windows", "not-a-git-work-tree")
end

local DIR = env.get("TILLANDSIAS_LITMUS_TESTS_DIR")
if not nonempty(DIR) then DIR = ROOT .. "/openspec/litmus-tests" end
local DISPO = env.get("TILLANDSIAS_LINE_WINDOW_DISPOSITIONS")
if not nonempty(DISPO) then DISPO = DIR .. "/LINE-WINDOW-DISPOSITIONS.txt" end

local listed_ok, listed = false, nil
if fs.exists(DIR) then listed_ok, listed = pcall(fs.list, DIR) end
if not listed_ok or not listed then verdict.could_not_run("litmus-line-windows", "litmus-corpus-unreadable") end
local dispo_ok, dispo_body = pcall(fs.read, DISPO)
if not dispo_ok or not dispo_body then verdict.could_not_run("litmus-line-windows", "dispositions-file-unreadable") end

local recorded_tests = {}
for _, l in ipairs(text.lines(dispo_body)) do
    local key = l:match("^([^%s|]+)[%s|]")
    if key then recorded_tests[key] = true end
end

local files = {}
for _, f in ipairs(listed) do
    local name = f:match("([^/]+)$") or f
    if name:match("%.yaml$") then files[#files + 1] = name end
end
table.sort(files)

local WINDOW = [=[grep[^|;)]*-[ABC][ ]*[0-9]]=]
local SOURCE = [=[(\.sh|\.rs|\.md|\.yaml|\.toml|\.json|\.py|\.nix)]=]

local recorded, unrecorded = 0, {}
for _, name in ipairs(files) do
    local sect = nil
    for n, line in ipairs(text.lines(fs.read(DIR .. "/" .. name) or "")) do
        -- Track the top-level section. Only critical_path decides verdicts.
        local s = line:match("^([a-z_]+):")
        if s then sect = s end
        local stripped = line:gsub("^[ \t]+", "")
        if stripped:sub(1, 1) ~= "#" and sect == "critical_path"
            and text.is_match(line, WINDOW) and text.is_match(line, SOURCE) then
            if recorded_tests[name] then
                recorded = recorded + 1
            else
                unrecorded[#unrecorded + 1] = name .. ":" .. n
            end
        end
    end
end

if #unrecorded > 0 then
    for _, hit in ipairs(unrecorded) do log.raw("  " .. hit) end
    log.raw("  Each needs a line in " .. DISPO .. " naming the test and why the window is the right scope,")
    log.raw("  or a conversion to a structural range (see order 925-erjs for the idiom).")
    verdict.emit("violation:litmus-line-windows-unrecorded:" .. #unrecorded, STRICT and 1 or 0)
end
verdict.ok("litmus-line-windows", recorded .. "-recorded")
