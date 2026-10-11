-- @trace order:1602-3ave
--
-- test-land-queue-eviction-comment.lua — a gate-failed eviction comment
-- carries the failing step's verdict lines, not only `tail -5` of the gate log.
--
-- SEEN by macuahuitl-fedora 2026-10-11: #319's run-17 eviction comment could
-- not name its failing arm. The queue captures stderr (`> "$_glog" 2>&1`), so
-- the fixture's "FAIL: ..." line was in the log, but it sits ABOVE the gate's
-- closing summary, and the body quoted only the last five lines.
--
-- scripts/land-queue.sh's own gate_failed_comment builds every body here, from
-- logs captured the way the queue captures a gate:
--   1 PRE-FIX   the builder with its BEGIN/END-FAIL-LINES block stripped (the
--               old tail-only body) lacks the planted FAIL line
--   2 FIXED     the builder as it stands carries it, and a coloured, indented
--               "[FAIL]" line with its colour codes stripped, ahead of the tail
--   3 BOUNDED   30 distinct FAIL lines plus duplicates give exactly 20, each once
--   4 CONTROL   a failing log with no verdict line gets no "Failing lines"
--               section: the body is the old one
--
-- Terminal line: ok:land-queue-eviction-comment-fixture:<n> or
-- refused:land-queue-eviction-comment-fixture:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-queue-eviction-comment.lua

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/eviction-comment-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
fs.mkdir(REL)
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

local src = fs.read("scripts/land-queue.sh") or ""
local fn = src:match("\n(gate_failed_comment%(%) {.-\n})\n")
local pre = fn and fn:gsub("    # BEGIN%-FAIL%-LINES\n.-    # END%-FAIL%-LINES\n", "")
if not fn or pre == fn then
    bad("premise: gate_failed_comment, or its BEGIN/END-FAIL-LINES block, was not found in scripts/land-queue.sh")
    proc.run({ argv = { "rm", "-rf", S } })
    verdict.emit("refused:land-queue-eviction-comment-fixture:" .. failed, 1)
end

-- capture(name, script): run a planted fixture the way the queue runs a gate.
local function capture(name, script)
    fs.write(REL .. "/" .. name .. ".sh", script)
    fs.write(REL .. "/run-" .. name .. ".sh", "bash \"$1\" > \"$2\" 2>&1\n")
    proc.run({ argv = { "bash", S .. "/run-" .. name .. ".sh", S .. "/" .. name .. ".sh", S .. "/" .. name .. ".log" }, timeout_ms = 30000 })
    return S .. "/" .. name .. ".log"
end
local function body(builder, glog)
    fs.write(REL .. "/build.sh", builder .. "\ngate_failed_comment \"$1\" 1 work/9999-zzzz linux-next 0123456789abcdef\n")
    local r = proc.run({ argv = { "bash", S .. "/build.sh", glog }, timeout_ms = 30000 })
    return r.stdout or ""
end

local SUMMARY = ""
for i = 1, 8 do SUMMARY = SUMMARY .. "echo 'summary line " .. i .. "'\n" end
local planted = capture("planted", "echo 'ok:   arm 1 held'\n"
    .. "printf '  \\033[0;31m[FAIL]\\033[0m spec=fixture test=litmus:planted\\n'\n"
    .. "echo 'FAIL: arm 3: keychain state read as absent' >&2\n" .. SUMMARY .. "exit 1\n")

local b_pre = body(pre, planted)
if not has(b_pre, "FAIL: arm 3") and has(b_pre, "summary line 8") then
    ok("pre-fix body quotes only the tail: the planted FAIL line is missing")
else bad("pre-fix body did not reproduce the loss: " .. b_pre:sub(1, 200)) end

local b_fix = body(fn, planted)
if has(b_fix, "FAIL: arm 3: keychain state read as absent") and has(b_fix, "[FAIL] spec=fixture test=litmus:planted")
    and not has(b_fix, "\27[") and has(b_fix, "summary line 8") and b_fix:find("FAIL: arm 3", 1, true) < b_fix:find("summary line 8", 1, true) then
    ok("fixed body carries the FAIL line and the colour-stripped [FAIL] line, ahead of the tail")
else bad("fixed body: " .. b_fix:sub(1, 300)) end

local many = ""
for i = 1, 30 do many = many .. "echo 'FAIL: distinct " .. i .. "'\necho 'FAIL: distinct " .. i .. "'\n" end
local b_many = body(fn, capture("many", many .. SUMMARY .. "exit 1\n"))
local section = b_many:match("Failing lines.-```\n(.-)\n```") or ""
local n, dup = 0, false
local seen = {}
for l in section:gmatch("[^\n]+") do n = n + 1; if seen[l] then dup = true end; seen[l] = true end
if n == 20 and not dup and has(section, "FAIL: distinct 20") and not has(section, "FAIL: distinct 21") then
    ok("30 distinct FAIL lines plus duplicates give exactly the first 20, each once")
else bad("bounded: " .. n .. " lines, duplicate=" .. tostring(dup)) end

local b_ctl = body(fn, capture("control", SUMMARY .. "exit 1\n"))
if not has(b_ctl, "Failing lines") and b_ctl == body(pre, S .. "/control.log") then
    ok("a failing log with no verdict line gets the old body unchanged")
else bad("control: " .. b_ctl:sub(1, 200)) end

proc.run({ argv = { "rm", "-rf", S } })
if failed == 0 then verdict.emit("ok:land-queue-eviction-comment-fixture:" .. passed, 0) end
verdict.emit("refused:land-queue-eviction-comment-fixture:" .. failed, 1)
