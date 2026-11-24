-- @trace order:1179-yshc, order:2303-h6qe, spec:accel-capability-probe
--
-- test-envelope-suite-resolves-the-gates-artifact.lua — the envelope suite
-- (test-capabilities-envelope-names-its-source.sh) grades the binary the GATE
-- built, not whatever artifact sits in-tree. Ported from the .sh (2303-h6qe).
--
-- Where the builder re-execs with CARGO_TARGET_DIR redirected (every Windows
-- host, via with-wsl2-builder.sh) a hardcoded $ROOT/target/debug/tillandsias
-- grades a stale binary. MEASURED on esmeraldinha 2026-09-14: 5/6 arms red with
-- accel_source='' under that regime, 6/6 standalone.
--
-- Hermetic: a scratch checkout with a STALE in-tree fake, a CURRENT fake under a
-- scratch redirected target, and a copy of the real plan-binary-probe.sh.
-- THE SUBJECT IS CUT from the suite's own source (the .sh kept a literal copy
-- and could not see it drift).
--
--   1 PRE-FIX CONTROL the old hardcoded line picks the stale one. Without it, a
--     check that "a binary was found" passes on the pre-fix suite too.
--   2 THE CLOSURE     the suite's own resolution picks the redirected one
--   3 FALLBACK        with nothing redirected it picks the in-tree one
--   4 OVERRIDE        TILLANDSIAS_BIN wins
--
-- Verdict: ok:envelope-suite-resolves-the-gates-artifact:4 arms | violation:…:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("envelope-suite-resolves-the-gates-artifact")
local SUITE = "scripts/test-capabilities-envelope-names-its-source.sh"
local block, on = {}, false
for _, l in ipairs(text.lines(fs.read(SUITE))) do
    if not on and l == 'if [ -n "${TILLANDSIAS_BIN:-}" ]; then' then on = true end
    if on then
        block[#block + 1] = l
        if l == "fi" then break end
    end
end
if block[#block] ~= "fi" then T:refuse("no-subject", SUITE .. " has no resolution block opening with TILLANDSIAS_BIN") end

local W = T:scratch()
local function fake(path, says)
    fs.mkdir(W.rel .. "/" .. path:match("^(.*)/"))
    fs.write(W.rel .. "/" .. path, "#!/usr/bin/env bash\necho '" .. says .. "'\n")
    T:must{ "chmod", "+x", W.abs .. "/" .. path }
end
fake("checkout/target/debug/tillandsias", "stale=true")
fake("redirected/debug/tillandsias", "accel_source=measured")
fs.mkdir(W.rel .. "/checkout/scripts")
fs.write(W.rel .. "/checkout/scripts/plan-binary-probe.sh", fs.read("scripts/plan-binary-probe.sh"))
-- What the resolved binary says: the planted fake is run, not just named.
local function resolved(code, e)
    -- proc.run passes TILLANDSIAS_* and CARGO_TARGET_DIR through (a gate exports
    -- both), so what an arm does not set is unset here.
    local sh = "set -uo pipefail\n" .. (e.CARGO_TARGET_DIR and "" or "unset CARGO_TARGET_DIR\n")
        .. (e.TILLANDSIAS_BIN and "" or "unset TILLANDSIAS_BIN\n") .. "ROOT=\"$FAKE_ROOT\"\n" .. code .. '\nprintf "%s|" "$BIN"; "$BIN" --capabilities\n'
    e.FAKE_ROOT = W.abs .. "/checkout"
    local r = T:run{ fixture.posix_shell(), "-s", stdin = sh, env = e, timeout_ms = 30000 }
    return text.trim(r.stdout or ""), " rc=" .. tostring(r.code) .. " " .. (r.stderr or ""):sub(1, 200)
end
local function says(o, w) return o:match("|(.*)$") == w end
local REDIR = { CARGO_TARGET_DIR = W.abs .. "/redirected" }
local code = table.concat(block, "\n")

local o, e = resolved('BIN="${TILLANDSIAS_BIN:-$ROOT/target/debug/tillandsias}"', { CARGO_TARGET_DIR = REDIR.CARGO_TARGET_DIR })
T:arm("1 PRE-FIX CONTROL the hardcoded line picks the stale in-tree binary", says(o, "stale=true"), o .. e)
o, e = resolved(code, { CARGO_TARGET_DIR = REDIR.CARGO_TARGET_DIR })
T:arm("2 CLOSURE the suite's resolution picks the redirected, current binary", says(o, "accel_source=measured"), o .. e)
o, e = resolved(code, {})
T:arm("3 FALLBACK with nothing redirected it picks the in-tree binary", says(o, "stale=true"), o .. e)
o, e = resolved(code, { TILLANDSIAS_BIN = W.abs .. "/redirected/debug/tillandsias" })
T:arm("4 OVERRIDE TILLANDSIAS_BIN wins", says(o, "accel_source=measured"), o .. e)
T:finish()
