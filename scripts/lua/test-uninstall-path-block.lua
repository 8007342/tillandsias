-- @trace order:372
-- The uninstaller removes its own PATH block from the user's dotfiles and nothing else.
-- Those files predate the install and outlive it, so the failure that matters is "the user
-- lost something else", not "the block survived". The function under test is cut out of
-- scripts/uninstall.sh (sourcing that would run an uninstall); the shell fixture this
-- replaces, test-uninstall-path-block.sh, tested a copy of its own.
local fixture = require "common.fixture"
local T = fixture.new("uninstall-path-block")
local B, E = "# >>> tillandsias PATH >>>", "# <<< tillandsias PATH <<<"
local install, uninstall = fs.read("scripts/install.sh"), fs.read("scripts/uninstall.sh")
local function both(t) return install:find(t, 1, true) ~= nil and uninstall:find(t, 1, true) ~= nil end
T:arm("1 install.sh and uninstall.sh agree on the markers",
    both('PATH_MARKER_BEGIN="' .. B .. '"') and both('PATH_MARKER_END="' .. E .. '"'), "markers drifted")
local fn = uninstall:match("\n(strip_path_block%(%) {\n.-\n}\n)")
if not fn then T:refuse("no-strip-path-block", "scripts/uninstall.sh no longer defines strip_path_block()") end

local d = T:scratch()
fs.write(d.rel .. "/strip.sh", "set -eu\nPATH_MARKER_BEGIN='" .. B .. "'\nPATH_MARKER_END='" .. E .. "'\n" .. fn
    .. 'strip_path_block "$1"\n')
local function strip(name, body)
    if body then fs.write(d.rel .. "/" .. name, body) end
    local r = T:run{ fixture.posix_shell(), d.abs .. "/strip.sh", d.abs .. "/" .. name }
    local ok, s = pcall(fs.read, d.rel .. "/" .. name)
    return ok and s or nil, r.code
end
local function show(s, rc) return "rc=" .. tostring(rc) .. " [" .. tostring(s) .. "]" end
local BODY = 'case ":$PATH:" in\n    *":/x:"*) ;;\n    *) export PATH="/x:$PATH" ;;\nesac\n'
local s, rc = strip("bashrc", "export EDITOR=vim\n\n" .. B .. "\n" .. BODY .. E .. "\nalias ll='ls -l'\n")
T:arm("2 the block goes and the lines around it are byte-identical",
    rc == 0 and s == "export EDITOR=vim\n\nalias ll='ls -l'\n", show(s, rc))
s, rc = strip("untouched", "export EDITOR=nano\n")
T:arm("3 a file without the marker is left alone", rc == 0 and s == "export EDITOR=nano\n", show(s, rc))
s, rc = strip("absent")
T:arm("4 a missing file is a no-op, not an error", rc == 0 and s == nil, show(s, rc))
s, rc = strip("doubled", "first=1\n" .. B .. "\nexport PATH=\"/x:$PATH\"\n" .. E .. "\nmiddle=2\n" .. B
    .. "\nexport PATH=\"/y:$PATH\"\n" .. E .. "\nlast=3\n")
T:arm("5 two blocks are both removed", rc == 0 and s == "first=1\nmiddle=2\nlast=3\n", show(s, rc))
-- An unterminated block takes the rest of the file: awk cannot know where it ends. What is
-- held is that everything before it survives, so the damage is visible.
s, rc = strip("unterminated", "before=1\n" .. B .. "\nexport PATH=\"/x:$PATH\"\n")
T:arm("6 content before an unterminated block survives", rc == 0 and s ~= nil and s:find("before=1\n", 1, true) == 1, show(s, rc))
T:finish()
