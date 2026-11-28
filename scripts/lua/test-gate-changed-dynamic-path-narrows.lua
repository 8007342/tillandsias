-- @trace order:2423-86ca, order:2422-4yak, order:1916-tsel, spec:ci-release
-- @env GATE_CHANGED_FX_INNER
-- inputs: scripts/gate-changed.sh lib/lua/common/ crates/tillandsias-plan/
--
-- test-gate-changed-dynamic-path-narrows.lua — a DYNAMIC path under scripts/
-- ("$ROOT/scripts/${name}.sh", the token stops at the $) used to map its file to the
-- whole scripts/ directory, so ~50 fixtures ran on any script change. It now narrows to
-- the file's LITERAL names under scripts/, but only when the file names at least one
-- and has no glob, ls or find over that directory (a census really reads all of it).
-- A stub tree, changed one path at a time.
--
--   1 narrowed: a fixture with a dynamic path plus a literal subject is NOT selected by an
--     unrelated script, and IS selected by its literal subject
--   2 kept: a glob census over scripts/ keeps the whole directory
--   3 kept: a find over scripts/ keeps the whole directory
--   4 kept: a dynamic path with no literal under scripts/ keeps the whole directory
--   6 narrowed: a Lua concatenation (ROOT .. "/scripts/" .. name) narrows the same way
--   7 kept: a Lua fs.walk over scripts/ beside a concatenation keeps the whole directory
--   8 kept: a dynamic name read as DATA from a literal script that itself reads scripts/
--     whole (test-host-tools.sh takes its provers from check-host-tools.sh) keeps it
--   5 mutant: a narrowed fixture whose literal subject reads scripts/ dynamically with no
--     literal of its own still selects on any script change, through the subject (closure)
--
-- Verdict: ok:gate-changed-dynamic-path-narrows:<n> arms | violation:gate-changed-dynamic-path-narrows:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-changed-dynamic-path-narrows")
local SH = fixture.posix_shell()
if not fs.exists("scripts/gate-changed.sh") then T:refuse("subject-missing") end

local W = T:scratch()
local tree = W.rel .. "/tree"
fs.mkdir(tree .. "/scripts")
local function put(p, s) fs.write(tree .. "/" .. p, s) end
put("scripts/gate-changed.sh", fs.read("scripts/gate-changed.sh"))
local HEAD = '#!/usr/bin/env bash\nROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"\n'
local FX = {
    n = 'bash "$ROOT/scripts/subj-x.sh"\nname=probe\n[ -f "$ROOT/scripts/${name}.sh" ] || true\n',
    k = 'bash "$ROOT/scripts/subj-x.sh"\nfor f in "$ROOT"/scripts/*.sh; do :; done\n[ -f "$ROOT/scripts/${name}.sh" ] || true\n',
    f = 'bash "$ROOT/scripts/subj-x.sh"\nfind "$ROOT/scripts" -name probe >/dev/null\n[ -f "$ROOT/scripts/${name}.sh" ] || true\n',
    d = 'name=probe\n[ -f "$ROOT/scripts/${name}.sh" ] || true\n',
    m = 'bash "$ROOT/scripts/subj-m.sh"\n[ -f "$ROOT/scripts/${name}.sh" ] || true\n',
    h = 'CHECK="$ROOT/scripts/spec-src.sh"\nfor p in $(awk "/^SPEC/{f=1}f" "$CHECK"); do bash "$ROOT/scripts/$p"; done\n',
}
local BUILD = { '#!/usr/bin/env bash', 'if [[ "$FLAG_CHECK" == true ]]; then' }
for _, k in ipairs{ "n", "k", "f", "d", "m", "h" } do
    put("scripts/test-" .. k .. ".sh", HEAD .. FX[k])
    BUILD[#BUILD + 1] = '    _step "Checking ' .. k .. '..."'
    BUILD[#BUILD + 1] = '    if ! _run bash "$SCRIPT_DIR/scripts/test-' .. k .. '.sh" 2>&1; then exit 1; fi'
end
BUILD[#BUILD + 1] = 'fi'
put("build.sh", table.concat(BUILD, "\n") .. "\n")
put("scripts/subj-x.sh", "#!/usr/bin/env bash\necho x\n")
put("scripts/subj-m.sh", HEAD .. 'kind=a\n. "$ROOT/scripts/${kind}.sh"\n')
put("scripts/spec-src.sh", HEAD .. "for t in \"$ROOT\"/scripts/*.sh; do :; done\ncat <<SPEC\nother.sh\nSPEC\n")
put("scripts/other.sh", "#!/usr/bin/env bash\necho other\n")
put("Cargo.toml", "[workspace]\nmembers = []\n")
fs.mkdir(tree .. "/scripts/lua"); fs.mkdir(tree .. "/scripts/gate-steps.d")
put("scripts/lua/test-l.lua", "local ROOT = \".\"\nlocal name = \"probe\"\nlocal p = ROOT .. \"/scripts/\" .. name .. \".sh\"\nlocal s = fs.read(\"scripts/subj-x.sh\")\n")
put("scripts/lua/test-w.lua", "local ROOT = \".\"\nlocal name = \"probe\"\nlocal p = ROOT .. \"/scripts/\" .. name .. \".sh\"\nlocal s = fs.read(\"scripts/subj-x.sh\")\nlocal all = fs.walk(\"scripts\", { suffix = \".sh\" })\n")
put("scripts/gate-steps.d/010-l.step", "STEP_DESC=\"l\"\nSTEP_LUA=\"scripts/lua/test-l.lua\"\nSTEP_ERROR=\"l\"\nSTEP_OK=\"l\"\n")
put("scripts/gate-steps.d/020-w.step", "STEP_DESC=\"w\"\nSTEP_LUA=\"scripts/lua/test-w.lua\"\nSTEP_ERROR=\"w\"\nSTEP_OK=\"w\"\n")
T:must{ "git", "-C", W.abs .. "/tree", "init", "-q" }

local STUB = W.abs .. "/tree/scripts/gate-changed.sh"
local function sel(path)
    fs.write(W.rel .. "/changed", path .. "\n")
    local r = T:run{ SH, STUB, "--list", "--files", W.abs .. "/changed", cwd = W.abs .. "/tree", env_unset = { "TILLANDSIAS_*" }, timeout_ms = 300000 }
    return (r.stdout or "") .. (r.stderr or "")
end
local function picks(o, k) return o:find("select:fixture:scripts/test-" .. k .. ".sh", 1, true) ~= nil end
local function picksl(o, k) return o:find("select:fixture:scripts/lua/test-" .. k .. ".lua", 1, true) ~= nil end

local other, subj = sel("scripts/other.sh"), sel("scripts/subj-x.sh")
local scoped = other:find("select:scoped", 1, true) ~= nil
if not scoped then T:arm("premise: a change to scripts/other.sh is scoped, not select:all", false, other) end
T:arm("1 narrowed: dynamic path + literal subject is not selected by an unrelated script, and is by its subject",
    scoped and not picks(other, "n") and picks(subj, "n"), "other-> " .. other .. " subj-> " .. subj)
T:arm("2 kept: a glob census over scripts/ selects on any script change", picks(other, "k"), other)
T:arm("3 kept: a find over scripts/ selects on any script change", picks(other, "f"), other)
T:arm("4 kept: a dynamic path with no literal under scripts/ selects on any script change", picks(other, "d"), other)
T:arm("5 mutant: a narrowed fixture whose subject reads scripts/ dynamically still selects, through the subject",
    picks(other, "m"), other)
T:arm("8 kept: names taken from DATA in a literal script that itself reads scripts/ whole keep the directory (test-host-tools.sh <- check-host-tools.sh)", picks(other, "h"), other)
T:arm("6 narrowed: a Lua concatenation (ROOT .. \"/scripts/\" .. name) plus a literal subject is not selected by an unrelated script, and is by its subject",
    not picksl(other, "l") and picksl(subj, "l"), "other-> " .. other .. " subj-> " .. subj)
T:arm("7 kept: a Lua fs.walk over scripts beside a concatenation selects on any script change", picksl(other, "w"), other)
T:finish()
