-- @trace order:2243-wosv
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-script-stdin-read.lua — the runner's stdin primitive (2243-wosv slice 1).
-- A script reads its own stdin ONLY when its header says `-- @stdin <max-bytes>`;
-- the read is bounded and EOF-safe, so a decider the preflight door runs can
-- never block a gate on an inherited stdin unless it opts in.
--   1 PIPED      `printf data | script run probe` returns the bytes exactly
--   2 UNDECLARED with no @stdin there is no `stdin` table at all
--   3 TOO-LARGE  more than the cap is refused:stdin:too-large:<cap>, by name
--   4 CLOSED     a closed stdin (</dev/null) reads as "" at once, never blocks
--   5 NO-CAP     `-- @stdin` with no byte cap is refused before the script runs
-- (A terminal stdin returns "" without reading; a tty cannot be faked here.)
--
-- Verdict: ok:script-stdin-read:<n> or violation:script-stdin-read:<failed>.

local BASH = "/bin/bash"
do
    local ep = text.trim(proc.run({ argv = { "git", "--exec-path" }, timeout_ms = 10000 }).stdout or "")
    if ep:find("^%a:/.*/libexec/git%-core$") then
        BASH = (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe"))
    end
end
local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not RUNNER or RUNNER == "" then RUNNER = "target/release/tillandsias-plan" end
local rel = "target/plan-scratch/stdin-read-" .. tostring(time.now_ms())
fs.mkdir(rel)

fs.write(rel .. "/declared.lua", '-- @stdin 16\nlocal s = stdin.read()\nout.line("got=[" .. s .. "] len=" .. #s)\nverdict.emit("ok:probe", 0)\n')
fs.write(rel .. "/undeclared.lua", 'out.line("stdin=" .. type(stdin))\nverdict.emit("ok:probe", 0)\n')
fs.write(rel .. "/nocap.lua", '-- @stdin\nverdict.emit("ok:probe", 0)\n')
-- The driver feeds stdin the way a shell pipeline does (proc.run's own stdin
-- string is the CHILD's input, which is exactly a pipe into the runner).
local function probe(script, input, closed)
    local argv = { RUNNER, "script", "run", rel .. "/" .. script }
    if closed then
        fs.write(rel .. "/closed.sh", '"$1" script run "$2" </dev/null\n')
        argv = { BASH, rel .. "/closed.sh", RUNNER, rel .. "/" .. script }
    end
    local t0 = time.now_ms()
    local p = proc.run{ argv = argv, stdin = input, timeout_ms = 30000 }
    return (p.stdout or "") .. (p.stderr or ""), p.code, time.now_ms() - t0
end

local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end

local o, rc = probe("declared.lua", "abc\ndef\n")
if rc == 0 and o:find("got=[abc\ndef\n] len=8", 1, true) then ok("1: piped bytes are returned exactly")
else bad("1: piped answered rc=" .. tostring(rc) .. " [" .. o .. "]") end

o, rc = probe("undeclared.lua", "abc\n")
if rc == 0 and o:find("stdin=nil", 1, true) then ok("2: with no @stdin there is no stdin table")
else bad("2: undeclared answered rc=" .. tostring(rc) .. " [" .. o .. "]") end

o, rc = probe("declared.lua", string.rep("x", 17))
if rc ~= 0 and o:find("refused:stdin:too-large:16", 1, true) then ok("3: 17 bytes past a 16-byte cap is refused:stdin:too-large:16")
else bad("3: oversized answered rc=" .. tostring(rc) .. " [" .. o .. "]") end

local ms
o, rc, ms = probe("declared.lua", nil, true)
if rc == 0 and o:find("got=[] len=0", 1, true) and ms < 10000 then ok("4: a closed stdin reads as \"\" in " .. ms .. " ms")
else bad("4: closed answered rc=" .. tostring(rc) .. " in " .. tostring(ms) .. " ms [" .. o .. "]") end

o, rc = probe("nocap.lua", "")
if rc ~= 0 and o:find("refused:script-header:stdin-needs-a-byte-cap", 1, true) then ok("5: @stdin with no cap is refused by name")
else bad("5: no-cap answered rc=" .. tostring(rc) .. " [" .. o .. "]") end

fs.write(rel .. "/cleanup.sh", 'rm -rf -- "$1"\n')
proc.run{ argv = { BASH, rel .. "/cleanup.sh", rel } }
if fail == 0 then verdict.emit("ok:script-stdin-read:" .. pass, 0) end
verdict.emit("violation:script-stdin-read:" .. fail, 1)
