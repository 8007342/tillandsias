-- @trace spec:meta-orchestration, order:1004-8vkv, order:2387-lrg2
-- @env PATH HOME
--
-- test-loop-status-append-input.lua — loop-status-append's INPUT handling. Ported from
-- test-loop-status-append-input.sh (2387-lrg2); same six arms, in its order.
--
-- Measured by lenovinha-silverblue 2026-09-04: `loop-status-append <file>` dropped the path,
-- read stdin, and with an inherited SOCKET on fd 0 blocked for 26 MINUTES at 0.0% CPU. Re-run
-- with a closed stdin, the same invocation blamed the fragment's shape against zero bytes.
-- EVERY ARM RUNS THE REAL BINARY: both outcomes are about what the process does with fd 0.
--
--   1 a bare positional path is honoured, or refused with a usage error naming both forms
--   2 a blocking stdin (a FIFO whose writer stays open) is refused within a bounded time
--   3 an empty stdin names the byte count rather than blaming the fragment's shape
--   4 CONTROL the stdin form still writes a fragment
--   5 CONTROL the --file form still writes a fragment
--   6 a malformed fragment reports its shape, not an empty read
--
-- PORT NOTE. Arm 2 needs fd 0 to be a pipe that never reaches EOF, which a proc.run stdin
-- string cannot be, so it runs in a posix_shell script: a FIFO held open by a `sleep`, the
-- binary reading it, and a watchdog that kills the binary BY PID after 10 s and leaves a mark.
-- The .sh used timeout(1) and skipped when none was on PATH; the watchdog needs no timeout(1),
-- so the arm never skips. TILLANDSIAS_* and PROJECT_ROOT are unset: a gate's repo-root export
-- would point the writer at the real checkout instead of the scratch repo.
--
-- GRAMMAR ok:loop-status-append-input:<n> arms | violation:loop-status-append-input:<n>-failed
--       | skip:loop-status-append-input:no-validator

local fixture = require "common.fixture"
local T = fixture.new("loop-status-append-input")
local BIN = fixture.plan_binary()
if BIN == "" then T:skip("no-validator") end
local SH = fixture.posix_shell()
local UNSET = { "TILLANDSIAS_*", "PROJECT_ROOT" }

local repo = T:git_repo("repo")
fs.mkdir(repo.rel .. "/plan/loop_status.d")
fs.write(repo.rel .. "/plan/loop_status.d/.keep", "")
fs.write(repo.rel .. "/plan/loop_status.md", "# loop status\n")
T:must{ "git", "-C", repo.abs, "add", "-A" }
T:must{ "git", "-C", repo.abs, "commit", "-q", "-m", "base" }

local W = T:scratch("in")
local FRAG = W.abs .. "/fragment.md"
fs.write(W.rel .. "/fragment.md",
    "## Cycle 2026-09-04T10:45:00Z (tlatoanis-macbook-air — fixture)\n\nWritten by scripts/lua/test-loop-status-append-input.lua.\n")

local function append(argv, stdin)
    local a = { BIN, "loop-status-append" }
    for _, x in ipairs(argv) do a[#a + 1] = x end
    a.cwd, a.env_unset, a.stdin, a.timeout_ms = repo.abs, UNSET, stdin or "", 60000
    local r = T:run(a)
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function count()
    local n = 0
    for _, e in ipairs(fs.list(repo.rel .. "/plan/loop_status.d") or {}) do
        if e ~= ".keep" and e ~= "." and e ~= ".." then n = n + 1 end
    end
    return n
end
local function tail(s)
    local l = text.lines(s); return table.concat({ l[#l - 1] or "", l[#l] or "" }, "|")
end

-- 1
local before = count()
local rc, o = append({ FRAG })
local after = count()
T:arm("1 a bare positional path is honoured, or refused with a usage error naming both forms",
    after > before or (rc ~= 0 and text.contains(o, "--file") and text.contains(o, "<")),
    "rc=" .. tostring(rc) .. " out=[" .. tail(o) .. "]")

-- 2
fs.write(W.rel .. "/hang.sh", table.concat({
    'f="$1/stdin.fifo"; mark="$1/watchdog-fired"; rm -f "$f" "$mark"; mkfifo "$f" || exit 90',
    'sleep 300 > "$f" & holder=$!',
    '"$2" loop-status-append --host fixture < "$f" > "$1/hang.out" 2>&1 & bin=$!',
    '( sleep 10; kill "$bin" 2>/dev/null && : > "$mark" ) & dog=$!',
    'wait "$bin"; rc=$?',
    'kill "$dog" "$holder" 2>/dev/null; wait "$holder" 2>/dev/null',
    'if [ -e "$mark" ]; then echo "hung rc=$rc"; else echo "rc=$rc"; fi',
}, "\n") .. "\n")
local h = T:run{ SH, W.abs .. "/hang.sh", W.abs, BIN, cwd = repo.abs, env_unset = UNSET, stdin = "", timeout_ms = 60000 }
local hout = text.trim(h.stdout or "")
local hrc = tonumber(hout:match("^rc=(%d+)$") or "")
T:arm("2 a blocking stdin is refused within a bounded time, not waited on",
    h.code == 0 and hrc ~= nil and hrc ~= 0,
    "script rc=" .. tostring(h.code) .. " says '" .. hout .. "' (hung = the 26-minute wait in miniature)")

-- 3
rc, o = append({})
T:arm("3 an empty stdin names the byte count rather than blaming the fragment's shape",
    rc ~= 0 and text.contains(o:lower(), "0 bytes"), "rc=" .. tostring(rc) .. " out=[" .. tail(o) .. "]")

-- 4 / 5
rc, o = append({ "--host", "fixture" }, fs.read(W.rel .. "/fragment.md"))
T:arm("4 CONTROL the stdin form still writes a fragment",
    rc == 0 and text.contains(o, "plan/loop_status.d/"), "rc=" .. tostring(rc) .. " out=[" .. tail(o) .. "]")
rc, o = append({ "--host", "fixture", "--file", FRAG })
T:arm("5 CONTROL the --file form still writes a fragment",
    rc == 0 and text.contains(o, "plan/loop_status.d/"), "rc=" .. tostring(rc) .. " out=[" .. tail(o) .. "]")

-- 6
fs.write(W.rel .. "/bad.md", "# Cycle 2026-09-04T10:45:00Z (single hash, wrong level)\n\nbody\n")
rc, o = append({ "--host", "fixture", "--file", W.abs .. "/bad.md" })
T:arm("6 a malformed fragment reports its shape, not an empty read",
    rc ~= 0 and not text.contains(o:lower(), "0 bytes"), "rc=" .. tostring(rc) .. " out=[" .. tail(o) .. "]")

T:finish()
