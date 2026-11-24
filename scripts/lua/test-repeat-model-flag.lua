-- @trace order:1437-m5yx, order:2302-pspt
--
-- test-repeat-model-flag.lua — the `claude)` arm of ./repeat passes --model and
-- --effort through to the claude binary, exactly as the codex/opencode arms
-- pass their -m flag. A stub CLAUDE_BIN records its argv; three arms check it.
-- Ported from test-repeat-model-flag.sh (2302-pspt).
--
--   1 --model haiku reaches the claude argv
--   2 --effort low reaches the claude argv
--   3 negative control: neither flag given, neither token appears (and the stub
--     DID run: an absent argv file is not "no token"; the .sh passed it vacuously)
--
-- ./repeat builds target/debug/tillandsias-policy under the repo root, so the
-- run pins CARGO_TARGET_DIR to <root>/target (cargo's own default): a forge's
-- redirected target dir must not leak in (721-nyev). The deadline is the
-- runner's timeout_ms, not timeout(1), which stock macOS lacks.
--
-- GRAMMAR ok:repeat-model-flag:3 arms | violation:repeat-model-flag:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("repeat-model-flag")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
local ARGV = W.abs .. "/argv.txt"

fs.write(W.rel .. "/stub-claude", "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" >\"$STUB_ARGV_FILE\"\nprintf 'stub output\\n'\nexit 0\n")
T:must{ "chmod", "+x", W.abs .. "/stub-claude" }

local function run_repeat(...)
    proc.run{ argv = { "rm", "-f", ARGV } }
    local argv = { SH, ROOT .. "/repeat", "--times", "1", "--agent", "claude", "--prompt", "x", ... }
    local r = proc.run{ argv = argv, cwd = ROOT, timeout_ms = 120000,
        env = { CARGO_TARGET_DIR = ROOT .. "/target", CLAUDE_BIN = W.abs .. "/stub-claude", STUB_ARGV_FILE = ARGV } }
    local c = proc.run{ argv = { "cat", ARGV } }
    local lines = (c.code == 0) and text.lines(c.stdout or "") or {}
    return (r.status == "exited" and r.code == 0), lines
end
-- `flag` present as a whole line, and (when want is given) followed by want.
local function pair(lines, flag, want)
    for i, l in ipairs(lines) do
        if l == flag then return want == nil or lines[i + 1] == want end
    end
    return false
end

local ok1, a1 = run_repeat("--model", "haiku")
T:arm("1 --model haiku reached claude argv", ok1 and pair(a1, "--model", "haiku"), table.concat(a1, " "))

local ok2, a2 = run_repeat("--effort", "low")
T:arm("2 --effort low reached claude argv", ok2 and pair(a2, "--effort", "low"), table.concat(a2, " "))

local ok3, a3 = run_repeat()
T:arm("3 no --model/--effort token when neither flag is given",
    ok3 and #a3 > 0 and not pair(a3, "--model") and not pair(a3, "--effort"), table.concat(a3, " "))

T:finish()
