-- @env PATH HOME
-- @trace order:1183-j9dk, order:313, order:2332-rxkr
--
-- test-inference-mkdir-fatal-1183-j9dk.lua — when the inference container cannot create the
-- engine directory the entrypoint fails loud and there, naming the ownership. Ported from the
-- .sh of the same name (2332-rxkr). The old form warned, fell through, and died four lines later
-- naming a missing directory. Arms 1-4 are static; 5 runs the shipped guard on an unwritable
-- directory; 6 is the old form, which must exit 0 there or arm 5 proves nothing.
--
--   1 the swallowing form is gone        2 the failure has an explicit guard
--   3 it prints the uid and the owner    4 it cites both ownership orders
--   5 it fails loud on an unwritable mount, saying FATAL
--   6 MUTATION CONTROL the old form exits 0
--
-- As uid 0 mode 0555 excludes nobody: the static arms run, then skip.
-- Usage: tillandsias-plan script run scripts/lua/test-inference-mkdir-fatal-1183-j9dk.lua
-- Verdict: ok:inference-mkdir-fatal:<n> arms | violation:... | skip:...:uid-0-static-arms-only

local fixture = require "common.fixture"
local T = fixture.new("inference-mkdir-fatal")
local SH = fixture.posix_shell()
local SRC = "\n" .. fs.read("images/inference/entrypoint.sh"):gsub("\r", "") .. "\n"
local lines = {}
for l in SRC:gmatch("([^\n]*)\n") do
    if not l:match("^%s*#") then lines[#lines + 1] = l end
end
local CODE = table.concat(lines, "\n")
local function has(s) return text.contains(CODE, s) end
T:arm("1 the mkdir no longer falls through", not has('mkdir -p "$OLLAMA_BINDIR" || echo'), "|| echo is back")
T:arm("2 the failure has an explicit guard", has('if ! mkdir -p "$OLLAMA_BINDIR"; then'), "no guard")

local a = SRC:find('\n    if ! mkdir -p "$OLLAMA_BINDIR"; then\n', 1, true)
local _, z = SRC:find("\n    fi\n", a or 1, true)
if not a or not z then
    T:arm("5 the guard can be extracted", false, "the behavioural arms did not run")
    T:finish()
end
-- Read from the guard alone: the rest of the file prints uids too.
local GUARD = SRC:sub(a + 1, z)
T:arm("3 the diagnosis prints the uid and the mount's owner", text.contains(GUARD, "id -u") and text.contains(GUARD, 'ls -ldn "$OLLAMA_MODELS"'), GUARD)
T:arm("4 both ownership orders are cited", text.contains(GUARD, "order 313") and text.contains(GUARD, "1183-j9dk"), GUARD)
local function run(guard)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/models"); fs.write(d.rel .. "/guard.sh", guard .. "\n")
    local r = T:run{ SH, "-s", cwd = d.abs, env_unset = { "TILLANDSIAS_*", "OLLAMA_*" }, timeout_ms = 30000, stdin = [==[
[ "$(id -u)" != 0 ] || exit 90
chmod 0555 models
if mkdir models/probe 2>/dev/null; then rmdir models/probe; chmod 0755 models; exit 91; fi
( set -e; export OLLAMA_MODELS="$PWD/models/" OLLAMA_BINDIR="$PWD/models/.tools/ollama"; . ./guard.sh ) >out 2>&1
rc=$?; chmod 0755 models; echo "guard=$rc"; cat out
]==] }
    local o = r.stdout or ""
    return r.code, o:match("^guard=(%d+)"), o
end
local rc, got, o = run(GUARD)
if rc == 90 then
    if #T.failed > 0 then T:finish() end
    T:skip("uid-0-static-arms-only")
end
T:arm("5a PREMISE the directory is unwritable", rc == 0, "rc=" .. tostring(rc) .. " " .. o)
T:arm("5b the shipped guard fails on it", got ~= nil and got ~= "0", o)
T:arm("5c and says FATAL", text.contains(o, "FATAL"), o)
rc, got, o = run('mkdir -p "$OLLAMA_BINDIR" || echo "[inference] WARN: cannot create $OLLAMA_BINDIR" >&2')
T:arm("6 MUTATION CONTROL the old form exits 0", got == "0", o)
T:finish()
